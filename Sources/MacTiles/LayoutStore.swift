import Foundation
import SwiftUI
import UniformTypeIdentifiers

enum TileDestination: Equatable {
    case before(UUID)
    case endOf(UUID)
    case newGroup
    case lastGroup
}

/// Owns the Start layout and settings, persisted to
/// ~/Library/Application Support/MacTiles/layout.json (human-readable, safe to hand-edit).
@MainActor
final class LayoutStore: ObservableObject {
    @Published var groups: [TileGroup] = [] { didSet { scheduleSave() } }
    @Published var settings = AppSettings() { didSet { scheduleSave() } }
    @Published var draggingID: UUID?
    /// A whole group being dragged by its name.
    @Published var draggingGroupID: UUID?

    private var saveTask: Task<Void, Never>?
    private var lastLiveMove = Date.distantPast
    private var lastGroupSwap: (id: UUID, target: UUID, at: Date)?

    static let directory: URL = FileManager.default
        .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("MacTiles", isDirectory: true)
    static let fileURL: URL = directory.appendingPathComponent("layout.json")

    init() { load() }

    // MARK: Persistence

    private func load() {
        let url = Self.fileURL
        if let data = try? Data(contentsOf: url) {
            do {
                let file = try JSONDecoder().decode(LayoutFile.self, from: data)
                settings = file.settings
                groups = file.groups.isEmpty ? Self.defaultGroups() : file.groups
                return
            } catch {
                let backup = Self.directory.appendingPathComponent("layout.unreadable-\(Int(Date().timeIntervalSince1970)).json")
                try? FileManager.default.moveItem(at: url, to: backup)
                NSLog("MacTiles: layout.json could not be read (\(error)). Saved it as \(backup.path) and restored defaults.")
            }
        }
        groups = Self.defaultGroups()
        settings = AppSettings()
        saveNow()
    }

    private func scheduleSave() {
        saveTask?.cancel()
        saveTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 400_000_000)
            guard !Task.isCancelled else { return }
            self?.saveNow()
        }
    }

    func saveNow() {
        saveTask?.cancel()
        saveTask = nil
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(LayoutFile(settings: settings, groups: groups)) else { return }
        let fm = FileManager.default
        try? fm.createDirectory(at: Self.directory, withIntermediateDirectories: true,
                                attributes: [.posixPermissions: 0o700])
        do {
            try data.write(to: Self.fileURL, options: .atomic)
            // It lists your services' addresses and user names: readable by you only.
            try? fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: Self.fileURL.path)
        } catch {
            NSLog("MacTiles: couldn't save layout.json: \(error.localizedDescription)")
        }
    }

    func resetLayout() { groups = Self.defaultGroups() }

    /// Settings → Import Layout…: replaces tiles, groups and settings with another layout.json.
    func importLayout(from url: URL) throws {
        let file = try JSONDecoder().decode(LayoutFile.self, from: Data(contentsOf: url))
        var imported = file.settings
        // A folder chosen in another app (or on another Mac) can't be opened here: fall back to Pictures.
        if !FileManager.default.isReadableFile(atPath: imported.photosFolder) {
            imported.photosFolder = AppSettings().photosFolder
        }
        imported.photosFolderBookmark = nil
        settings = imported
        groups = file.groups.isEmpty ? Self.defaultGroups() : file.groups
        saveNow()
    }

    /// Where the Import panel opens: MacTiles' own folder (the real one, outside any sandbox).
    static var importFolderSuggestion: URL {
        let home = getpwuid(getuid()).map { String(cString: $0.pointee.pw_dir) } ?? NSHomeDirectory()
        let macTiles = URL(fileURLWithPath: home).appendingPathComponent("Library/Application Support/MacTiles", isDirectory: true)
        return FileManager.default.fileExists(atPath: macTiles.path) ? macTiles : URL(fileURLWithPath: home)
    }

    // MARK: Queries

    func locate(_ id: UUID) -> (g: Int, t: Int)? { Self.locate(id, in: groups) }

    func isPinned(_ path: String) -> Bool {
        groups.contains { $0.tiles.contains { $0.appPath == path } }
    }

    func has(_ kind: TileKind) -> Bool {
        groups.contains { $0.tiles.contains { $0.kind == kind } }
    }

    // MARK: Mutations

    func update(_ id: UUID, _ change: (inout Tile) -> Void) {
        guard let p = locate(id) else { return }
        change(&groups[p.g].tiles[p.t])
    }

    func remove(_ id: UUID) {
        var g = groups
        guard let p = Self.locate(id, in: g) else { return }
        g[p.g].tiles.remove(at: p.t)
        groups = Self.pruned(g)
    }

    func move(_ id: UUID, to dest: TileDestination) {
        if case .before(let target) = dest, target == id { return }
        var g = groups
        guard let src = Self.locate(id, in: g) else { return }
        let tile = g[src.g].tiles.remove(at: src.t)
        Self.insert(tile, at: dest, into: &g, from: src)
        groups = Self.pruned(g)
    }

    /// Reorders while dragging over other tiles, Windows 8 style. Debounced to avoid jitter.
    func liveMove(_ id: UUID, before target: UUID) {
        let now = Date()
        guard id != target, now.timeIntervalSince(lastLiveMove) > 0.18 else { return }
        lastLiveMove = now
        withAnimation(.spring(response: 0.3, dampingFraction: 0.82)) { move(id, to: .before(target)) }
    }

    @discardableResult
    func pin(path: String, at dest: TileDestination = .lastGroup) -> Bool {
        guard !isPinned(path) else { return false }
        var g = groups
        Self.insert(.app(path), at: dest, into: &g)
        groups = Self.pruned(g)
        return true
    }

    func unpin(path: String) {
        if let tile = groups.flatMap(\.tiles).first(where: { $0.appPath == path }) { remove(tile.id) }
    }

    /// Adds a tile that opens a web address in the default browser.
    func addWeb(url: String, title: String?, at dest: TileDestination = .lastGroup) {
        var g = groups
        Self.insert(.web(url, title: title), at: dest, into: &g)
        groups = Self.pruned(g)
    }

    func addService(_ tile: Tile, at dest: TileDestination = .lastGroup) {
        var g = groups
        Self.insert(tile, at: dest, into: &g)
        groups = Self.pruned(g)
    }

    /// Service tiles showing this integration.
    func serviceTiles(of integration: UUID) -> [Tile] {
        groups.flatMap(\.tiles).filter { $0.kind == .service && $0.integrationID == integration }
    }

    /// Removes an integration and unpins its tiles. Its secret is removed from the Keychain.
    func removeIntegration(_ id: UUID) {
        settings.integrations.removeAll { $0.id == id }
        var g = groups
        for i in g.indices { g[i].tiles.removeAll { $0.kind == .service && $0.integrationID == id } }
        groups = Self.pruned(g)
        IntegrationSecrets.remove(id)
    }

    func addLive(_ kind: TileKind) {
        addToFirstGroup(Tile(kind: kind))
    }

    /// A News tile with its own feed; you can have as many as you like.
    func addNews(feed: String, title: String?) {
        addToFirstGroup(Tile(kind: .news, url: feed, title: title))
    }

    /// The distinct feeds the News tiles on Start are showing.
    var newsFeeds: [String] { Self.newsFeeds(in: groups, default: settings.newsFeed) }

    /// A News tile's feed: its own, or Settings' default for tiles that don't have one.
    func newsFeed(of tile: Tile) -> String { Self.newsFeed(of: tile, default: settings.newsFeed) }

    nonisolated static func newsFeed(of tile: Tile, default fallback: String) -> String {
        let own = (tile.url ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        return own.isEmpty ? fallback.trimmingCharacters(in: .whitespacesAndNewlines) : own
    }

    nonisolated static func newsFeeds(in groups: [TileGroup], default fallback: String) -> [String] {
        var seen = Set<String>()
        return groups.flatMap(\.tiles).filter { $0.kind == .news }
            .map { newsFeed(of: $0, default: fallback) }
            .filter { !$0.isEmpty && seen.insert($0).inserted }
    }

    private func addToFirstGroup(_ tile: Tile) {
        var g = groups
        if let first = g.first {
            Self.insert(tile, at: .endOf(first.id), into: &g)
        } else {
            g.append(TileGroup(name: "", tiles: [tile]))
        }
        groups = g
    }

    func rename(_ groupID: UUID, to name: String) {
        guard let i = groups.firstIndex(where: { $0.id == groupID }) else { return }
        groups[i].name = name
    }

    // MARK: Group order

    /// Moves a group into another group's position. Dragging right lands after the target,
    /// dragging left lands before it, so passing over a neighbour swaps the two.
    func moveGroup(_ id: UUID, to target: UUID) {
        groups = Self.movingGroup(id, to: target, in: groups)
    }

    /// Moves a group one place left (-1) or right (+1).
    func shiftGroup(_ id: UUID, by offset: Int) {
        guard let i = groups.firstIndex(where: { $0.id == id }) else { return }
        let j = i + offset
        guard groups.indices.contains(j) else { return }
        groups = Self.movingGroup(id, to: groups[j].id, in: groups)
    }

    /// Reorders groups while dragging, debounced like tile reordering.
    func liveMoveGroup(_ id: UUID, to target: UUID) {
        let now = Date()
        guard id != target, now.timeIntervalSince(lastLiveMove) > 0.18 else { return }
        // After swapping with a wider group, the pointer can land on that group again without
        // moving; don't swap straight back with the same neighbour.
        if let last = lastGroupSwap, last.target == target, last.id == id, now.timeIntervalSince(last.at) < 0.7 { return }
        lastGroupSwap = (id, target, now)
        lastLiveMove = now
        withAnimation(.spring(response: 0.35, dampingFraction: 0.82)) { moveGroup(id, to: target) }
    }

    nonisolated static func movingGroup(_ id: UUID, to target: UUID, in groups: [TileGroup]) -> [TileGroup] {
        guard id != target,
              let from = groups.firstIndex(where: { $0.id == id }),
              let to = groups.firstIndex(where: { $0.id == target }) else { return groups }
        var g = groups
        let group = g.remove(at: from)
        g.insert(group, at: to)
        return g
    }

    /// The group a drop destination belongs to (for dropping a dragged group onto tiles).
    func groupID(for dest: TileDestination) -> UUID? {
        switch dest {
        case .before(let tileID): return locate(tileID).map { groups[$0.g].id }
        case .endOf(let groupID): return groupID
        case .newGroup, .lastGroup: return groups.last?.id
        }
    }

    func removeGroup(_ groupID: UUID) {
        groups = Self.pruned(groups.filter { $0.id != groupID })
    }

    /// Handles drops of tiles (reordering) and of .app bundles from Finder (pinning).
    func acceptDrop(_ providers: [NSItemProvider], at dest: TileDestination) -> Bool {
        let files = providers.filter { $0.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) }
        if !files.isEmpty {
            for provider in files {
                _ = provider.loadObject(ofClass: URL.self) { [weak self] url, _ in
                    guard let url, url.pathExtension.lowercased() == "app" else { return }
                    let path = url.path
                    Task { @MainActor in
                        withAnimation(.spring(response: 0.35, dampingFraction: 0.85)) {
                            _ = self?.pin(path: path, at: dest)
                        }
                    }
                }
            }
            return true
        }

        // A link dragged from a browser's address bar or a web page becomes a web tile.
        let links = providers.filter { $0.hasItemConformingToTypeIdentifier(UTType.url.identifier) }
        if !links.isEmpty && draggingID == nil && draggingGroupID == nil {
            for provider in links {
                _ = provider.loadObject(ofClass: URL.self) { [weak self] url, _ in
                    guard let url, WebLink.isFetchable(url) else { return }
                    let address = url.absoluteString
                    Task { @MainActor in
                        withAnimation(.spring(response: 0.35, dampingFraction: 0.85)) {
                            self?.addWeb(url: address, title: nil, at: dest)
                        }
                    }
                }
            }
            return true
        }

        if let dragged = draggingGroupID {
            draggingGroupID = nil
            // Live reordering has already moved it into place while dragging.
            // Only dropping in the empty space after the last group needs a final move.
            if case .newGroup = dest, let last = groups.last?.id, last != dragged {
                withAnimation(.spring(response: 0.35, dampingFraction: 0.85)) { moveGroup(dragged, to: last) }
            }
            return true
        }

        guard let id = draggingID else { return false }
        draggingID = nil
        // Dropping onto a tile: live reordering has already put it in place.
        if case .before = dest { return true }
        withAnimation(.spring(response: 0.35, dampingFraction: 0.85)) { move(id, to: dest) }
        return true
    }

    // MARK: Helpers

    static func locate(_ id: UUID, in groups: [TileGroup]) -> (g: Int, t: Int)? {
        for (gi, group) in groups.enumerated() {
            if let ti = group.tiles.firstIndex(where: { $0.id == id }) { return (gi, ti) }
        }
        return nil
    }

    private static func insert(_ tile: Tile, at dest: TileDestination, into g: inout [TileGroup],
                               from src: (g: Int, t: Int)? = nil) {
        switch dest {
        case .before(let target):
            if let p = locate(target, in: g) {
                var index = p.t
                // Moving forward within a group lands after the target, so a drag swaps neighbours.
                if let src, src.g == p.g, src.t <= p.t { index += 1 }
                g[p.g].tiles.insert(tile, at: min(index, g[p.g].tiles.count))
            } else {
                appendToLast(tile, &g)
            }
        case .endOf(let groupID):
            if let gi = g.firstIndex(where: { $0.id == groupID }) {
                g[gi].tiles.append(tile)
            } else {
                appendToLast(tile, &g)
            }
        case .newGroup:
            g.append(TileGroup(name: "", tiles: [tile]))
        case .lastGroup:
            appendToLast(tile, &g)
        }
    }

    private static func appendToLast(_ tile: Tile, _ g: inout [TileGroup]) {
        if g.isEmpty { g.append(TileGroup(name: "", tiles: [tile])) } else { g[g.count - 1].tiles.append(tile) }
    }

    private static func pruned(_ g: [TileGroup]) -> [TileGroup] {
        let kept = g.filter { !$0.tiles.isEmpty }
        return kept.isEmpty ? [TileGroup(name: "", tiles: [])] : kept
    }

    static func defaultGroups() -> [TileGroup] {
        let fm = FileManager.default
        func app(_ path: String, _ size: TileSize = .medium) -> Tile? {
            fm.fileExists(atPath: path) ? Tile.app(path, size: size) : nil
        }

        let today = TileGroup(name: "Today", tiles: [
            Tile(kind: .clock, size: .wide),
            Tile(kind: .weather, size: .wide),
            Tile(kind: .calendar),
            Tile(kind: .system),
            Tile(kind: .photos, size: .wide),
            Tile(kind: .news, size: .wide),
        ])

        let everyday: [Tile?] = [
            app("/Applications/Safari.app", .wide),
            app("/System/Applications/Mail.app"),
            app("/System/Applications/Messages.app"),
            app("/System/Applications/Music.app"),
            app("/System/Applications/Photos.app"),
            app("/System/Applications/Notes.app", .small),
            app("/System/Applications/Reminders.app", .small),
            app("/System/Applications/Maps.app", .small),
            app("/System/Applications/FaceTime.app", .small),
            app("/System/Applications/App Store.app"),
            app("/System/Applications/System Settings.app"),
        ]

        let work: [Tile?] = [
            Tile(kind: .desktop, size: .wide),
            app("/System/Library/CoreServices/Finder.app"),
            app("/System/Applications/Utilities/Terminal.app"),
            app("/System/Applications/Utilities/Activity Monitor.app", .small),
            app("/System/Applications/Calculator.app", .small),
            app("/System/Applications/TextEdit.app", .small),
            app("/System/Applications/Preview.app", .small),
            Tile(kind: .battery),
        ]

        return [
            today,
            TileGroup(name: "Everyday", tiles: everyday.compactMap { $0 }),
            TileGroup(name: "Work", tiles: work.compactMap { $0 }),
        ]
    }
}
