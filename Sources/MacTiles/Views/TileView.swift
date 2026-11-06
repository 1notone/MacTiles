import AppKit
import SwiftUI
import UniformTypeIdentifiers

@MainActor
struct TileView: View {
    let tile: Tile
    let metrics: Metrics
    let column: Int

    @EnvironmentObject private var launcher: Launcher
    @EnvironmentObject private var store: LayoutStore
    @EnvironmentObject private var catalog: AppCatalog
    @EnvironmentObject private var hub: LiveHub
    @EnvironmentObject private var running: RunningApps
    @State private var hovering = false
    @State private var pointer: CGPoint?
    @State private var shimmer = 0.0
    @State private var pressed = false
    @State private var targeted = false

    var body: some View {
        let frame = metrics.frame(tile.size)
        let shape = RoundedRectangle(cornerRadius: metrics.cornerRadius, style: .continuous)
        let settings = store.settings
        let shadow = settings.tileShadow.parameters
        TileContent(tile: tile, frame: frame)
            .foregroundStyle(.white)
            .frame(width: frame.width, height: frame.height)
            .background(TileSurface(color: background, finish: settings.tileFinish, glassTint: settings.glassTint))
            .overlay {
                if settings.tileFinish == .glass {
                    GlassOverlay(shape: shape, size: frame, pointer: pointer, shimmer: shimmer)
                }
            }
            .clipShape(shape)
            .overlay(alignment: tile.size == .small ? .bottom : .bottomTrailing) {
                // A small dot while the tile's app is running, like the Dock.
                if isRunning {
                    let inset = settings.tileShape.labelInset
                    RunningDot(size: tile.size == .small ? 4 : 6)
                        .padding(.trailing, tile.size == .small ? 0 : inset.leading)
                        .padding(.bottom, tile.size == .small ? 4 : inset.bottom + 4)
                        .transition(.scale(scale: 0.2).combined(with: .opacity))
                }
            }
            .animation(.spring(response: 0.3, dampingFraction: 0.7), value: isRunning)
            .overlay(shape.strokeBorder(Color.white.opacity(hovering || targeted ? 0.45 : 0), lineWidth: 2))
            // Lift off the background; the shadow deepens a little while you hover.
            .shadow(color: .black.opacity(shadow.opacity * (hovering ? 1.15 : 1)),
                    radius: shadow.radius * (hovering ? 1.2 : 1), x: 0, y: shadow.y * (hovering ? 1.25 : 1))
            .animation(.easeOut(duration: 0.15), value: hovering)
            // The Windows 8 "tilt" press effect.
            .scaleEffect(pressed ? 0.94 : 1)
            .rotation3DEffect(.degrees(pressed ? 6 : 0), axis: (x: 1, y: -0.5, z: 0), perspective: 0.6)
            .opacity(store.draggingID == tile.id ? 0.55 : 1)
            .contentShape(shape)
            .onHover { isOver in
                hovering = isOver
                if isOver && store.settings.tileFinish == .glass && !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
                    shimmer = 0.001
                    withAnimation(.easeOut(duration: 0.85)) { shimmer = 0.999 }
                }
            }
            .onContinuousHover(coordinateSpace: .local) { phase in
                guard store.settings.tileFinish == .glass else { return }
                switch phase {
                case .active(let p): pointer = p
                case .ended: withAnimation(.easeOut(duration: 0.25)) { pointer = nil }
                }
            }
            .onTapGesture(perform: activate)
            .contextMenu { TileMenu(tile: tile) }
            .onDrag {
                store.draggingID = tile.id
                store.draggingGroupID = nil
                return NSItemProvider(object: tile.id.uuidString as NSString)
            }
            .onDrop(of: [.text, .fileURL, .url], isTargeted: $targeted) { providers in
                store.acceptDrop(providers, at: .before(tile.id))
            }
            .onChange(of: targeted) { _, isOn in
                guard isOn else { return }
                if let group = store.draggingGroupID, let target = store.groupID(for: .before(tile.id)) {
                    store.liveMoveGroup(group, to: target)      // dragging a whole group over this one
                } else if let dragging = store.draggingID, dragging != tile.id {
                    store.liveMove(dragging, before: tile.id)
                }
            }
            .help(helpText)
            .modifier(Entrance(token: launcher.appearToken, column: column))
    }

    private var isRunning: Bool {
        guard store.settings.showRunningIndicator, tile.kind == .app, let path = tile.appPath else { return false }
        return running.isRunning(path: path)
    }

    private var helpText: String {
        if tile.kind == .app, let path = tile.appPath { return catalog.name(for: path) }
        if tile.kind == .web, let url = WebLink.url(of: tile) {
            let name = tile.title ?? launcher.webIcons.title(for: url) ?? WebLink.displayHost(url)
            return name + "\n" + url.absoluteString
        }
        if tile.kind == .service {
            guard let integration = launcher.services.integration(for: tile) else { return "This service was removed" }
            var lines = [integration.displayName + " · " + (tile.widget?.title ?? "")]
            if let entity = tile.entity { lines.append(entity) }
            if let error = launcher.services.status(for: tile)?.error { lines.append(error) }
            return lines.joined(separator: "\n")
        }
        if tile.kind == .weather { return "Weather\n" + WeatherAPI.attribution }
        return tile.kind.title
    }

    private var background: Color {
        if let hex = tile.color { return Color(hex: hex) }
        switch tile.kind {
        case .app:
            guard let path = tile.appPath else { return Color(hex: Palette.accents[0]) }
            return Color(hex: store.settings.iconColoredTiles ? catalog.tint(for: path) : Palette.autoColor(for: path))
        case .web:
            guard let url = WebLink.url(of: tile) else { return Color(hex: tile.kind.defaultColor) }
            if store.settings.iconColoredTiles, let tint = launcher.webIcons.tint(for: url) { return Color(hex: tint) }
            return Color(hex: Palette.autoColor(for: WebLink.displayHost(url)))
        case .service:
            return Color(hex: launcher.services.integration(for: tile)?.kind.defaultColor ?? tile.kind.defaultColor)
        default:
            return Color(hex: tile.kind.defaultColor)
        }
    }

    private func activate() {
        withAnimation(.easeOut(duration: 0.08)) { pressed = true }
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 90_000_000)
            perform()
            pressed = false
        }
    }

    private func perform() {
        switch tile.kind {
        case .app:
            if let path = tile.appPath { launcher.launch(path: path) }
        case .clock:
            launcher.launch(path: "/System/Applications/Clock.app")
        case .calendar:
            launcher.launch(path: "/System/Applications/Calendar.app")
        case .weather:
            launcher.launch(path: "/System/Applications/Weather.app")
        case .system:
            launcher.launch(path: "/System/Applications/Utilities/Activity Monitor.app")
        case .battery:
            if let url = URL(string: "x-apple.systempreferences:com.apple.Battery-Settings.extension") {
                launcher.open(url: url)
            }
        case .photos:
            launcher.launch(path: "/System/Applications/Photos.app")
        case .news:
            if let link = hub.news.current?.link { launcher.open(url: link) }
        case .desktop:
            launcher.showDesktop()
        case .web:
            if let url = WebLink.url(of: tile) { launcher.open(url: url) }
        case .service:
            launcher.activateService(tile)
        }
    }
}

@MainActor
struct TileMenu: View {
    let tile: Tile
    @EnvironmentObject private var store: LayoutStore
    @EnvironmentObject private var launcher: Launcher
    @EnvironmentObject private var running: RunningApps
    @EnvironmentObject private var catalog: AppCatalog

    var body: some View {
        Menu("Resize") {
            ForEach(tile.sizes) { size in
                Button {
                    withAnimation(.spring(response: 0.35, dampingFraction: 0.85)) {
                        store.update(tile.id) { $0.size = size }
                    }
                } label: {
                    if size == tile.size { Label(size.title, systemImage: "checkmark") } else { Text(size.title) }
                }
            }
        }
        Menu("Color") {
            Button("Automatic") { store.update(tile.id) { $0.color = nil } }
            Divider()
            ForEach(Palette.named, id: \.hex) { color in
                Button(color.name) { store.update(tile.id) { $0.color = color.hex } }
            }
        }
        Menu("Move to Group") {
            ForEach(store.groups) { group in
                Button(group.displayName) {
                    withAnimation(.spring(response: 0.35, dampingFraction: 0.85)) { store.move(tile.id, to: .endOf(group.id)) }
                }
            }
            Divider()
            Button("New Group") {
                withAnimation(.spring(response: 0.35, dampingFraction: 0.85)) { store.move(tile.id, to: .newGroup) }
            }
        }
        if tile.kind == .app, let path = tile.appPath {
            Divider()
            Button("Show in Finder") { launcher.reveal(path: path) }
            if running.isRunning(path: path) {
                Divider()
                QuitMenuItems(path: path, name: catalog.name(for: path))
            }
        }
        if tile.kind == .service {
            Divider()
            ServiceMenuItems(tile: tile)
        }
        if tile.kind == .weather {
            Divider()
            Button(WeatherAPI.attribution) { launcher.open(url: WeatherAPI.attributionURL) }
        }
        if tile.kind == .web {
            Divider()
            Button("Edit Link…") { launcher.editWebTile(tile) }
            Button("Copy Link") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(tile.url ?? "", forType: .string)
            }
            if let url = WebLink.url(of: tile), WebLink.isFetchable(url) {
                Button("Refresh Icon") { launcher.webIcons.load(url, force: true) }
            }
        }
        Divider()
        Button("Unpin from Start") {
            withAnimation(.spring(response: 0.35, dampingFraction: 0.85)) { store.remove(tile.id) }
        }
    }
}

@MainActor
struct TileContent: View {
    let tile: Tile
    let frame: CGSize

    /// Offsets each tile's flip timing so they don't all turn at once.
    private var phase: Double { Double(Palette.stableIndex(tile.id.uuidString, modulo: 40)) / 10 }

    var body: some View {
        switch tile.kind {
        case .app: AppTileContent(tile: tile, frame: frame)
        case .clock: ClockTile(size: tile.size, phase: phase)
        case .calendar: CalendarTile(size: tile.size, phase: phase)
        case .weather: WeatherTile(size: tile.size, phase: phase)
        case .system: SystemTile(size: tile.size, phase: phase)
        case .battery: BatteryTile(size: tile.size)
        case .photos: PhotosTile(size: tile.size, frame: frame)
        case .news: NewsTile(size: tile.size)
        case .desktop: DesktopTile(size: tile.size, frame: frame)
        case .web: WebTileContent(tile: tile, frame: frame)
        case .service: ServiceTileContent(tile: tile, frame: frame, phase: phase)
        }
    }
}

@MainActor
struct AppTileContent: View {
    let tile: Tile
    let frame: CGSize
    @EnvironmentObject private var catalog: AppCatalog

    private var iconSide: CGFloat {
        switch tile.size {
        case .small: return frame.width * 0.7
        case .medium: return frame.height * 0.5
        case .wide: return frame.height * 0.52
        case .large: return frame.height * 0.42
        }
    }

    var body: some View {
        let path = tile.appPath ?? ""
        ZStack(alignment: .bottomLeading) {
            Image(nsImage: catalog.icon(for: path))
                .resizable()
                .interpolation(.high)
                .frame(width: iconSide, height: iconSide)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .offset(y: tile.size == .small ? 0 : -6)
            if tile.size != .small {
                TileLabel(text: catalog.name(for: path))
            }
        }
    }
}

struct TileLabel: View {
    let text: String
    @Environment(\.tileShape) private var shape

    var body: some View {
        Text(text)
            .font(.system(size: 12))
            .foregroundStyle(.white)
            .lineLimit(1)
            .shadow(color: .black.opacity(0.35), radius: 2)
            .padding(.leading, shape.labelInset.leading)
            .padding(.trailing, shape.labelInset.leading)
            .padding(.bottom, shape.labelInset.bottom)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomLeading)
    }
}

// MARK: - Environment

private struct TileShapeKey: EnvironmentKey {
    static let defaultValue = TileShape.square
}

extension EnvironmentValues {
    /// The Settings → Tile shape choice, for views deep inside tiles (labels).
    var tileShape: TileShape {
        get { self[TileShapeKey.self] }
        set { self[TileShapeKey.self] = newValue }
    }
}
