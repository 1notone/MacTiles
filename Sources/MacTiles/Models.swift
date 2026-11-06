import Foundation

// MARK: - Tile sizes (Windows 8.1 units: small = 1×1, medium = 2×2, wide = 4×2, large = 4×4)

enum TileSize: String, Codable, CaseIterable, Identifiable {
    case small, medium, wide, large

    var id: String { rawValue }
    var title: String { rawValue.capitalized }

    var units: (w: Int, h: Int) {
        switch self {
        case .small: return (1, 1)
        case .medium: return (2, 2)
        case .wide: return (4, 2)
        case .large: return (4, 4)
        }
    }
}

// MARK: - Tile shape

/// Square is classic Windows 8; Soft and Round use Apple's continuous-corner squircle.
enum TileShape: String, Codable, CaseIterable, Identifiable {
    case square, soft, round

    var id: String { rawValue }
    var title: String { rawValue.capitalized }

    /// Corner radius in points at 100% tile size.
    var cornerRadius: Double {
        switch self {
        case .square: return 0
        case .soft: return 12
        case .round: return 20
        }
    }

    /// Space between tiles at 100% tile size. Round tiles get more room so corners don't crowd.
    var gap: Double { self == .round ? 12 : 8 }

    /// How far tile labels sit from the bottom-left corner, clear of the curve.
    var labelInset: (leading: Double, bottom: Double) {
        switch self {
        case .square: return (8, 6)
        case .soft: return (10, 7)
        case .round: return (14, 9)
        }
    }
}

// MARK: - Tile finish & shadow

/// Flat Metro tiles, or translucent glass that lets the wallpaper show through.
enum TileFinish: String, Codable, CaseIterable, Identifiable {
    case flat, glass

    var id: String { rawValue }
    var title: String { rawValue.capitalized }
}

/// How much tiles lift off the background.
enum TileShadow: String, Codable, CaseIterable, Identifiable {
    case none, subtle, medium, strong

    var id: String { rawValue }
    var title: String { rawValue.capitalized }

    /// Opacity, blur radius and downward offset (in points) of the drop shadow.
    var parameters: (opacity: Double, radius: Double, y: Double) {
        switch self {
        case .none: return (0, 0, 0)
        case .subtle: return (0.25, 4, 2)
        case .medium: return (0.40, 10, 5)
        case .strong: return (0.55, 20, 10)
        }
    }
}

// MARK: - Background

/// What fills the Start screen behind the tiles.
enum BackgroundStyle: String, Codable, CaseIterable, Identifiable {
    case color, media, live     // a saved "desktop" (removed in 1.10.2) falls back to color

    var id: String { rawValue }
    var title: String {
        switch self {
        case .color: return "Color"
        case .media: return "Picture or Video"
        case .live: return "Live"
        }
    }
}

/// Animated wallpapers drawn by MacTiles itself, tinted with the background color.
enum LiveWallpaper: String, Codable, CaseIterable, Identifiable {
    case aurora, ribbons, bokeh, squares

    var id: String { rawValue }
    var title: String {
        switch self {
        case .aurora: return "Aurora"
        case .ribbons: return "Ribbons"
        case .bokeh: return "Bokeh"
        case .squares: return "Squares"
        }
    }
}

// MARK: - Tile kinds

enum TileKind: String, Codable, CaseIterable, Identifiable {
    case app, clock, calendar, weather, system, battery, photos, news, desktop, web, service

    var id: String { rawValue }
    static var liveKinds: [TileKind] { allCases.filter { $0 != .app && $0 != .web && $0 != .service } }

    var title: String {
        switch self {
        case .app: return "App"
        case .clock: return "Clock"
        case .calendar: return "Calendar"
        case .weather: return "Weather"
        case .system: return "System"
        case .battery: return "Battery"
        case .photos: return "Photos"
        case .news: return "News"
        case .desktop: return "Desktop"
        case .web: return "Web Link"
        case .service: return "Service"
        }
    }

    var symbol: String {
        switch self {
        case .app: return "app"
        case .clock: return "clock"
        case .calendar: return "calendar"
        case .weather: return "cloud.sun"
        case .system: return "cpu"
        case .battery: return "battery.75percent"
        case .photos: return "photo.on.rectangle"
        case .news: return "newspaper"
        case .desktop: return "menubar.dock.rectangle"
        case .web: return "globe"
        case .service: return "server.rack"
        }
    }

    var defaultSize: TileSize {
        switch self {
        case .clock, .weather, .photos, .news, .desktop: return .wide
        case .battery: return .small
        default: return .medium
        }
    }

    var defaultColor: String {
        switch self {
        case .app: return "#2D89EF"
        case .clock: return "#2B5797"
        case .calendar: return "#603CBA"
        case .weather: return "#2D89EF"
        case .system: return "#00A300"
        case .battery: return "#1E7145"
        case .photos: return "#00ABA9"
        case .news: return "#B91D47"
        case .desktop: return "#1D1D1D"
        case .web: return "#2D89EF"
        case .service: return "#2B5797"
        }
    }

    /// Sizes that make sense for this tile.
    var sizes: [TileSize] {
        switch self {
        case .battery: return [.small, .medium]
        case .photos, .news, .desktop: return [.medium, .wide, .large]
        default: return TileSize.allCases
        }
    }
}

// MARK: - Tiles and groups

struct Tile: Identifiable, Codable, Hashable {
    var id: UUID
    var kind: TileKind
    var appPath: String?
    var size: TileSize
    var color: String?          // "#RRGGBB"; nil = automatic
    var url: String?            // web tiles: the address to open; news tiles: their feed (nil = Settings' default)
    var title: String?          // web and service tiles: the name shown on the tile
    var integrationID: UUID?    // service tiles: which integration (Settings → Integrations)
    var widget: ServiceWidget?  // service tiles: what to show
    var entity: String?         // Home Assistant tiles: the entity, e.g. light.kitchen

    init(kind: TileKind, appPath: String? = nil, size: TileSize? = nil, color: String? = nil,
         url: String? = nil, title: String? = nil) {
        self.id = UUID()
        self.kind = kind
        self.appPath = appPath
        self.size = size ?? kind.defaultSize
        self.color = color
        self.url = url
        self.title = title
    }

    static func service(_ integration: UUID, widget: ServiceWidget, entity: String? = nil, title: String? = nil) -> Tile {
        var tile = Tile(kind: .service, size: widget.defaultSize, title: title)
        tile.integrationID = integration
        tile.widget = widget
        tile.entity = entity
        return tile
    }

    /// Sizes the Resize menu offers.
    var sizes: [TileSize] {
        if kind == .service, let widget { return widget.sizes }
        return kind.sizes
    }

    static func app(_ path: String, size: TileSize = .medium) -> Tile {
        Tile(kind: .app, appPath: path, size: size)
    }

    static func web(_ url: String, title: String? = nil, size: TileSize = .medium) -> Tile {
        Tile(kind: .web, size: size, url: url, title: title)
    }

    enum CodingKeys: String, CodingKey { case id, kind, appPath, size, color, url, title, integrationID, widget, entity }

    // Lenient decoding so a hand-edited layout.json doesn't need every key.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        kind = try c.decode(TileKind.self, forKey: .kind)
        id = (try? c.decodeIfPresent(UUID.self, forKey: .id)) ?? UUID()
        appPath = try? c.decodeIfPresent(String.self, forKey: .appPath)
        size = (try? c.decodeIfPresent(TileSize.self, forKey: .size)) ?? kind.defaultSize
        color = try? c.decodeIfPresent(String.self, forKey: .color)
        url = try? c.decodeIfPresent(String.self, forKey: .url)
        title = try? c.decodeIfPresent(String.self, forKey: .title)
        integrationID = try? c.decodeIfPresent(UUID.self, forKey: .integrationID)
        widget = try? c.decodeIfPresent(ServiceWidget.self, forKey: .widget)
        entity = try? c.decodeIfPresent(String.self, forKey: .entity)
        if kind == .web, url == nil { throw DecodingError.dataCorruptedError(forKey: .url, in: c, debugDescription: "web tile without url") }
        if kind == .service, integrationID == nil || widget == nil {
            throw DecodingError.dataCorruptedError(forKey: .widget, in: c, debugDescription: "service tile without integration")
        }
    }
}

struct TileGroup: Identifiable, Codable, Hashable {
    var id: UUID
    var name: String
    var tiles: [Tile]

    init(name: String, tiles: [Tile]) {
        self.id = UUID()
        self.name = name
        self.tiles = tiles
    }

    var displayName: String { name.isEmpty ? "Unnamed group" : name }

    enum CodingKeys: String, CodingKey { case id, name, tiles }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = (try? c.decodeIfPresent(UUID.self, forKey: .id)) ?? UUID()
        name = (try? c.decodeIfPresent(String.self, forKey: .name)) ?? ""
        // Skip tiles we can't read (e.g. a kind from a newer version) instead of failing the whole file.
        let lenient = (try? c.decodeIfPresent([Lenient<Tile>].self, forKey: .tiles)) ?? []
        tiles = lenient.compactMap(\.value)
    }
}

struct Lenient<T: Decodable>: Decodable {
    let value: T?
    init(from decoder: Decoder) throws { value = try? T(from: decoder) }
}

// MARK: - Settings

struct HotKeyPreset: Identifiable, Hashable {
    let id: String
    let label: String
    let keyCode: UInt32
    let modifiers: UInt32   // Carbon modifier masks

    // cmdKey 0x0100, shiftKey 0x0200, optionKey 0x0800, controlKey 0x1000
    static let all: [HotKeyPreset] = [
        HotKeyPreset(id: "opt-space", label: "⌥ Space", keyCode: 49, modifiers: 0x0800),
        HotKeyPreset(id: "opt-cmd-space", label: "⌥⌘ Space", keyCode: 49, modifiers: 0x0800 | 0x0100),
        HotKeyPreset(id: "ctrl-opt-space", label: "⌃⌥ Space", keyCode: 49, modifiers: 0x1000 | 0x0800),
        HotKeyPreset(id: "ctrl-space", label: "⌃ Space", keyCode: 49, modifiers: 0x1000),
        HotKeyPreset(id: "f13", label: "F13", keyCode: 105, modifiers: 0),
        HotKeyPreset(id: "none", label: "None", keyCode: 0, modifiers: 0),
    ]

    static func find(_ id: String) -> HotKeyPreset? { all.first { $0.id == id } }
}

struct AppSettings: Codable, Equatable {
    var userName = NSFullUserName()
    var background = "#25115A"
    var tileScale = 1.0
    var iconColoredTiles = false
    var hotKey = "opt-space"
    var hotCorner = false
    var hotCornerToggles = false      // the corner also hides Start and shows the desktop when Start is open
    var weatherCity: String?
    var weatherLat: Double?
    var weatherLon: Double?
    var weatherPostalCode: String?    // set when the place was chosen by ZIP / postal code
    var fahrenheit = Locale.current.measurementSystem == .us
    var newsFeed = NewsFeeds.defaultFeed   // News tiles without a feed of their own use this one
    var photosFolder = NSHomeDirectory() + "/Pictures"
    var calendarEvents = false
    var keepOnDesktop = true      // Start stays behind your apps, Windows 8 style
    var showInDock = true         // the Dock icon acts as the Start button
    var tileShape = TileShape.square
    var backgroundStyle = BackgroundStyle.color
    var wallpaperFile: String?           // a file in Application Support/MacTiles/Wallpapers (or an absolute path)
    var liveWallpaper = LiveWallpaper.aurora
    var wallpaperDim = 0.25              // darkens pictures and videos so tiles stay readable
    var tileFinish = TileFinish.flat
    var glassTint = 0.45                 // how much of the tile color the glass carries (lower = clearer)
    var tileShadow = TileShadow.none
    var showRunningIndicator = true      // a small dot on tiles of apps that are running
    var integrations: [Integration] = [] // homelab services for service tiles; secrets are in the Keychain

    init() {}

    enum CodingKeys: String, CodingKey {
        case userName, background, tileScale, iconColoredTiles, hotKey, hotCorner, hotCornerToggles
        case weatherCity, weatherLat, weatherLon, weatherPostalCode, fahrenheit, newsFeed, photosFolder, calendarEvents
        case keepOnDesktop, showInDock, tileShape
        case backgroundStyle, wallpaperFile, liveWallpaper, wallpaperDim
        case tileFinish, glassTint, tileShadow, showRunningIndicator
        case integrations
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = AppSettings()
        func get<T: Decodable>(_ key: CodingKeys, _ fallback: T) -> T {
            (try? c.decodeIfPresent(T.self, forKey: key)) ?? fallback
        }
        userName = get(.userName, d.userName)
        background = get(.background, d.background)
        tileScale = min(max(get(.tileScale, d.tileScale), 0.8), 1.5)          // Settings' slider range
        iconColoredTiles = get(.iconColoredTiles, d.iconColoredTiles)
        hotKey = get(.hotKey, d.hotKey)
        hotCorner = get(.hotCorner, d.hotCorner)
        hotCornerToggles = get(.hotCornerToggles, d.hotCornerToggles)
        weatherCity = try? c.decodeIfPresent(String.self, forKey: .weatherCity)
        weatherLat = try? c.decodeIfPresent(Double.self, forKey: .weatherLat)
        weatherLon = try? c.decodeIfPresent(Double.self, forKey: .weatherLon)
        weatherPostalCode = try? c.decodeIfPresent(String.self, forKey: .weatherPostalCode)
        fahrenheit = get(.fahrenheit, d.fahrenheit)
        newsFeed = get(.newsFeed, d.newsFeed)
        photosFolder = get(.photosFolder, d.photosFolder)
        calendarEvents = get(.calendarEvents, d.calendarEvents)
        keepOnDesktop = get(.keepOnDesktop, d.keepOnDesktop)
        showInDock = get(.showInDock, d.showInDock)
        tileShape = get(.tileShape, d.tileShape)
        backgroundStyle = get(.backgroundStyle, d.backgroundStyle)
        wallpaperFile = try? c.decodeIfPresent(String.self, forKey: .wallpaperFile)
        liveWallpaper = get(.liveWallpaper, d.liveWallpaper)
        wallpaperDim = min(max(get(.wallpaperDim, d.wallpaperDim), 0), 0.7)
        tileFinish = get(.tileFinish, d.tileFinish)
        glassTint = min(max(get(.glassTint, d.glassTint), 0.1), 0.9)
        tileShadow = get(.tileShadow, d.tileShadow)
        showRunningIndicator = get(.showRunningIndicator, d.showRunningIndicator)
        // Skip services from a newer version instead of dropping them all.
        integrations = ((try? c.decodeIfPresent([Lenient<Integration>].self, forKey: .integrations)) ?? []).compactMap(\.value)
    }
}

struct LayoutFile: Codable {
    var version = 1
    var settings: AppSettings
    var groups: [TileGroup]

    init(settings: AppSettings, groups: [TileGroup]) {
        self.settings = settings
        self.groups = groups
    }

    enum CodingKeys: String, CodingKey { case version, settings, groups }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        version = (try? c.decodeIfPresent(Int.self, forKey: .version)) ?? 1
        settings = (try? c.decodeIfPresent(AppSettings.self, forKey: .settings)) ?? AppSettings()
        groups = try c.decode([TileGroup].self, forKey: .groups)
    }
}
