import AppKit
import AVFoundation
import ImageIO
import QuickLookThumbnailing

/// Finds the picture (or video) that's really on your desktop.
///
/// `NSWorkspace.desktopImageURL(for:)` is only reliable for plain picture files. Since macOS Sonoma,
/// Apple's built-in wallpapers, aerials (which are videos), dynamic wallpapers and photo shuffles
/// often report a placeholder, a `.madesktop` description file or a folder instead. So MacTiles also
/// reads the wallpaper store macOS keeps for System Settings, and checks the places Apple's own
/// wallpapers live.
enum DesktopPicture {
    enum Source: Equatable, Sendable {
        case file(URL)          // a picture or video MacTiles can show directly
        case quickLook(URL)     // something else; Quick Look can still draw a preview of it

        var url: URL {
            switch self {
            case .file(let u), .quickLook(let u): return u
            }
        }

        var isVideo: Bool { DesktopPicture.videoExtensions.contains(url.pathExtension.lowercased()) }
    }

    static let videoExtensions: Set<String> = ["mov", "mp4", "m4v"]
    static var imageExtensions: Set<String> { ImageLoader.extensions.union(["png", "jpg", "jpeg", "heic", "heif", "tiff", "tif", "bmp"]) }

    static let storeURL = URL(fileURLWithPath: NSHomeDirectory() + "/Library/Application Support/com.apple.wallpaper/Store/Index.plist")
    static let systemFolders = ["/System/Library/Desktop Pictures", "/System/Library/Desktop Pictures/.thumbnails", "/Library/Desktop Pictures"]
    static let aerialFolders = ["/Library/Application Support/com.apple.idleassetsd"]

    // MARK: What's on screen

    /// What macOS reports for the main display.
    @MainActor
    static func reportedURL() -> URL? {
        guard let screen = NSScreen.screens.first ?? NSScreen.main else { return nil }
        return NSWorkspace.shared.desktopImageURL(for: screen)
    }

    /// Changes whenever the wallpaper does, cheaply — so the picture is only re-read when needed.
    @MainActor
    static func fingerprint() -> String {
        let modified = (try? FileManager.default.attributesOfItem(atPath: storeURL.path)[.modificationDate] as? Date)?
            .timeIntervalSince1970 ?? 0
        return (reportedURL()?.path ?? "none") + "|" + String(modified)
    }

    /// Works out the best thing to show. Reads files, so call it off the main thread.
    static func resolve(reported: URL?) -> Source? {
        var seen = Set<String>()
        for url in candidates(reported: reported) where seen.insert(url.path).inserted {
            if isUsable(url) { return .file(url) }
        }
        if let reported, FileManager.default.fileExists(atPath: reported.path) { return .quickLook(reported) }
        return nil
    }

    /// In order of preference: what the wallpaper store says was set most recently, then what
    /// NSWorkspace reports (expanded if it's a folder or a description file).
    static func candidates(reported: URL?) -> [URL] {
        var out = storeCandidates()
        if let reported { out += expand(reported) }
        return out
    }

    /// A picture ImageIO can open, or a video file.
    static func isUsable(_ url: URL) -> Bool {
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory), !isDirectory.boolValue else { return false }
        let ext = url.pathExtension.lowercased()
        if videoExtensions.contains(ext) { return true }
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil) else { return false }
        return CGImageSourceGetCount(src) > 0
    }

    /// Turns a reported location into files worth trying.
    static func expand(_ url: URL) -> [URL] {
        let fm = FileManager.default
        var isDirectory: ObjCBool = false
        guard fm.fileExists(atPath: url.path, isDirectory: &isDirectory) else { return [] }
        let ext = url.pathExtension.lowercased()
        var out: [URL] = []
        if isDirectory.boolValue {
            // A photo-shuffle folder, or a wallpaper bundle: anything visual inside.
            out += ImageLoader.listImages(in: url.path, limit: 1)
            if let videos = try? fm.contentsOfDirectory(at: url, includingPropertiesForKeys: nil) {
                out += videos.filter { videoExtensions.contains($0.pathExtension.lowercased()) }.prefix(1)
            }
        } else if imageExtensions.contains(ext) || videoExtensions.contains(ext) {
            out.append(url)
        } else if let data = try? Data(contentsOf: url), data.count < 4_000_000,
                  let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) {
            // A .madesktop file describes an Apple wallpaper; its paths point at the artwork.
            var strings: [String] = []
            collectStrings(plist, into: &strings, depth: 0)
            out += files(in: strings)
        }
        // Apple's wallpapers keep a still of the same name in the system folders.
        out += systemPictures(matching: url.deletingPathExtension().lastPathComponent)
        return out
    }

    // MARK: The wallpaper store (System Settings → Wallpaper)

    static func storeCandidates() -> [URL] {
        guard let data = try? Data(contentsOf: storeURL),
              let root = try? PropertyListSerialization.propertyList(from: data, format: nil) else { return [] }
        return candidates(fromStore: root)
    }

    /// Picks the desktop setting that was changed most recently (the store keeps one for all
    /// displays, plus per-display and per-Space ones), then finds the files it names.
    static func candidates(fromStore root: Any) -> [URL] {
        var desktops: [(set: Date, content: Any)] = []
        findDesktops(root, into: &desktops, depth: 0)
        guard let latest = desktops.max(by: { $0.set < $1.set }) else { return [] }
        var strings: [String] = []
        collectStrings(latest.content, into: &strings, depth: 0)

        var out = files(in: strings)
        // Aerials are named by an asset ID; their videos (and stills) live with idleassetsd.
        let ids = strings.filter { UUID(uuidString: $0) != nil }
        if !ids.isEmpty { out += aerialFiles(ids: ids) }
        // Built-in wallpapers are named by their provider, e.g. com.apple.wallpaper.choice.sequoia.
        for provider in strings where provider.hasPrefix("com.apple.wallpaper.choice.") {
            let name = String(provider.dropFirst("com.apple.wallpaper.choice.".count))
            if !["image", "aerials", "photos", "color", "solid", "dynamic", "macintosh"].contains(name.lowercased()) {
                out += systemPictures(matching: name)
            }
        }
        return out
    }

    private static func findDesktops(_ node: Any, into out: inout [(set: Date, content: Any)], depth: Int) {
        guard depth < 12 else { return }
        if let dict = node as? [String: Any] {
            if let desktop = dict["Desktop"] as? [String: Any], let content = desktop["Content"] {
                out.append(((desktop["LastSet"] as? Date) ?? (desktop["LastUse"] as? Date) ?? .distantPast, content))
            }
            for value in dict.values { findDesktops(value, into: &out, depth: depth + 1) }
        } else if let array = node as? [Any] {
            for value in array { findDesktops(value, into: &out, depth: depth + 1) }
        }
    }

    /// Every string in a property list, including inside embedded (encoded) property lists.
    static func collectStrings(_ node: Any, into out: inout [String], depth: Int) {
        guard depth < 12, out.count < 2_000 else { return }
        if let s = node as? String {
            out.append(s)
        } else if let dict = node as? [String: Any] {
            for key in dict.keys.sorted() { collectStrings(dict[key] as Any, into: &out, depth: depth + 1) }
        } else if let array = node as? [Any] {
            for value in array { collectStrings(value, into: &out, depth: depth + 1) }
        } else if let data = node as? Data, data.count < 2_000_000 {
            if let inner = try? PropertyListSerialization.propertyList(from: data, format: nil) {
                collectStrings(inner, into: &out, depth: depth + 1)
            } else if let inner = try? JSONSerialization.jsonObject(with: data) {
                collectStrings(inner, into: &out, depth: depth + 1)
            }
        }
    }

    /// File URLs and absolute paths among the strings, expanded.
    static func files(in strings: [String]) -> [URL] {
        var out: [URL] = []
        for s in strings {
            let url: URL?
            if s.hasPrefix("file://") { url = URL(string: s) }
            else if s.hasPrefix("/") { url = URL(fileURLWithPath: s) }
            else if s.hasPrefix("~/") { url = URL(fileURLWithPath: NSHomeDirectory() + s.dropFirst(1)) }
            else { url = nil }
            guard let url, FileManager.default.fileExists(atPath: url.path) else { continue }
            let ext = url.pathExtension.lowercased()
            if imageExtensions.contains(ext) || videoExtensions.contains(ext) {
                out.append(url)
            } else if url.hasDirectoryPath || ext.isEmpty {
                out += ImageLoader.listImages(in: url.path, limit: 1)     // a shuffle folder
            }
        }
        return out
    }

    /// Stills first (they're light), then the videos, for aerial asset IDs.
    static func aerialFiles(ids: [String], roots: [String] = aerialFolders) -> [URL] {
        let wanted = Set(ids.map { $0.lowercased() })
        var stills: [URL] = [], videos: [URL] = []
        for root in roots {
            guard let e = FileManager.default.enumerator(at: URL(fileURLWithPath: root), includingPropertiesForKeys: nil) else { continue }
            var visited = 0
            for case let url as URL in e {
                visited += 1
                if visited > 20_000 { break }
                let name = url.lastPathComponent.lowercased()
                guard wanted.contains(where: { name.contains($0) }) else { continue }
                let ext = url.pathExtension.lowercased()
                if videoExtensions.contains(ext) { videos.append(url) }
                else if imageExtensions.contains(ext) { stills.append(url) }
            }
        }
        // A video shows the real, moving aerial; prefer it, with a still as the fallback.
        return videos + stills
    }

    /// Pictures in the system wallpaper folders whose name contains `name` (Sequoia, Sonoma…).
    static func systemPictures(matching name: String, folders: [String] = systemFolders) -> [URL] {
        let token = name.lowercased().replacingOccurrences(of: " ", with: "")
        guard token.count >= 3 else { return [] }
        var out: [URL] = []
        for folder in folders {
            guard let items = try? FileManager.default.contentsOfDirectory(atPath: folder) else { continue }
            for item in items.sorted() {
                let lowered = item.lowercased().replacingOccurrences(of: " ", with: "")
                let ext = (item as NSString).pathExtension.lowercased()
                if lowered.contains(token), imageExtensions.contains(ext) {
                    out.append(URL(fileURLWithPath: folder).appendingPathComponent(item))
                }
            }
        }
        return out
    }

    // MARK: Pictures

    /// A still of the source, at most `maxPixel` on its longest side. Videos give a frame from
    /// their first seconds; anything else is drawn by Quick Look.
    static func thumbnail(_ source: Source, maxPixel: Int) async -> Box<CGImage?> {
        let url = source.url
        switch source {
        case .file where source.isVideo:
            let asset = AVURLAsset(url: url)
            let generator = AVAssetImageGenerator(asset: asset)
            generator.appliesPreferredTrackTransform = true
            generator.maximumSize = CGSize(width: maxPixel, height: maxPixel)
            if let frame = try? await generator.image(at: CMTime(seconds: 2, preferredTimescale: 600)).image {
                return Box(frame)
            }
            return await quickLook(url, maxPixel: maxPixel)
        case .file:
            let image = await Task.detached(priority: .utility) { Box(ImageLoader.thumbnail(url, maxPixel: maxPixel)) }.value
            if image.value != nil { return image }
            return await quickLook(url, maxPixel: maxPixel)
        case .quickLook:
            return await quickLook(url, maxPixel: maxPixel)
        }
    }

    static func quickLook(_ url: URL, maxPixel: Int) async -> Box<CGImage?> {
        let side = CGFloat(maxPixel)
        let request = QLThumbnailGenerator.Request(fileAt: url, size: CGSize(width: side, height: side),
                                                   scale: 1, representationTypes: .thumbnail)
        let rep = try? await QLThumbnailGenerator.shared.generateBestRepresentation(for: request)
        return Box(rep?.cgImage)
    }

    /// Resolve and draw in one step (the Desktop tile and the Settings preview).
    @MainActor
    static func currentThumbnail(maxPixel: Int) async -> (source: Source?, image: NSImage?) {
        let reported = reportedURL()
        let source = await Task.detached(priority: .utility) { DesktopPicture.resolve(reported: reported) }.value
        guard let source else { return (nil, nil) }
        let cg = await thumbnail(source, maxPixel: maxPixel).value
        return (source, cg.map { NSImage(cgImage: $0, size: .zero) })
    }
}
