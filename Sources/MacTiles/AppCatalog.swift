import AppKit

struct AppInfo: Identifiable, Hashable {
    let path: String
    let name: String
    var id: String { path }
    var url: URL { URL(fileURLWithPath: path) }
}

/// Knows which apps are installed, plus cached names, icons and tile tints.
/// Watches the Applications folders, so apps you install, update or delete
/// appear in (or leave) All apps and search within a few seconds.
@MainActor
final class AppCatalog: ObservableObject {
    @Published private(set) var apps: [AppInfo] = []

    private var names: [String: String] = [:]
    private var tints: [String: String] = [:]
    private let icons = NSCache<NSString, NSImage>()
    private var scanning = false
    private var rescanRequested = false
    private var watcher: FolderWatcher?
    private var pendingScan: Task<Void, Never>?

    init() { icons.countLimit = 400 }

    /// Scans now and keeps watching for changes.
    func startWatching() {
        refresh()
        guard watcher == nil else { return }
        watcher = FolderWatcher(paths: AppScanner.watchedRoots) { [weak self] changed in
            self?.foldersChanged(changed)
        }
    }

    func refresh() {
        guard !scanning else {
            rescanRequested = true      // something changed mid-scan; scan again when this one ends
            return
        }
        scanning = true
        Task {
            let found = await Task.detached(priority: .utility) { AppScanner.scan() }.value
            for app in found { self.names[app.path] = app.name }
            if found != self.apps { self.apps = found }
            self.scanning = false
            if self.rescanRequested {
                self.rescanRequested = false
                self.refresh()
            }
        }
    }

    private func foldersChanged(_ paths: [String]) {
        // Forget cached names, icons and tints of apps that changed, so an updated app shows its new icon.
        for bundle in Set(paths.compactMap(AppScanner.enclosingBundle)) {
            names[bundle] = nil
            tints[bundle] = nil
            icons.removeObject(forKey: bundle as NSString)
        }
        // Copying an app writes thousands of files; wait until it has been quiet for a moment.
        pendingScan?.cancel()
        pendingScan = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 1_500_000_000)
            guard !Task.isCancelled, let self else { return }
            self.refresh()
            // A big app can still be finishing (or be signed/translocated) after the first scan; check once more.
            try? await Task.sleep(nanoseconds: 6_000_000_000)
            guard !Task.isCancelled else { return }
            self.forgetGenericIcons()
            self.refresh()
        }
    }

    /// An app scanned while it was still copying may have been given the generic icon; drop it so it reloads.
    private func forgetGenericIcons() {
        icons.removeAllObjects()
        tints.removeAll()
        objectWillChange.send()
    }

    func name(for path: String) -> String {
        if let n = names[path] { return n }
        let n = AppScanner.displayName(path)
        names[path] = n
        return n
    }

    func icon(for path: String) -> NSImage {
        if let cached = icons.object(forKey: path as NSString) { return cached }
        let image = NSWorkspace.shared.icon(forFile: path)
        image.size = NSSize(width: 256, height: 256)
        icons.setObject(image, forKey: path as NSString)
        return image
    }

    func tint(for path: String) -> String {
        if let t = tints[path] { return t }
        let t = IconTint.hex(for: icon(for: path)) ?? Palette.autoColor(for: path)
        tints[path] = t
        return t
    }
}

enum AppScanner {
    static let roots = [
        "/Applications",
        "/Applications/Utilities",
        "/System/Applications",
        "/System/Applications/Utilities",
        NSHomeDirectory() + "/Applications",
    ]

    /// /System/Applications only changes with macOS updates, so it isn't watched.
    static let watchedRoots = ["/Applications", NSHomeDirectory() + "/Applications"]

    /// "/Applications/Foo.app/Contents/Info.plist" → "/Applications/Foo.app"
    static func enclosingBundle(_ path: String) -> String? {
        guard let range = path.range(of: ".app", options: .caseInsensitive) else { return nil }
        let end = range.upperBound
        guard end == path.endIndex || path[end] == "/" else { return nil }
        return String(path[..<end])
    }

    static func scan() -> [AppInfo] {
        let fm = FileManager.default
        var seen = Set<String>()
        var out: [AppInfo] = []

        func add(_ path: String) {
            let resolved = (path as NSString).resolvingSymlinksInPath
            guard seen.insert(resolved).inserted else { return }
            out.append(AppInfo(path: path, name: displayName(path)))
        }

        func visit(_ dir: String, depth: Int) {
            guard let items = try? fm.contentsOfDirectory(atPath: dir) else { return }
            for item in items where !item.hasPrefix(".") {
                let path = (dir as NSString).appendingPathComponent(item)
                if item.hasSuffix(".app") {
                    // Skip a bundle that is still being copied (no Info.plist yet); the watcher rescans when it's done.
                    guard fm.fileExists(atPath: path + "/Contents/Info.plist") || fm.fileExists(atPath: path + "/Info.plist")
                            || fm.fileExists(atPath: path + "/Wrapper") else { continue }
                    add(path)
                } else if depth < 2 {
                    var isDir: ObjCBool = false
                    if fm.fileExists(atPath: path, isDirectory: &isDir), isDir.boolValue {
                        visit(path, depth: depth + 1)
                    }
                }
            }
        }

        for root in roots { visit(root, depth: 0) }
        add("/System/Library/CoreServices/Finder.app")

        return out.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    static func displayName(_ path: String) -> String {
        var name = FileManager.default.displayName(atPath: path)
        if name.lowercased().hasSuffix(".app") { name = String(name.dropLast(4)) }
        return name
    }
}

/// "Start typing" search, ranked like the Windows 8 search charm.
enum AppSearch {
    static func rank(_ query: String, in apps: [AppInfo]) -> [AppInfo] {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !q.isEmpty else { return [] }
        var scored: [(score: Int, app: AppInfo)] = []
        for app in apps {
            let n = app.name.lowercased()
            let score: Int?
            if n == q { score = 0 }
            else if n.hasPrefix(q) { score = 1 }
            else if n.split(separator: " ").contains(where: { $0.hasPrefix(q) }) { score = 2 }
            else if n.contains(q) { score = 3 }
            else if isSubsequence(q, of: n) { score = 4 }   // "vsc" → Visual Studio Code
            else { score = nil }
            if let score { scored.append((score, app)) }
        }
        return scored
            .sorted { $0.score != $1.score ? $0.score < $1.score : $0.app.name.count < $1.app.name.count }
            .map(\.app)
    }

    private static func isSubsequence(_ needle: String, of hay: String) -> Bool {
        var it = needle.makeIterator()
        var want = it.next()
        for ch in hay where ch == want {
            want = it.next()
            if want == nil { return true }
        }
        return want == nil
    }
}
