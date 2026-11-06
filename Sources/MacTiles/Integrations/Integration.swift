import Foundation
import Security

// MARK: - Services

/// The homelab apps MacTiles can talk to directly. These are the services Homarr offers
/// widgets for, reached with each service's own API. Homarr itself isn't needed.
enum ServiceKind: String, Codable, CaseIterable, Identifiable, Sendable {
    // Media
    case plex, jellyfin, emby, sonarr, radarr, overseerr
    // Network & home
    case pihole, adguard, homeAssistant, unifi, opnsense
    // Servers
    case proxmox, truenas, unraid, glances, docker, beszel
    // AI
    case comfyui

    var id: String { rawValue }

    enum Category: String, CaseIterable, Identifiable {
        case media = "Media", network = "Network & Home", servers = "Servers", ai = "AI"
        var id: String { rawValue }
    }

    var category: Category {
        switch self {
        case .plex, .jellyfin, .emby, .sonarr, .radarr, .overseerr: return .media
        case .pihole, .adguard, .homeAssistant, .unifi, .opnsense: return .network
        case .proxmox, .truenas, .unraid, .glances, .docker, .beszel: return .servers
        case .comfyui: return .ai
        }
    }

    var title: String {
        switch self {
        case .plex: return "Plex"
        case .jellyfin: return "Jellyfin"
        case .emby: return "Emby"
        case .sonarr: return "Sonarr"
        case .radarr: return "Radarr"
        case .overseerr: return "Overseerr / Jellyseerr"
        case .pihole: return "Pi-hole"
        case .adguard: return "AdGuard Home"
        case .homeAssistant: return "Home Assistant"
        case .unifi: return "UniFi Network"
        case .opnsense: return "OPNsense"
        case .proxmox: return "Proxmox VE"
        case .truenas: return "TrueNAS"
        case .unraid: return "Unraid"
        case .glances: return "Glances"
        case .docker: return "Docker"
        case .beszel: return "Beszel"
        case .comfyui: return "ComfyUI"
        }
    }

    /// SF Symbols, not brand logos.
    var symbol: String {
        switch self {
        case .plex, .jellyfin, .emby: return "play.rectangle.fill"
        case .sonarr: return "tv"
        case .radarr: return "film"
        case .overseerr: return "tray.and.arrow.down"
        case .pihole, .adguard: return "shield.lefthalf.filled"
        case .homeAssistant: return "house"
        case .unifi: return "wifi"
        case .opnsense: return "network.badge.shield.half.filled"
        case .proxmox: return "server.rack"
        case .truenas, .unraid: return "externaldrive.connected.to.line.below"
        case .glances: return "gauge.with.dots.needle.33percent"
        case .docker: return "shippingbox"
        case .beszel: return "chart.bar.xaxis"
        case .comfyui: return "wand.and.stars"
        }
    }

    var defaultColor: String {
        switch self {
        case .plex: return "#C1840B"
        case .jellyfin: return "#603CBA"
        case .emby: return "#00A300"
        case .sonarr: return "#00ABA9"
        case .radarr: return "#E3A21A"
        case .overseerr: return "#2B5797"
        case .pihole: return "#B91D47"
        case .adguard: return "#1E7145"
        case .homeAssistant: return "#2D89EF"
        case .unifi: return "#2B5797"
        case .opnsense: return "#DA532C"
        case .proxmox: return "#DA532C"
        case .truenas: return "#2D89EF"
        case .unraid: return "#EE1111"
        case .glances: return "#00A300"
        case .docker: return "#1D72B8"
        case .beszel: return "#00ABA9"
        case .comfyui: return "#603CBA"
        }
    }

    /// What goes in the address field, e.g. "http://192.168.1.10:32400".
    var placeholder: String {
        switch self {
        case .plex: return "http://192.168.1.10:32400"
        case .jellyfin, .emby: return "http://192.168.1.10:8096"
        case .sonarr: return "http://192.168.1.10:8989"
        case .radarr: return "http://192.168.1.10:7878"
        case .overseerr: return "http://192.168.1.10:5055"
        case .pihole: return "http://pi.hole"
        case .adguard: return "http://192.168.1.2:3000"
        case .homeAssistant: return "http://homeassistant.local:8123"
        case .unifi: return "https://192.168.1.1"
        case .opnsense: return "https://192.168.1.1"
        case .proxmox: return "https://192.168.1.20:8006"
        case .truenas: return "https://truenas.local"
        case .unraid: return "http://tower.local"
        case .glances: return "http://192.168.1.10:61208"
        case .docker: return "Leave empty for this Mac's Docker"
        case .beszel: return "http://192.168.1.10:8090"
        case .comfyui: return "http://192.168.1.10:8188"
        }
    }

    /// Docker can run on this Mac with no address at all.
    var addressOptional: Bool { self == .docker }

    /// The name of the account field, if the service has one.
    var usernameLabel: String? {
        switch self {
        case .adguard, .unifi, .glances: return "Username"
        case .proxmox: return "API token ID"
        case .beszel: return "Email"
        case .opnsense: return "API key"
        default: return nil
        }
    }

    /// Glances' username is optional (only for password-protected servers); the others need one.
    var usernameRequired: Bool { usernameLabel != nil && self != .glances }

    var usernamePrompt: String {
        switch self {
        case .proxmox: return "root@pam!mactiles"
        case .beszel: return "you@example.com"
        case .opnsense: return "The key from the downloaded apikey.txt"
        case .glances: return "Only if Glances asks for a password"
        default: return "admin"
        }
    }

    /// The name of the secret (stored in the Keychain), if the service needs one.
    var secretLabel: String? {
        switch self {
        case .plex: return "X-Plex-Token"
        case .jellyfin, .emby, .sonarr, .radarr, .overseerr, .truenas, .unraid: return "API key"
        case .pihole: return "Password"
        case .adguard, .unifi, .glances: return "Password"
        case .homeAssistant: return "Long-lived access token"
        case .proxmox: return "Token secret"
        case .opnsense: return "API secret"
        case .docker, .comfyui: return nil
        case .beszel: return "Password"
        }
    }

    var secretRequired: Bool {
        switch self {
        case .pihole, .glances, .docker, .comfyui: return false
        default: return true
        }
    }

    /// Where to find the key, shown under the fields.
    var help: String {
        switch self {
        case .plex: return "Find your token by viewing the XML of any item in Plex Web (it's the X-Plex-Token in the address)."
        case .jellyfin: return "Dashboard → API Keys → +."
        case .emby: return "Settings → Advanced → API Keys → New API Key."
        case .sonarr, .radarr: return "Settings → General → Security → API Key."
        case .overseerr: return "Settings → General → API Key. Works with Jellyseerr too."
        case .pihole: return "Your web interface password, or an app password (Settings → Web interface / API). For Pi-hole 5, use the API token. Leave empty if you don't use a password."
        case .adguard: return "The account you sign in to AdGuard Home with."
        case .homeAssistant: return "Your profile → Security → Long-lived access tokens → Create token."
        case .opnsense: return "System → Access → Users → edit a user → API keys → +. The downloaded apikey.txt holds the key and secret. The user needs the Dashboard, Diagnostics and Traffic Graph privileges (or \"All pages\")."
        case .unifi: return "A local account on your console or controller (a read-only local admin is enough)."
        case .proxmox: return "Datacenter → Permissions → API Tokens. Give it the PVEAuditor role, or uncheck Privilege Separation."
        case .truenas: return "Your account menu (top right) → API Keys → Add."
        case .unraid: return "Settings → Management Access → API Keys (Unraid 7.2 or the Unraid Connect plugin)."
        case .glances: return "Run Glances in web server mode: glances -w. The REST API is on port 61208."
        case .beszel: return "The email and password you sign in to Beszel with — a regular user (sees the systems shared with it) or a superuser."
        case .comfyui: return "No key needed: MacTiles uses ComfyUI's own API. To reach it from another machine, start ComfyUI with --listen. Install the ComfyUI-Crystools custom node to add GPU load, GPU temperature and CPU."
        case .docker: return "Uses Docker Desktop, OrbStack or Colima on this Mac. For another machine, enter its Docker API address, like http://nas.local:2375."
        }
    }

    /// Self-signed certificates are the norm for these.
    var usuallySelfSigned: Bool {
        switch self {
        case .unifi, .opnsense, .proxmox, .truenas: return true
        default: return false
        }
    }

    var widgets: [ServiceWidget] {
        switch self {
        case .plex, .jellyfin, .emby: return [.nowPlaying, .recentlyAdded]
        case .sonarr, .radarr: return [.upcoming]
        case .overseerr: return [.requests]
        case .pihole, .adguard: return [.dnsSummary]
        case .homeAssistant: return [.entity]
        case .unifi: return [.network]
        case .opnsense: return [.firewall]
        case .proxmox, .truenas, .glances: return [.resources]
        case .unraid: return [.resources, .containers]
        case .docker: return [.containers]
        case .beszel: return [.systems]
        case .comfyui: return [.generation]
        }
    }

    static func inCategory(_ category: Category) -> [ServiceKind] { allCases.filter { $0.category == category } }
}

// MARK: - Widgets

/// What a service tile shows.
enum ServiceWidget: String, Codable, CaseIterable, Identifiable, Sendable {
    case nowPlaying, recentlyAdded, upcoming, requests, dnsSummary, entity, network, firewall, resources, containers
    case systems, generation

    var id: String { rawValue }

    var title: String {
        switch self {
        case .nowPlaying: return "Now Playing"
        case .recentlyAdded: return "Recently Added"
        case .upcoming: return "Upcoming"
        case .requests: return "Requests"
        case .dnsSummary: return "Blocking Stats"
        case .entity: return "Entity"
        case .network: return "Network Health"
        case .firewall: return "Firewall Health"
        case .resources: return "System Health"
        case .containers: return "Containers"
        case .systems: return "Systems"
        case .generation: return "Generation"
        }
    }

    var detail: String {
        switch self {
        case .nowPlaying: return "Who's watching what, right now."
        case .recentlyAdded: return "The newest movies and episodes, with posters."
        case .upcoming: return "What's airing or releasing over the next two weeks, and the download queue."
        case .requests: return "Pending and recent requests."
        case .dnsSummary: return "Queries and blocked today. Pause blocking from the tile's menu."
        case .entity: return "One light, switch, sensor, script or automation. Click to toggle or run."
        case .network: return "Clients, devices and internet speed."
        case .firewall: return "Live traffic per interface, gateways (latency and packet loss), firewall states, memory, load and uptime."
        case .resources: return "CPU, memory, storage and uptime."
        case .containers: return "Running containers. Start, stop or restart from the tile's menu."
        case .systems: return "Every system's CPU, memory and disk — or pick one system for its full stats."
        case .generation: return "Live job progress, the queue, GPU / VRAM / RAM use and your latest images. Interrupt or clear the queue from the tile's menu."
        }
    }

    var defaultSize: TileSize {
        switch self {
        case .entity: return .medium
        case .dnsSummary, .network, .firewall, .resources: return .medium
        default: return .wide
        }
    }

    var sizes: [TileSize] {
        switch self {
        case .entity: return [.small, .medium, .wide]
        case .dnsSummary, .systems, .generation: return [.small, .medium, .wide, .large]
        default: return [.medium, .wide, .large]
        }
    }

    /// How often to ask the service, while Start is on screen.
    var interval: TimeInterval {
        switch self {
        case .nowPlaying, .entity, .containers: return 15
        case .firewall: return 10
        case .generation: return 2
        case .systems: return 20
        case .dnsSummary, .network, .resources: return 20
        case .requests, .recentlyAdded: return 120
        case .upcoming: return 300
        }
    }
}

// MARK: - A configured service

/// One service you've connected in Settings → Integrations. Saved in layout.json;
/// the password, token or API key lives in your Keychain instead.
struct Integration: Identifiable, Codable, Hashable, Sendable {
    var id: UUID
    var kind: ServiceKind
    var name: String
    var url: String
    var username: String
    var allowSelfSigned: Bool

    init(kind: ServiceKind, name: String = "", url: String = "", username: String = "", allowSelfSigned: Bool? = nil) {
        self.id = UUID()
        self.kind = kind
        self.name = name
        self.url = url
        self.username = username
        self.allowSelfSigned = allowSelfSigned ?? kind.usuallySelfSigned
    }

    var displayName: String { name.trimmingCharacters(in: .whitespaces).isEmpty ? kind.title : name }

    /// A plain-HTTP address that isn't on your local network: a key or password sent to it
    /// travels unencrypted across the internet.
    var sendsSecretInsecurely: Bool {
        guard let url = baseURL, url.scheme?.lowercased() == "http", let host = url.host else { return false }
        return !Self.isLocalHost(host)
    }

    /// Addresses that stay on your network (or this Mac): private IPv4/IPv6 ranges, Tailscale's
    /// 100.64/10, single-label names and the usual home-network suffixes.
    static func isLocalHost(_ rawHost: String) -> Bool {
        let host = rawHost.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "[]."))
        if host == "localhost" || !host.contains(".") && !host.contains(":") { return true }
        for suffix in [".local", ".lan", ".home", ".home.arpa", ".internal", ".localdomain", ".localhost", ".ts.net"]
        where host.hasSuffix(suffix) { return true }
        let octets = host.split(separator: ".").compactMap { UInt8($0) }
        if octets.count == 4, host.split(separator: ".").count == 4 {
            switch (octets[0], octets[1]) {
            case (10, _), (127, _), (192, 168), (169, 254): return true
            case (172, 16...31): return true
            case (100, 64...127): return true
            default: return false
            }
        }
        if host.contains(":") {
            return host == "::1" || host.hasPrefix("fc") || host.hasPrefix("fd") || host.hasPrefix("fe80")
        }
        return false
    }

    /// The address, cleaned up: a scheme added if missing, trailing slashes removed.
    var baseURL: URL? { Self.normalize(url) }

    static func normalize(_ raw: String) -> URL? {
        var s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !s.isEmpty, !s.contains(" ") else { return nil }
        if s.lowercased().hasPrefix("tcp://") { s = "http://" + s.dropFirst(6) }    // Docker-style addresses
        if !s.lowercased().hasPrefix("http://") && !s.lowercased().hasPrefix("https://") { s = "http://" + s }
        while s.hasSuffix("/") { s.removeLast() }
        guard let url = URL(string: s), let host = url.host, !host.isEmpty else { return nil }
        return url
    }

    enum CodingKeys: String, CodingKey { case id, kind, name, url, username, allowSelfSigned }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        kind = try c.decode(ServiceKind.self, forKey: .kind)
        id = (try? c.decodeIfPresent(UUID.self, forKey: .id)) ?? UUID()
        name = (try? c.decodeIfPresent(String.self, forKey: .name)) ?? ""
        url = (try? c.decodeIfPresent(String.self, forKey: .url)) ?? ""
        username = (try? c.decodeIfPresent(String.self, forKey: .username)) ?? ""
        allowSelfSigned = (try? c.decodeIfPresent(Bool.self, forKey: .allowSelfSigned)) ?? kind.usuallySelfSigned
    }
}

// MARK: - Keychain

/// Passwords, tokens and API keys for integrations, kept in the login keychain —
/// never in layout.json.
enum IntegrationSecrets {
    static let service = "io.github.mactiles.integration"

    /// Reading the Keychain can be slow (and may ask once after an update), so values are cached.
    private final class Cache: @unchecked Sendable {
        let lock = NSLock()
        var values: [UUID: String] = [:]
    }
    private static let store = Cache()

    static func get(_ id: UUID) -> String {
        store.lock.lock(); defer { store.lock.unlock() }
        if let cached = store.values[id] { return cached }
        let query: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: service,
            kSecAttrAccount: id.uuidString,
            kSecReturnData: true,
            kSecMatchLimit: kSecMatchLimitOne,
        ]
        var out: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &out)
        let value = (status == errSecSuccess ? (out as? Data).flatMap { String(data: $0, encoding: .utf8) } : nil) ?? ""
        // Only remember a definite answer. A locked keychain or a dismissed prompt is asked again
        // next time, instead of leaving the service signed out until MacTiles restarts.
        if status == errSecSuccess || status == errSecItemNotFound { store.values[id] = value }
        return value
    }

    /// Saves (or, with an empty secret, deletes) a service's secret. False if the Keychain refused.
    @discardableResult
    static func set(_ secret: String, for id: UUID, name: String = "") -> Bool {
        store.lock.lock(); defer { store.lock.unlock() }
        let match: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: service,
            kSecAttrAccount: id.uuidString,
        ]
        let deleted = SecItemDelete(match as CFDictionary)
        guard !secret.isEmpty else {
            store.values[id] = ""
            return deleted == errSecSuccess || deleted == errSecItemNotFound
        }
        var add = match
        add[kSecValueData] = Data(secret.utf8)
        add[kSecAttrLabel] = name.isEmpty ? "MacTiles integration" : "MacTiles: \(name)"
        add[kSecAttrAccessible] = kSecAttrAccessibleAfterFirstUnlock
        let status = SecItemAdd(add as CFDictionary, nil)
        guard status == errSecSuccess else {
            store.values[id] = nil
            return false
        }
        store.values[id] = secret
        return true
    }

    static func remove(_ id: UUID) { set("", for: id) }

    /// Deletes every MacTiles secret (Uninstall → "Also delete my tiles and settings").
    static func removeAll() {
        store.lock.lock(); defer { store.lock.unlock() }
        store.values.removeAll()
        let match: [CFString: Any] = [kSecClass: kSecClassGenericPassword, kSecAttrService: service]
        // SecItemDelete removes one item per call on macOS's file-based keychain; repeat until none are left.
        for _ in 0..<500 where SecItemDelete(match as CFDictionary) == errSecSuccess {}
    }
}
