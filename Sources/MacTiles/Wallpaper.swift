import AVFoundation
import AppKit
import ImageIO
import SwiftUI
import UniformTypeIdentifiers

// MARK: - Files

enum WallpaperKind: Equatable {
    case still, animated, video
}

/// Wallpaper files live in ~/Library/Application Support/MacTiles/Wallpapers, so a picture or
/// video keeps working even if you move or delete the original.
enum Wallpapers {
    static let directory: URL = FileManager.default
        .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("MacTiles/Wallpapers", isDirectory: true)

    /// Kinds of file the picker accepts.
    static let contentTypes: [UTType] = [.image, .movie, .gif]

    static func url(for stored: String?) -> URL? {
        guard let s = stored?.trimmingCharacters(in: .whitespaces), !s.isEmpty else { return nil }
        return s.hasPrefix("/") ? URL(fileURLWithPath: s) : importedCopy(s)
    }

    /// An imported copy's file inside the Wallpapers folder; nil for anything that would
    /// point elsewhere ("../layout.json" in a hand-edited layout file).
    static func importedCopy(_ name: String) -> URL? {
        guard !name.isEmpty, !name.contains("/"), name != ".", name != ".." else { return nil }
        return directory.appendingPathComponent(name)
    }

    static func displayName(_ stored: String?) -> String? {
        guard let url = url(for: stored) else { return nil }
        let name = url.lastPathComponent
        // Imported copies are "1a2b3c4d-Original Name.mp4"; show the original name.
        if !(stored ?? "").hasPrefix("/"), name.count > 9, name[name.index(name.startIndex, offsetBy: 8)] == "-" {
            return String(name.dropFirst(9))
        }
        return name
    }

    /// Video, animated picture (GIF, animated PNG/HEIC/WebP) or still picture; nil if it's neither.
    static func kind(of url: URL) -> WallpaperKind? {
        guard let type = UTType(filenameExtension: url.pathExtension.lowercased()) else { return nil }
        if type.conforms(to: .movie) || type.conforms(to: .video) { return .video }
        if type.conforms(to: .image) { return frameCount(url) > 1 ? .animated : .still }
        return nil
    }

    static func frameCount(_ url: URL) -> Int {
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil) else { return 0 }
        return CGImageSourceGetCount(src)
    }

    /// Copies the file into the Wallpapers folder and removes the previous imported copy.
    static func importFile(_ source: URL, replacing old: String?) throws -> String {
        let fm = FileManager.default
        try fm.createDirectory(at: directory, withIntermediateDirectories: true)
        let name = String(UUID().uuidString.prefix(8)).lowercased() + "-" + source.lastPathComponent
        try fm.copyItem(at: source, to: directory.appendingPathComponent(name))
        remove(old)
        return name
    }

    /// Deletes an imported copy (never a file elsewhere on your Mac).
    static func remove(_ stored: String?) {
        guard let stored, !stored.hasPrefix("/"), let url = importedCopy(stored) else { return }
        try? FileManager.default.removeItem(at: url)
    }
}

// MARK: - When to animate

/// Animated wallpapers pause when Start can't be seen, in Low Power Mode, and with Reduce Motion on.
@MainActor
final class MotionPolicy: ObservableObject {
    static let shared = MotionPolicy()
    @Published private(set) var allowsMotion = true
    private var observers: [Any] = []

    private init() {
        update()
        observers.append(NotificationCenter.default.addObserver(
            forName: .NSProcessInfoPowerStateDidChange, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.update() }
            })
        observers.append(NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.update() }
            })
    }

    private func update() {
        let allowed = !ProcessInfo.processInfo.isLowPowerModeEnabled && !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        if allowed != allowsMotion { allowsMotion = allowed }
    }
}

// MARK: - The background

/// Everything behind the tiles: a color, a picture, a video or a live wallpaper.
@MainActor
struct BackgroundView: View {
    let size: CGSize
    @EnvironmentObject private var launcher: Launcher
    @EnvironmentObject private var store: LayoutStore
    @ObservedObject private var motion = MotionPolicy.shared

    var body: some View {
        let s = store.settings
        let animating = launcher.tilesLive && motion.allowsMotion
        ZStack {
            Color(hex: s.background)
            switch s.backgroundStyle {
            case .color:
                sheen
            case .media:
                if let url = Wallpapers.url(for: s.wallpaperFile) {
                    MediaWallpaper(url: url, size: size, playing: animating)
                    Color.black.opacity(s.wallpaperDim)
                } else {
                    sheen
                }
            case .live:
                LiveWallpaperView(style: s.liveWallpaper, tint: s.background, animating: animating)
            }
        }
        .frame(width: size.width, height: size.height)
        .clipped()
        .allowsHitTesting(false)
    }

    private var sheen: some View {
        RadialGradient(colors: [Color.white.opacity(0.07), .clear], center: .topLeading,
                       startRadius: 10, endRadius: max(size.width, 600) * 0.8)
    }
}

// MARK: - Pictures and videos

@MainActor
struct MediaWallpaper: View {
    let url: URL
    let size: CGSize
    let playing: Bool
    @State private var kind: WallpaperKind?
    @State private var still: NSImage?

    var body: some View {
        ZStack {
            switch kind {
            case .video:
                VideoWallpaperView(url: url, playing: playing)
            case .animated:
                AnimatedImageView(url: url, playing: playing)
            case .still:
                if let still {
                    Image(nsImage: still)
                        .resizable()
                        .scaledToFill()
                        .frame(width: size.width, height: size.height)
                        .clipped()
                        .transition(.opacity)
                }
            case nil:
                EmptyView()
            }
        }
        .frame(width: size.width, height: size.height)
        .task(id: url) { await load() }
    }

    private func load() async {
        let url = self.url
        let maxPixel = Self.screenPixels
        let result = await Task.detached(priority: .userInitiated) { () -> (WallpaperKind?, Box<CGImage?>) in
            let kind = Wallpapers.kind(of: url)
            let image = kind == .still ? ImageLoader.thumbnail(url, maxPixel: maxPixel) : nil
            return (kind, Box(image))
        }.value
        kind = result.0
        if let cg = result.1.value {
            withAnimation(.easeInOut(duration: 0.4)) { still = NSImage(cgImage: cg, size: .zero) }
        } else {
            still = nil
        }
    }

    /// Long edge of the largest display, in pixels — no point decoding a 48 MP photo at full size.
    static var screenPixels: Int {
        let longest = NSScreen.screens.map { max($0.frame.width, $0.frame.height) * $0.backingScaleFactor }.max() ?? 3000
        return Int(min(max(longest, 1600), 6144))
    }
}

/// A silent, looping video.
struct VideoWallpaperView: NSViewRepresentable {
    let url: URL
    let playing: Bool

    func makeNSView(context: Context) -> VideoWallpaperNSView { VideoWallpaperNSView() }

    func updateNSView(_ view: VideoWallpaperNSView, context: Context) {
        view.load(url)
        view.setPlaying(playing)
    }

    static func dismantleNSView(_ view: VideoWallpaperNSView, coordinator: ()) {
        view.stop()
    }
}

final class VideoWallpaperNSView: NSView {
    private let player = AVQueuePlayer()
    private let playerLayer = AVPlayerLayer()
    private var looper: AVPlayerLooper?
    private var current: URL?

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer = CALayer()
        player.isMuted = true
        player.preventsDisplaySleepDuringVideoPlayback = false
        player.actionAtItemEnd = .advance
        playerLayer.player = player
        playerLayer.videoGravity = .resizeAspectFill
        layer?.addSublayer(playerLayer)
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        playerLayer.frame = bounds
        CATransaction.commit()
    }

    func load(_ url: URL) {
        guard url != current else { return }
        current = url
        player.removeAllItems()
        looper = AVPlayerLooper(player: player, templateItem: AVPlayerItem(url: url))
    }

    func setPlaying(_ playing: Bool) {
        if playing { player.play() } else { player.pause() }
    }

    func stop() {
        player.pause()
        looper?.disableLooping()
        looper = nil
        player.removeAllItems()
    }
}

/// Animated GIF / PNG / HEIC / WebP, scaled to fill, played with Core Animation.
struct AnimatedImageView: NSViewRepresentable {
    let url: URL
    let playing: Bool

    func makeNSView(context: Context) -> AnimatedImageNSView { AnimatedImageNSView() }

    func updateNSView(_ view: AnimatedImageNSView, context: Context) {
        view.load(url)
        view.setPlaying(playing)
    }
}

final class AnimatedImageNSView: NSView {
    private let imageLayer = CALayer()
    private var current: URL?
    private var playing = false

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer = CALayer()
        imageLayer.contentsGravity = .resizeAspectFill
        imageLayer.masksToBounds = true
        layer?.addSublayer(imageLayer)
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        imageLayer.frame = bounds
        CATransaction.commit()
    }

    func load(_ url: URL) {
        guard url != current else { return }
        current = url
        imageLayer.removeAllAnimations()
        imageLayer.contents = nil
        Task { @MainActor in
            let decoded = await Task.detached(priority: .userInitiated) { Box(AnimatedImageDecoder.decode(url)) }.value
            guard self.current == url, let frames = decoded.value, let first = frames.images.first else { return }
            self.imageLayer.contents = first
            guard frames.images.count > 1 else { return }
            let anim = CAKeyframeAnimation(keyPath: "contents")
            anim.values = frames.images
            anim.keyTimes = frames.keyTimes.map { NSNumber(value: $0) }
            anim.calculationMode = .discrete
            anim.duration = frames.duration
            anim.repeatCount = .infinity
            anim.isRemovedOnCompletion = false
            anim.beginTime = 0
            self.imageLayer.add(anim, forKey: "frames")
            self.applySpeed()
        }
    }

    func setPlaying(_ playing: Bool) {
        guard playing != self.playing else { return }
        self.playing = playing
        applySpeed()
    }

    /// Pauses or resumes the layer's animation where it is.
    private func applySpeed() {
        if playing {
            guard imageLayer.speed == 0 else { return }
            let paused = imageLayer.timeOffset
            imageLayer.speed = 1
            imageLayer.timeOffset = 0
            imageLayer.beginTime = 0
            imageLayer.beginTime = imageLayer.convertTime(CACurrentMediaTime(), from: nil) - paused
        } else {
            guard imageLayer.speed != 0 else { return }
            let now = imageLayer.convertTime(CACurrentMediaTime(), from: nil)
            imageLayer.speed = 0
            imageLayer.timeOffset = now
        }
    }
}

enum AnimatedImageDecoder {
    struct Frames {
        let images: [CGImage]
        let keyTimes: [Double]
        let duration: Double
    }

    /// Decodes up to 400 frames, downsampled so the whole animation fits in roughly 400 MB.
    static func decode(_ url: URL) -> Frames? {
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        let count = min(CGImageSourceGetCount(src), 400)
        guard count > 0 else { return nil }
        let maxPixel = min(2048, max(320, Int(sqrt(100_000_000.0 / Double(count)))))
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixel,
        ]
        var images: [CGImage] = []
        var delays: [Double] = []
        for i in 0..<count {
            guard let image = CGImageSourceCreateThumbnailAtIndex(src, i, options as CFDictionary) else { continue }
            images.append(image)
            let props = CGImageSourceCopyPropertiesAtIndex(src, i, nil) as? [CFString: Any] ?? [:]
            delays.append(frameDelay(props))
        }
        guard !images.isEmpty else { return nil }
        return frames(images: images, delays: delays)
    }

    static func frames(images: [CGImage], delays: [Double]) -> Frames {
        let total = max(delays.reduce(0, +), 0.01)
        var keyTimes: [Double] = []
        var t = 0.0
        for d in delays {
            keyTimes.append(t / total)
            t += d
        }
        keyTimes.append(1)
        // CAKeyframeAnimation with discrete mode wants one more key time than values.
        return Frames(images: images, keyTimes: keyTimes, duration: total)
    }

    /// Frame delay from GIF, PNG (APNG), HEICS or WebP metadata. Like browsers, tiny delays mean 0.1 s.
    static func frameDelay(_ props: [CFString: Any]) -> Double {
        let containers: [(CFString, CFString, CFString)] = [
            (kCGImagePropertyGIFDictionary, kCGImagePropertyGIFUnclampedDelayTime, kCGImagePropertyGIFDelayTime),
            (kCGImagePropertyPNGDictionary, kCGImagePropertyAPNGUnclampedDelayTime, kCGImagePropertyAPNGDelayTime),
            (kCGImagePropertyHEICSDictionary, kCGImagePropertyHEICSUnclampedDelayTime, kCGImagePropertyHEICSDelayTime),
            (kCGImagePropertyWebPDictionary, kCGImagePropertyWebPUnclampedDelayTime, kCGImagePropertyWebPDelayTime),
        ]
        for (dictKey, unclamped, clamped) in containers {
            guard let dict = props[dictKey] as? [CFString: Any] else { continue }
            let value = (dict[unclamped] as? Double) ?? (dict[clamped] as? Double) ?? 0.1
            return value < 0.02 ? 0.1 : value
        }
        return 0.1
    }
}

// MARK: - Live wallpapers

/// Animated wallpapers drawn with SwiftUI Canvas at up to 30 fps, tinted with the background color.
/// When paused (Start hidden or covered, Low Power Mode, Reduce Motion) they hold still.
struct LiveWallpaperView: View {
    let style: LiveWallpaper
    let tint: String
    let animating: Bool
    var frameRate: Double = 30

    var body: some View {
        let colors = LivePalette.colors(tint)
        TimelineView(.animation(minimumInterval: 1 / frameRate, paused: !animating)) { ctx in
            let t = ctx.date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: 100_000)
            Canvas(rendersAsynchronously: true) { gc, size in
                switch style {
                case .aurora: LiveDraw.aurora(&gc, size, t, colors)
                case .ribbons: LiveDraw.ribbons(&gc, size, t, colors)
                case .bokeh: LiveDraw.bokeh(&gc, size, t, colors)
                case .squares: LiveDraw.squares(&gc, size, t, colors)
                }
            }
        }
    }
}

/// Four related colors derived from the tint: neighbouring hues, lighter and more saturated.
enum LivePalette {
    static func colors(_ hex: String) -> [Color] {
        hsb(hex).map { Color(hue: $0.h, saturation: $0.s, brightness: $0.b) }
    }

    static func hsb(_ hex: String) -> [(h: Double, s: Double, b: Double)] {
        let ns = NSColor(Color(hex: hex)).usingColorSpace(.sRGB) ?? .systemPurple
        var h: CGFloat = 0, s: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        ns.getHue(&h, saturation: &s, brightness: &b, alpha: &a)
        let hue = Double(h), sat = Double(s), bri = Double(b)
        func wrap(_ x: Double) -> Double { (x.truncatingRemainder(dividingBy: 1) + 1).truncatingRemainder(dividingBy: 1) }
        // Grey tints get a gentle colour so the effect is still visible.
        let baseSat = max(sat, 0.35)
        return [
            (wrap(hue), min(1, baseSat + 0.15), min(1, max(bri, 0.35) + 0.45)),
            (wrap(hue + 0.08), min(1, baseSat + 0.10), min(1, max(bri, 0.35) + 0.35)),
            (wrap(hue - 0.10), min(1, baseSat + 0.05), min(1, max(bri, 0.35) + 0.40)),
            (wrap(hue + 0.33), max(0.25, baseSat - 0.15), min(1, max(bri, 0.35) + 0.30)),
        ]
    }
}

enum LiveDraw {
    /// Deterministic pseudo-random numbers, so every launch draws the same scene.
    static func rand(_ i: Int, _ salt: Int) -> Double {
        var x = UInt64(truncatingIfNeeded: i &* 73_856_093 ^ salt &* 19_349_663) &+ 0x9E37_79B9_7F4A_7C15
        x = (x ^ (x >> 30)) &* 0xBF58_476D_1CE4_E5B9
        x = (x ^ (x >> 27)) &* 0x94D0_49BB_1331_11EB
        x ^= x >> 31
        return Double(x % 1_000_000) / 1_000_000
    }

    /// Slow, glowing colour fields drifting on Lissajous paths.
    static func aurora(_ gc: inout GraphicsContext, _ size: CGSize, _ t: Double, _ colors: [Color]) {
        let w = size.width, h = size.height, m = max(w, h)
        gc.blendMode = .screen
        for i in 0..<5 {
            let c = colors[i % colors.count]
            let speed = 0.035 + rand(i, 1) * 0.03
            let x = w * (0.5 + 0.45 * sin(t * speed + rand(i, 2) * 6.28))
            let y = h * (0.5 + 0.40 * cos(t * speed * 0.8 + rand(i, 3) * 6.28))
            let r = m * (0.35 + 0.2 * rand(i, 4)) * (1 + 0.08 * sin(t * 0.2 + Double(i)))
            let rect = CGRect(x: x - r, y: y - r, width: r * 2, height: r * 2)
            gc.fill(Path(ellipseIn: rect),
                    with: .radialGradient(Gradient(colors: [c.opacity(0.42), c.opacity(0.12), c.opacity(0)]),
                                          center: CGPoint(x: x, y: y), startRadius: 0, endRadius: r))
        }
    }

    /// Flowing translucent bands, like the Windows 8 Start backgrounds.
    static func ribbons(_ gc: inout GraphicsContext, _ size: CGSize, _ t: Double, _ colors: [Color]) {
        let w = size.width, h = size.height
        gc.blendMode = .screen
        let step = max(12, w / 120)
        for i in 0..<4 {
            let c = colors[i % colors.count]
            let baseY = h * (0.25 + 0.17 * Double(i))
            let amp = h * (0.08 + 0.05 * rand(i, 5))
            let k = (1.2 + rand(i, 6) * 1.6) * 2 * .pi / w
            let speed = 0.12 + rand(i, 7) * 0.1
            let thickness = h * (0.05 + 0.06 * rand(i, 8))
            var top: [CGPoint] = []
            var bottom: [CGPoint] = []
            var x = -step
            while x <= w + step {
                let y = baseY + amp * sin(k * x + t * speed + Double(i) * 1.7)
                let th = thickness * (0.6 + 0.4 * sin(k * 0.5 * x - t * speed * 0.7 + Double(i)))
                top.append(CGPoint(x: x, y: y - th))
                bottom.append(CGPoint(x: x, y: y + th))
                x += step
            }
            var path = Path()
            path.addLines(top)
            path.addLines(bottom.reversed())
            path.closeSubpath()
            gc.fill(path, with: .linearGradient(
                Gradient(colors: [c.opacity(0), c.opacity(0.32), c.opacity(0.18), c.opacity(0)]),
                startPoint: CGPoint(x: 0, y: baseY), endPoint: CGPoint(x: w, y: baseY)))
        }
    }

    /// Soft out-of-focus lights drifting upward.
    static func bokeh(_ gc: inout GraphicsContext, _ size: CGSize, _ t: Double, _ colors: [Color]) {
        let w = size.width, h = size.height
        gc.blendMode = .screen
        for i in 0..<40 {
            let c = colors[i % colors.count]
            let r = 18 + 90 * pow(rand(i, 9), 2)
            let speed = 6 + 18 * rand(i, 10)                     // points per second, upward
            let span = h + r * 2
            let y = h + r - (rand(i, 11) * span + t * speed).truncatingRemainder(dividingBy: span)
            let x = w * rand(i, 12) + 30 * sin(t * 0.15 + Double(i))
            let twinkle = 0.55 + 0.45 * sin(t * (0.3 + rand(i, 13) * 0.5) + Double(i))
            let alpha = (0.10 + 0.22 * rand(i, 14)) * twinkle
            let rect = CGRect(x: x - r, y: y - r, width: r * 2, height: r * 2)
            gc.fill(Path(ellipseIn: rect),
                    with: .radialGradient(Gradient(colors: [c.opacity(alpha), c.opacity(alpha * 0.7), c.opacity(0)]),
                                          center: CGPoint(x: x, y: y), startRadius: 0, endRadius: r))
        }
    }

    /// Translucent Metro squares gliding sideways on a grid.
    static func squares(_ gc: inout GraphicsContext, _ size: CGSize, _ t: Double, _ colors: [Color]) {
        let w = size.width, h = size.height
        let unit = max(40, min(w, h) / 9)
        for i in 0..<28 {
            let c = colors[i % colors.count]
            let s = unit * Double([1, 1, 2, 2, 3][Int(rand(i, 15) * 5) % 5])
            let speed = 4 + 10 * rand(i, 16)
            let span = w + s * 2
            let x = (rand(i, 17) * span + t * speed).truncatingRemainder(dividingBy: span) - s
            let row = floor(rand(i, 18) * (h / unit))
            let y = row * unit + unit * 0.1 * sin(t * 0.1 + Double(i))
            let alpha = 0.05 + 0.13 * rand(i, 19) * (0.7 + 0.3 * sin(t * 0.25 + Double(i)))
            gc.fill(Path(CGRect(x: x, y: y, width: s - 6, height: s - 6)), with: .color(c.opacity(alpha)))
        }
    }
}
