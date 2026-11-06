import AppKit
import SwiftUI

struct NamedColor: Hashable {
    let name: String
    let hex: String
}

/// The Windows 8 "Metro" palette.
enum Palette {
    static let named: [NamedColor] = [
        NamedColor(name: "Blue", hex: "#2D89EF"),
        NamedColor(name: "Cobalt", hex: "#2B5797"),
        NamedColor(name: "Teal", hex: "#00ABA9"),
        NamedColor(name: "Emerald", hex: "#00A300"),
        NamedColor(name: "Forest", hex: "#1E7145"),
        NamedColor(name: "Lime", hex: "#99B433"),
        NamedColor(name: "Plum", hex: "#7E3878"),
        NamedColor(name: "Violet", hex: "#603CBA"),
        NamedColor(name: "Magenta", hex: "#FF0097"),
        NamedColor(name: "Red", hex: "#EE1111"),
        NamedColor(name: "Crimson", hex: "#B91D47"),
        NamedColor(name: "Amber", hex: "#E3A21A"),
        NamedColor(name: "Orange", hex: "#DA532C"),
        NamedColor(name: "Yellow", hex: "#FFC40D"),
    ]

    static var accents: [String] { named.map(\.hex) }

    /// Start-screen backgrounds.
    static let backgrounds: [String] = [
        "#25115A", "#1F0068", "#2D004E", "#4E0038", "#4E0000",
        "#3B1F00", "#003E00", "#004050", "#002050", "#1D1D1D",
    ]

    /// Stable across launches (unlike `hashValue`), so a tile keeps its color.
    static func stableIndex(_ s: String, modulo: Int) -> Int {
        var h: UInt64 = 5381
        for b in s.utf8 { h = (h &* 33) &+ UInt64(b) }
        return Int(h % UInt64(max(modulo, 1)))
    }

    /// "25115a", "#25115A", " #25115a " → "#25115A"; anything else → nil.
    static func normalizedHex(_ input: String) -> String? {
        var s = input.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        if s.hasPrefix("#") { s.removeFirst() }
        guard s.count == 6, s.allSatisfy({ $0.isHexDigit }) else { return nil }
        return "#" + s
    }

    static func autoColor(for key: String) -> String {
        accents[stableIndex(key, modulo: accents.count)]
    }
}

extension Color {
    init(hex: String) {
        let s = hex.trimmingCharacters(in: CharacterSet(charactersIn: "# "))
        var v: UInt64 = 0
        Scanner(string: s).scanHexInt64(&v)
        if s.count == 6 {
            self.init(.sRGB,
                      red: Double((v >> 16) & 0xFF) / 255,
                      green: Double((v >> 8) & 0xFF) / 255,
                      blue: Double(v & 0xFF) / 255,
                      opacity: 1)
        } else {
            self.init(.sRGB, red: 0.2, green: 0.2, blue: 0.2, opacity: 1)
        }
    }
}

extension NSColor {
    var hexString: String {
        let c = usingColorSpace(.sRGB) ?? self
        func byte(_ x: CGFloat) -> Int { Int((min(max(x, 0), 1) * 255).rounded()) }
        return String(format: "#%02X%02X%02X", byte(c.redComponent), byte(c.greenComponent), byte(c.blueComponent))
    }
}

/// Derives a flat, Metro-friendly tile color from an app icon.
enum IconTint {
    static func hex(for image: NSImage) -> String? {
        guard let cg = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return nil }
        let side = 8
        var px = [UInt8](repeating: 0, count: side * side * 4)
        let drawn: Bool = px.withUnsafeMutableBytes { buf -> Bool in
            guard let ctx = CGContext(data: buf.baseAddress, width: side, height: side, bitsPerComponent: 8,
                                      bytesPerRow: side * 4, space: CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
            ctx.interpolationQuality = .medium
            ctx.draw(cg, in: CGRect(x: 0, y: 0, width: side, height: side))
            return true
        }
        guard drawn else { return nil }

        var r = 0.0, g = 0.0, b = 0.0, a = 0.0
        for i in stride(from: 0, to: px.count, by: 4) {
            r += Double(px[i]); g += Double(px[i + 1]); b += Double(px[i + 2]); a += Double(px[i + 3])
        }
        guard a > 0 else { return nil }
        let color = NSColor(srgbRed: CGFloat(min(1, r / a)), green: CGFloat(min(1, g / a)),
                            blue: CGFloat(min(1, b / a)), alpha: 1)
        var h: CGFloat = 0, s: CGFloat = 0, v: CGFloat = 0, alpha: CGFloat = 0
        color.getHue(&h, saturation: &s, brightness: &v, alpha: &alpha)
        let tuned = NSColor(hue: h, saturation: min(1, s * 1.3 + 0.1),
                            brightness: min(0.72, max(0.38, v * 0.85)), alpha: 1)
        return tuned.hexString
    }
}

/// Lets non-Sendable values (CGImage, NSImage) come back from detached tasks.
struct Box<T>: @unchecked Sendable {
    let value: T
    init(_ value: T) { self.value = value }
}

// MARK: - Tile surface

/// What's behind a tile's content: a flat Metro color, or tinted glass over the wallpaper.
@MainActor
struct TileSurface: View {
    let color: Color
    let finish: TileFinish
    let glassTint: Double

    var body: some View {
        switch finish {
        case .flat:
            color
        case .glass:
            ZStack {
                // Blurs whatever is behind the tile: the wallpaper, live wallpaper or color.
                Rectangle().fill(.ultraThinMaterial)
                // The tint is lighter at the top and richer at the bottom, like light passing
                // through a thick pane.
                LinearGradient(colors: [color.opacity(glassTint * 0.7), color.opacity(min(1, glassTint * 1.3))],
                               startPoint: .top, endPoint: .bottom)
            }
            .environment(\.colorScheme, .dark)
        }
    }
}

/// Everything that makes a pane read as polished glass, drawn over the tile's content
/// (so photo and desktop tiles look glassy too).
@MainActor
struct GlassOverlay<S: InsettableShape>: View {
    let shape: S
    let size: CGSize
    /// Where the pointer is over the tile, for the moving glint (nil when not hovering).
    let pointer: CGPoint?
    /// 0 → 1 while the hover shimmer sweeps across.
    let shimmer: Double

    var body: some View {
        let w = size.width, h = size.height
        ZStack {
            // 1. The classic curved gloss: a big ellipse of reflected light across the top half.
            Ellipse()
                .fill(LinearGradient(colors: [Color.white.opacity(0.34), Color.white.opacity(0.10), Color.white.opacity(0.02)],
                                     startPoint: .top, endPoint: .bottom))
                .frame(width: w * 1.7, height: h * 1.05)
                .offset(x: -w * 0.12, y: -h * 0.56)

            // 3. Depth: a little shade pooling at the bottom edge of the pane.
            LinearGradient(colors: [.clear, .clear, Color.black.opacity(0.22)], startPoint: .top, endPoint: .bottom)

            // 4. A glint that follows the pointer.
            if let p = pointer {
                RadialGradient(colors: [Color.white.opacity(0.32), Color.white.opacity(0.08), .clear],
                               center: UnitPoint(x: p.x / max(w, 1), y: p.y / max(h, 1)),
                               startRadius: 0, endRadius: max(w, h) * 0.75)
                    .blendMode(.plusLighter)
                    .transition(.opacity)
            }

            // 5. A bright band that sweeps across once when you hover.
            if shimmer > 0 && shimmer < 1 {
                Rectangle()
                    .fill(LinearGradient(colors: [.clear, Color.white.opacity(0.38), .clear], startPoint: .leading, endPoint: .trailing))
                    .frame(width: max(w, h) * 0.35, height: max(w, h) * 2.4)
                    .rotationEffect(.degrees(24))
                    .offset(x: (shimmer * 2 - 1) * (w + max(w, h) * 0.5))
                    .blendMode(.plusLighter)
            }

            // 6. A polished rim: light catches the top-left edge, fades along the sides,
            //    and glows faintly again at the bottom; a second inner line gives the edge thickness.
            shape.strokeBorder(
                AngularGradient(colors: [Color.white.opacity(0.85), Color.white.opacity(0.25), Color.white.opacity(0.10),
                                         Color.white.opacity(0.35), Color.white.opacity(0.10), Color.white.opacity(0.30),
                                         Color.white.opacity(0.85)],
                                center: .center, angle: .degrees(-135)),
                lineWidth: 1.3)
            shape.inset(by: 1.5).strokeBorder(Color.white.opacity(0.10), lineWidth: 1)
        }
        .frame(width: w, height: h)
        .clipShape(shape)
        .allowsHitTesting(false)
    }
}
