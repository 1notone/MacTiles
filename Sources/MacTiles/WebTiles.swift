import AppKit
import SwiftUI

// MARK: - Addresses

enum WebLink {
    /// "apple.com", "https://apple.com/mac", "localhost:3000/docs", "mailto:me@x.com" → a URL to open.
    /// Bare addresses get https://. Returns nil for things that aren't addresses.
    static func normalize(_ input: String) -> URL? {
        let s = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !s.isEmpty, s.rangeOfCharacter(from: .whitespacesAndNewlines) == nil else { return nil }

        let lower = s.lowercased()
        let explicitScheme = s.range(of: "^[A-Za-z][A-Za-z0-9+.-]*://", options: .regularExpression) != nil
        let opaqueSchemes = ["mailto:", "tel:", "sms:", "facetime:", "facetime-audio:", "maps:", "x-apple.systempreferences:"]
        if opaqueSchemes.contains(where: { lower.hasPrefix($0) }) {
            return URL(string: s)
        }
        let candidate = explicitScheme ? s : "https://" + s
        guard let url = URL(string: candidate), let scheme = url.scheme?.lowercased() else { return nil }
        if scheme == "http" || scheme == "https" {
            guard let host = url.host, isPlausibleHost(host) else { return nil }
        }
        return url
    }

    private static func isPlausibleHost(_ host: String) -> Bool {
        let h = host.lowercased()
        if h == "localhost" { return true }
        if h.range(of: #"^\d{1,3}(\.\d{1,3}){3}$"#, options: .regularExpression) != nil { return true }   // IPv4
        if h.contains(":") { return true }                                                             // IPv6
        let parts = h.split(separator: ".")
        return parts.count >= 2 && parts.allSatisfy { !$0.isEmpty } && (parts.last?.count ?? 0) >= 2
    }

    /// "www.apple.com" → "apple.com"; used as the label when there's no name.
    static func displayHost(_ url: URL) -> String {
        guard let host = url.host?.lowercased() else { return url.absoluteString }
        return host.hasPrefix("www.") ? String(host.dropFirst(4)) : host
    }

    static func url(of tile: Tile) -> URL? {
        tile.url.flatMap { URL(string: $0) }
    }

    static func isFetchable(_ url: URL) -> Bool {
        ["http", "https"].contains(url.scheme?.lowercased() ?? "")
    }
}

// MARK: - Reading a page's icon and title

enum WebPage {
    /// The page's <title>, tidied up.
    static func title(in html: String) -> String? {
        guard let range = html.range(of: #"<title[^>]*>([\s\S]*?)</title>"#, options: [.regularExpression, .caseInsensitive]) else { return nil }
        var t = String(html[range])
        t = t.replacingOccurrences(of: #"<[^>]+>"#, with: "", options: .regularExpression)
        t = decodeEntities(t)
        t = t.replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression).trimmingCharacters(in: .whitespaces)
        guard !t.isEmpty else { return nil }
        return t.count > 60 ? String(t.prefix(59)) + "…" : t
    }

    /// An icon a page declares, with the size it claims (0 = unknown).
    struct IconCandidate: Equatable {
        let url: URL
        let size: Int
    }

    /// Icons declared in the page — apple-touch-icon, <link rel="icon">, and the web app manifest
    /// address (returned separately) — best (largest) first.
    static func iconCandidates(in html: String, base: URL) -> (icons: [IconCandidate], manifest: URL?) {
        var found: [(candidate: IconCandidate, rank: Int)] = []
        var manifest: URL?
        let tagRegex = try? NSRegularExpression(pattern: #"<link\b[^>]*>"#, options: [.caseInsensitive])
        let ns = html as NSString
        for match in tagRegex?.matches(in: html, range: NSRange(location: 0, length: ns.length)) ?? [] {
            let attrs = attributes(of: ns.substring(with: match.range))
            guard let rel = attrs["rel"]?.lowercased(), let href = attrs["href"], !href.isEmpty,
                  let url = URL(string: href, relativeTo: base)?.absoluteURL else { continue }
            let rels = rel.split(separator: " ")
            if rels.contains("manifest") { manifest = manifest ?? url; continue }
            let declared = parseSizes(attrs["sizes"])
            if rel.contains("apple-touch-icon") {
                found.append((IconCandidate(url: url, size: declared > 0 ? declared : 180), 0))
            } else if rels.contains("icon") {
                found.append((IconCandidate(url: url, size: declared > 0 ? declared : 32), 1))
            }
        }
        let sorted = found.sorted { $0.candidate.size != $1.candidate.size ? $0.candidate.size > $1.candidate.size : $0.rank < $1.rank }
        return (dedupe(sorted.map(\.candidate)), manifest)
    }

    /// Icons listed in a web app manifest (often 192 px and 512 px — the sharpest a site offers).
    static func manifestIcons(_ data: Data, base: URL) -> [IconCandidate] {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let icons = json["icons"] as? [[String: Any]] else { return [] }
        let found: [IconCandidate] = icons.compactMap { icon in
            guard let src = icon["src"] as? String, let url = URL(string: src, relativeTo: base)?.absoluteURL else { return nil }
            let purpose = (icon["purpose"] as? String ?? "any").lowercased()
            if !purpose.split(separator: " ").contains("any") && purpose.contains("monochrome") { return nil }
            return IconCandidate(url: url, size: parseSizes(icon["sizes"] as? String))
        }
        return found.sorted { $0.size > $1.size }
    }

    /// The conventional locations, for sites that don't declare their icons.
    static func conventionalIcons(for page: URL) -> [IconCandidate] {
        guard let root = URL(string: "/", relativeTo: page)?.absoluteURL else { return [] }
        return [
            IconCandidate(url: root.appendingPathComponent("apple-touch-icon.png"), size: 180),
            IconCandidate(url: root.appendingPathComponent("apple-touch-icon-precomposed.png"), size: 180),
            IconCandidate(url: root.appendingPathComponent("favicon.ico"), size: 32),
        ]
    }

    /// Last resort when a site blocks or hides its icon: Google's public favicon service
    /// (it receives only the site's domain).
    static func fallbackIcon(for host: String) -> IconCandidate? {
        guard var c = URLComponents(string: "https://www.google.com/s2/favicons") else { return nil }
        c.queryItems = [URLQueryItem(name: "domain", value: host), URLQueryItem(name: "sz", value: "256")]
        return c.url.map { IconCandidate(url: $0, size: 64) }
    }

    /// "16x16 32x32" → 32; "any" → 512 (a vector icon).
    static func parseSizes(_ sizes: String?) -> Int {
        let s = (sizes ?? "").lowercased()
        if s.contains("any") { return 512 }
        return s.split(separator: " ").compactMap { $0.split(separator: "x").first.flatMap { Int($0) } }.max() ?? 0
    }

    static func dedupe(_ list: [IconCandidate]) -> [IconCandidate] {
        var seen = Set<String>()
        return list.filter { seen.insert($0.url.absoluteString).inserted }
    }

    static func attributes(of tag: String) -> [String: String] {
        var out: [String: String] = [:]
        guard let re = try? NSRegularExpression(pattern: #"([A-Za-z][\w:-]*)\s*=\s*(?:"([^"]*)"|'([^']*)'|([^\s"'>]+))"#) else { return out }
        let ns = tag as NSString
        for m in re.matches(in: tag, range: NSRange(location: 0, length: ns.length)) {
            let name = ns.substring(with: m.range(at: 1)).lowercased()
            for i in 2...4 where m.range(at: i).location != NSNotFound {
                out[name] = decodeEntities(ns.substring(with: m.range(at: i)))
                break
            }
        }
        return out
    }

    static func decodeEntities(_ s: String) -> String {
        var t = s
        for (k, v) in [("&amp;", "&"), ("&lt;", "<"), ("&gt;", ">"), ("&quot;", "\""), ("&#39;", "'"),
                       ("&#x27;", "'"), ("&apos;", "'"), ("&nbsp;", " "), ("&ndash;", "–"), ("&mdash;", "—")] {
            t = t.replacingOccurrences(of: k, with: v, options: .caseInsensitive)
        }
        return t
    }
}

/// Fetches and remembers each site's icon and page title, on disk, so tiles look right offline.
@MainActor
final class WebIconCache: ObservableObject {
    @Published private(set) var icons: [String: NSImage] = [:]       // by host
    @Published private(set) var titles: [String: String] = [:]       // by URL
    private var tints: [String: String] = [:]
    private var diskIcons: [String: NSImage] = [:]      // read from disk on demand; not published (read during drawing)
    private var inFlight = Set<String>()
    private var failedAt: [String: Date] = [:]          // don't retry a site that has no icon on every redraw

    static let directory: URL = FileManager.default
        .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("MacTiles/WebIcons", isDirectory: true)
    private static var titlesFile: URL { directory.appendingPathComponent("titles.json") }

    private let session: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 10
        config.timeoutIntervalForResource = 20
        config.httpAdditionalHeaders = [
            "User-Agent": "Mozilla/5.0 (Macintosh; Intel Mac OS X 14_0) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Safari/605.1.15",
            "Accept-Language": Locale.preferredLanguages.first ?? "en",
        ]
        return URLSession(configuration: config)
    }()

    init() {
        if let data = try? Data(contentsOf: Self.titlesFile),
           let saved = try? JSONDecoder().decode([String: String].self, from: data) {
            titles = saved
        }
    }

    func icon(for url: URL) -> NSImage? {
        let host = WebLink.displayHost(url)
        if let image = icons[host] ?? diskIcons[host] { return image }
        if let image = NSImage(contentsOf: Self.iconFile(host)) {
            diskIcons[host] = image
            return image
        }
        return nil
    }

    func title(for url: URL) -> String? { titles[url.absoluteString] }

    /// Tile color from the site's icon, for "Color app tiles from their icons".
    func tint(for url: URL) -> String? {
        let host = WebLink.displayHost(url)
        if let t = tints[host] { return t }
        guard let image = icon(for: url), let t = IconTint.hex(for: image) else { return nil }
        tints[host] = t
        return t
    }

    /// Fetches the site's own icon and the page title if we don't have them yet.
    func load(_ url: URL, force: Bool = false) {
        guard WebLink.isFetchable(url) else { return }
        let host = WebLink.displayHost(url)
        let key = url.absoluteString
        if !force, let failed = failedAt[key], Date().timeIntervalSince(failed) < 30 * 60 { return }
        let needIcon = force || icon(for: url) == nil
        let needTitle = force || titles[key] == nil
        guard needIcon || needTitle, inFlight.insert(key).inserted else { return }
        if force {
            icons[host] = nil
            diskIcons[host] = nil
            tints[host] = nil
        }
        Task {
            defer { self.inFlight.remove(key) }

            // 1. The page itself: its title, and the icons it declares. Follow redirects
            //    (apple.com → www.apple.com) so relative icon addresses resolve correctly.
            var html = ""
            var base = url
            if let page = try? await session.data(from: url) {
                base = page.1.url ?? url
                if (page.1 as? HTTPURLResponse).map({ (200..<400).contains($0.statusCode) }) ?? true {
                    let slice = page.0.prefix(768 * 1024)
                    html = String(data: slice, encoding: .utf8) ?? String(data: slice, encoding: .isoLatin1) ?? ""
                    if let t = WebPage.title(in: html) {
                        titles[key] = t
                        saveTitles()
                    }
                }
            }
            guard needIcon else { return }

            // 2. Every place the site might keep its icon, sharpest first.
            let declared = WebPage.iconCandidates(in: html, base: base)
            var candidates = declared.icons
            if let manifest = declared.manifest, WebLink.isFetchable(manifest),
               let data = try? await session.data(from: manifest).0, data.count <= 1_000_000 {
                candidates += WebPage.manifestIcons(data, base: manifest)
            }
            candidates.sort { $0.size > $1.size }
            candidates += WebPage.conventionalIcons(for: base)
            if base.host != url.host { candidates += WebPage.conventionalIcons(for: url) }
            if let fallback = WebPage.fallbackIcon(for: base.host ?? host) { candidates.append(fallback) }

            // 3. Keep the best one; stop as soon as it's big enough to fill a tile.
            var best: NSImage?
            for candidate in WebPage.dedupe(candidates).prefix(12) {
                guard let image = await fetchImage(candidate.url) else { continue }
                if best == nil || Self.pixelWidth(image) > Self.pixelWidth(best!) { best = image }
                if Self.pixelWidth(image) >= 120 { break }
            }
            if let best {
                icons[host] = best
                tints[host] = nil
                saveIcon(best, host: host)
                failedAt[key] = nil
            } else {
                failedAt[key] = Date()
            }
        }
    }

    private func fetchImage(_ url: URL) async -> NSImage? {
        // Only web addresses: a page can't make MacTiles read a local file (file://) as its icon.
        guard WebLink.isFetchable(url), let result = try? await session.data(from: url) else { return nil }
        let (data, response) = result
        guard ((response as? HTTPURLResponse)?.statusCode ?? 200) < 400,
              !data.isEmpty, data.count <= 4_000_000, let image = NSImage(data: data) else { return nil }
        // Vector icons (SVG) report no pixels; treat them as large.
        return Self.pixelWidth(image) >= 16 ? image : nil
    }

    static func pixelWidth(_ image: NSImage) -> Int {
        let pixels = image.representations.map(\.pixelsWide).max() ?? 0
        return pixels > 0 ? pixels : (image.size.width > 0 ? 512 : 0)      // vector images have no pixel size
    }

    private static func iconFile(_ host: String) -> URL {
        let safe = host.replacingOccurrences(of: "[^A-Za-z0-9.-]", with: "_", options: .regularExpression)
        return directory.appendingPathComponent(safe + ".v2.png")     // v2: sharper icons; older cached ones are refetched
    }

    private func saveIcon(_ image: NSImage, host: String) {
        guard let tiff = image.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff),
              let png = rep.representation(using: .png, properties: [:]) else { return }
        try? FileManager.default.createDirectory(at: Self.directory, withIntermediateDirectories: true)
        try? png.write(to: Self.iconFile(host), options: .atomic)
    }

    private func saveTitles() {
        try? FileManager.default.createDirectory(at: Self.directory, withIntermediateDirectories: true)
        if let data = try? JSONEncoder().encode(titles) { try? data.write(to: Self.titlesFile, options: .atomic) }
    }
}

// MARK: - The tile

@MainActor
struct WebTileContent: View {
    let tile: Tile
    let frame: CGSize
    @EnvironmentObject private var webIcons: WebIconCache

    private var url: URL? { WebLink.url(of: tile) }

    private var name: String {
        if let t = tile.title, !t.isEmpty { return t }
        guard let url else { return "Web Link" }
        return webIcons.title(for: url) ?? WebLink.displayHost(url)
    }

    private var iconSide: CGFloat {
        switch tile.size {
        case .small: return frame.width * 0.62
        case .medium: return frame.height * 0.42
        case .wide: return frame.height * 0.46
        case .large: return frame.height * 0.36
        }
    }

    var body: some View {
        ZStack(alignment: .bottomLeading) {
            icon
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .offset(y: tile.size == .small ? 0 : -6)
            if tile.size != .small {
                if tile.size != .medium, let url, name != WebLink.displayHost(url) {
                    Text(WebLink.displayHost(url))
                        .font(.system(size: 11))
                        .opacity(0.8)
                        .lineLimit(1)
                        .padding(10)
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                }
                TileLabel(text: name)
            }
        }
        .onAppear { if let url { webIcons.load(url) } }
    }

    @ViewBuilder private var icon: some View {
        if let url, let image = webIcons.icon(for: url) {
            // Favicons are often tiny: don't blow them up into a blur.
            let native = CGFloat(image.representations.map(\.pixelsWide).max() ?? 32) / 2
            let side = min(iconSide, max(native, iconSide * 0.55))
            Image(nsImage: image)
                .resizable()
                .interpolation(.high)
                .aspectRatio(contentMode: .fit)
                .frame(width: side, height: side)
                .clipShape(RoundedRectangle(cornerRadius: side * 0.18, style: .continuous))
                .shadow(color: .black.opacity(0.2), radius: 2, y: 1)
        } else {
            Image(systemName: "globe")
                .font(.system(size: iconSide * 0.75, weight: .light))
        }
    }
}

// MARK: - Adding and editing

struct WebTileDraft: Identifiable, Equatable {
    let id = UUID()
    var tileID: UUID?
    var address: String
    var name: String
    var destination: TileDestination?
}

/// A Metro-style panel over the Start screen for adding or editing a web tile.
@MainActor
struct WebTileEditor: View {
    let draft: WebTileDraft
    @EnvironmentObject private var launcher: Launcher
    @EnvironmentObject private var store: LayoutStore
    @EnvironmentObject private var webIcons: WebIconCache
    @State private var address = ""
    @State private var name = ""
    @State private var error = ""
    @FocusState private var focus: Field?

    enum Field { case address, name }

    private var isEditing: Bool { draft.tileID != nil }

    var body: some View {
        ZStack {
            Color.black.opacity(0.55)
                .ignoresSafeArea()
                .onTapGesture(perform: cancel)
            VStack(alignment: .leading, spacing: 16) {
                Text(isEditing ? "Edit web tile" : "Add a web tile")
                    .font(.system(size: 28, weight: .light))
                field("Address", text: $address, prompt: "example.com", field: .address)
                field("Name (optional)", text: $name, prompt: WebLink.normalize(address).map(WebLink.displayHost) ?? "Shown on the tile", field: .name)
                if !error.isEmpty {
                    Text(error).font(.system(size: 12)).foregroundStyle(Color(hex: "#FF8A80"))
                }
                Text(WebLink.normalize(address).map(WebLink.isFetchable) == false ? "Opens in the app that handles this kind of link." : "Opens in your default browser.")
                    .font(.system(size: 12)).opacity(0.6)
                HStack(spacing: 10) {
                    Spacer()
                    Button("Cancel", action: cancel)
                        .buttonStyle(MetroButtonStyle(filled: false))
                    Button(isEditing ? "Save" : "Add", action: save)
                        .buttonStyle(MetroButtonStyle(filled: true))
                }
            }
            .foregroundStyle(.white)
            .padding(28)
            .frame(width: 480)
            .background(Color(hex: "#1D1D1D"))
            .overlay(Rectangle().strokeBorder(Color.white.opacity(0.12), lineWidth: 1))
            .shadow(color: .black.opacity(0.5), radius: 30, y: 10)
        }
        .onAppear {
            address = draft.address
            name = draft.name
            Task { @MainActor in
                try? await Task.sleep(nanoseconds: 80_000_000)
                focus = .address
            }
        }
        .onExitCommand(perform: cancel)
    }

    private func field(_ label: String, text: Binding<String>, prompt: String, field: Field) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(label).font(.system(size: 12, weight: .semibold)).opacity(0.75)
            TextField("", text: text, prompt: Text(prompt).foregroundColor(.white.opacity(0.35)))
                .textFieldStyle(.plain)
                .font(.system(size: 15))
                .padding(.horizontal, 10)
                .padding(.vertical, 8)
                .background(Color.white.opacity(focus == field ? 0.16 : 0.09))
                .focused($focus, equals: field)
                .onSubmit(save)
        }
    }

    private func save() {
        guard let url = WebLink.normalize(address) else {
            error = "That doesn't look like a web address. Try something like apple.com."
            focus = .address
            return
        }
        let title = name.trimmingCharacters(in: .whitespacesAndNewlines)
        withAnimation(.spring(response: 0.35, dampingFraction: 0.85)) {
            if let id = draft.tileID {
                store.update(id) {
                    $0.url = url.absoluteString
                    $0.title = title.isEmpty ? nil : title
                }
            } else {
                store.addWeb(url: url.absoluteString, title: title.isEmpty ? nil : title, at: draft.destination ?? .lastGroup)
            }
        }
        webIcons.load(url)
        launcher.webDraft = nil
    }

    private func cancel() { launcher.webDraft = nil }
}

struct MetroButtonStyle: ButtonStyle {
    let filled: Bool

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 14, weight: .semibold))
            .foregroundStyle(filled ? Color.black : Color.white)
            .padding(.horizontal, 18)
            .padding(.vertical, 7)
            .background(filled ? Color.white.opacity(configuration.isPressed ? 0.75 : 0.95) : Color.white.opacity(configuration.isPressed ? 0.2 : 0.1))
            .overlay(Rectangle().strokeBorder(Color.white.opacity(filled ? 0 : 0.6), lineWidth: 1.5))
            .scaleEffect(configuration.isPressed ? 0.97 : 1)
    }
}
