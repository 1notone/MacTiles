import AppKit
import ImageIO
import SwiftUI

/// Polls your services for the service tiles on Start. Like the other live tiles, it only
/// runs while Start is on screen, and each widget has its own pace (now playing every 15 s,
/// upcoming episodes every 5 min).
@MainActor
final class ServiceHub: ObservableObject {
    enum Status: Equatable {
        case loading
        case ready(ServiceSnapshot)
        case failed(String, ServiceSnapshot?)

        var snapshot: ServiceSnapshot? {
            switch self {
            case .loading: return nil
            case .ready(let s): return s
            case .failed(_, let s): return s
            }
        }

        var error: String? {
            if case .failed(let message, _) = self { return message }
            return nil
        }
    }

    @Published private(set) var status: [String: Status] = [:]
    @Published private(set) var posters: [URL: NSImage] = [:]

    private let store: LayoutStore
    private var clients: [UUID: ServiceClient] = [:]
    private var fetchedAt: [String: Date] = [:]
    private var inFlight: Set<String> = []
    private var posterLoading: Set<URL> = []
    private var loop: Task<Void, Never>?
    private(set) var active = false

    init(store: LayoutStore) {
        self.store = store
    }

    /// One entry per distinct thing to fetch; two tiles showing the same widget share it.
    nonisolated static func key(_ tile: Tile) -> String {
        [tile.integrationID?.uuidString ?? "", tile.widget?.rawValue ?? "", tile.entity ?? ""].joined(separator: "|")
    }

    func integration(for tile: Tile) -> Integration? {
        guard let id = tile.integrationID else { return nil }
        return store.settings.integrations.first { $0.id == id }
    }

    func status(for tile: Tile) -> Status? { status[Self.key(tile)] }

    // MARK: Polling

    func setActive(_ on: Bool) {
        active = on
        loop?.cancel()
        loop = nil
        guard on else {
            // Close ComfyUI's live feed now rather than when it idles out.
            for client in clients.values { client.comfy?.stop() }
            return
        }
        loop = Task { [weak self] in
            while !Task.isCancelled {
                self?.tick()
                // Widgets set their own pace (ComfyUI every 2 s, upcoming every 5 min); this just checks.
                try? await Task.sleep(nanoseconds: 1_000_000_000)
            }
        }
    }

    /// Fetches whatever is due.
    func tick(now: Date = Date()) {
        var seen = Set<String>()
        for tile in store.groups.flatMap(\.tiles) where tile.kind == .service {
            let key = Self.key(tile)
            guard seen.insert(key).inserted, let widget = tile.widget else { continue }
            if let last = fetchedAt[key], now.timeIntervalSince(last) < widget.interval { continue }
            fetch(tile)
        }
    }

    func refresh(_ tile: Tile) {
        fetchedAt[Self.key(tile)] = nil
        fetch(tile)
    }

    /// Settings for an integration changed (or it was removed): reconnect and refetch.
    func integrationChanged(_ id: UUID) {
        clients.removeValue(forKey: id)?.invalidate()
        let prefix = id.uuidString + "|"
        for key in status.keys where key.hasPrefix(prefix) { status[key] = nil }
        for key in fetchedAt.keys where key.hasPrefix(prefix) { fetchedAt[key] = nil }
        if active { tick() }
    }

    private func fetch(_ tile: Tile) {
        let key = Self.key(tile)
        guard !inFlight.contains(key), let widget = tile.widget else { return }
        guard let integration = integration(for: tile) else {
            status[key] = .failed("This service was removed from Settings → Integrations.", nil)
            return
        }
        let client = self.client(for: integration)
        let entity = tile.entity
        inFlight.insert(key)
        if status[key] == nil { status[key] = .loading }
        Task { [weak self] in
            let result: Result<ServiceSnapshot, Error>
            do { result = .success(try await ServiceAPI.fetch(client, widget: widget, entity: entity)) }
            catch { result = .failure(error) }
            self?.finish(key, result, client: client)
        }
    }

    private func finish(_ key: String, _ result: Result<ServiceSnapshot, Error>, client: ServiceClient) {
        inFlight.remove(key)
        fetchedAt[key] = Date()
        switch result {
        case .success(let snapshot):
            if status[key] != .ready(snapshot) { status[key] = .ready(snapshot) }
            for url in snapshot.items.prefix(8).compactMap(\.image) { loadPoster(url, client: client) }
        case .failure(let error):
            status[key] = .failed(Self.message(error), status[key]?.snapshot)
        }
    }

    nonisolated static func message(_ error: Error) -> String {
        if let e = error as? LocalizedError, let text = e.errorDescription { return text }
        return error.localizedDescription
    }

    // MARK: Clients

    private func client(for integration: Integration) -> ServiceClient {
        let secret = IntegrationSecrets.get(integration.id)
        let fingerprint = ServiceClient.fingerprint(integration, secret: secret)
        if let existing = clients[integration.id], existing.fingerprint == fingerprint { return existing }
        clients[integration.id]?.invalidate()
        let client = ServiceClient(integration: integration, secret: secret)
        clients[integration.id] = client
        return client
    }

    // MARK: Posters

    private func loadPoster(_ url: URL, client: ServiceClient) {
        guard posters[url] == nil, !posterLoading.contains(url) else { return }
        posterLoading.insert(url)
        Task { [weak self] in
            let data = try? await client.image(url)
            guard let self else { return }
            self.posterLoading.remove(url)
            guard let data, let image = Self.decode(data, maxPixel: 480) else { return }
            if self.posters.count > 150 { self.posters.removeAll() }
            self.posters[url] = image
        }
    }

    nonisolated static func decode(_ data: Data, maxPixel: Int) -> NSImage? {
        guard let src = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixel,
        ]
        guard let cg = CGImageSourceCreateThumbnailAtIndex(src, 0, options as CFDictionary) else { return nil }
        return NSImage(cgImage: cg, size: NSSize(width: cg.width, height: cg.height))
    }

    // MARK: Actions

    /// Runs an action (pause blocking, toggle a light, restart a container), then refreshes the tile.
    func perform(_ action: ServiceAction, on tile: Tile) {
        guard let integration = integration(for: tile) else { return }
        let key = Self.key(tile)
        let client = self.client(for: integration)

        // Show the change right away; the refresh confirms it.
        if var snapshot = status[key]?.snapshot {
            switch action {
            case .pauseBlocking: snapshot.isOn = false
            case .resumeBlocking: snapshot.isOn = true
            case .toggleEntity: if let on = snapshot.isOn { snapshot.isOn = !on }
            case .interrupt:
                snapshot.busy = false
                snapshot.progress = nil
                snapshot.headline = "Stopping…"
            default: break
            }
            status[key] = .ready(snapshot)
        }

        Task { [weak self] in
            var failure: String?
            do { try await ServiceAPI.perform(client, action) } catch { failure = Self.message(error) }
            // Give the service a moment to apply it.
            try? await Task.sleep(nanoseconds: 700_000_000)
            guard let self else { return }
            if let failure { self.status[key] = .failed(failure, self.status[key]?.snapshot) }
            self.refresh(tile)
        }
    }

    // MARK: Settings helpers

    /// For the Test button in Settings: connects with the values in the form, not the saved ones.
    func test(_ integration: Integration, secret: String) async -> (ok: Bool, message: String) {
        let client = ServiceClient(integration: integration, secret: secret)
        defer { client.invalidate() }
        do { return (true, try await ServiceAPI.test(client)) }
        catch { return (false, Self.message(error)) }
    }

    /// Home Assistant entities, or Beszel systems, for choosing what a tile shows.
    func entities(of integration: Integration) async throws -> [ServiceAPI.HAEntity] {
        let client = self.client(for: integration)
        if integration.kind == .beszel { return try await ServiceAPI.beszelSystems(client) }
        return try await ServiceAPI.haEntities(client)
    }
}

// MARK: - Opening a service

extension Integration {
    /// The service's own web page, opened when you click its tile.
    var webURL: URL? {
        guard let base = baseURL else { return nil }
        switch kind {
        case .plex: return base.appendingPathComponent("web")
        case .pihole: return base.appendingPathComponent("admin")
        default: return base
        }
    }
}
