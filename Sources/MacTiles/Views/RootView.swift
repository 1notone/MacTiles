import AppKit
import SwiftUI

/// Grid geometry. One unit = a small tile; medium is 2×2 units, wide 4×2, large 4×4.
struct Metrics {
    static let headerHeight: CGFloat = 120
    static let footerHeight: CGFloat = 64
    static let groupTitleHeight: CGFloat = 36

    let tile: CGFloat
    let gap: CGFloat
    let step: CGFloat
    let rows: Int
    let leftMargin: CGFloat
    let groupSpacing: CGFloat

    let cornerRadius: CGFloat
    let shape: TileShape

    init(size: CGSize, scale: Double, shape: TileShape = .square) {
        let s = CGFloat(min(max(scale, 0.7), 1.6))
        tile = (62 * s).rounded()
        gap = (CGFloat(shape.gap) * s).rounded()
        cornerRadius = CGFloat(shape.cornerRadius) * s
        self.shape = shape
        step = tile + gap
        let available = size.height - Self.headerHeight - Self.footerHeight - Self.groupTitleHeight - 16
        var r = Int((available + gap) / step)
        r = min(max(r, 4), 12)
        if r % 2 == 1 { r -= 1 }        // keep medium tiles aligned
        rows = r
        leftMargin = min(max(size.width * 0.06, 40), 116)
        groupSpacing = (52 * s).rounded()
    }

    func span(_ units: Int) -> CGFloat { CGFloat(units) * step - gap }
    func frame(_ size: TileSize) -> CGSize { CGSize(width: span(size.units.w), height: span(size.units.h)) }
}

@MainActor
struct RootView: View {
    @EnvironmentObject private var launcher: Launcher
    @EnvironmentObject private var store: LayoutStore

    var body: some View {
        GeometryReader { geo in
            // Lay out inside the menu bar and Dock, so nothing jumps when Start
            // moves between the front and the desktop.
            let insets = launcher.chromeInsets
            let inner = CGSize(width: max(0, geo.size.width - insets.leading - insets.trailing),
                               height: max(0, geo.size.height - insets.top - insets.bottom))
            let m = Metrics(size: inner, scale: store.settings.tileScale, shape: store.settings.tileShape)
            ZStack(alignment: .topLeading) {
                BackgroundView(size: geo.size)
                VStack(alignment: .leading, spacing: 0) {
                    HeaderView(metrics: m)
                    content(m)
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                        .clipped()
                    FooterView(metrics: m)
                }
                .padding(insets)
            }
        }
        .contentShape(Rectangle())
        .contextMenu { BackgroundMenu() }
        .overlay {
            if let draft = launcher.webDraft {
                WebTileEditor(draft: draft)
                    .id(draft.id)
                    .transition(.opacity)
            }
        }
        .animation(.easeOut(duration: 0.15), value: launcher.webDraft?.id)
        .overlay {
            if let draft = launcher.newsDraft {
                NewsTileEditor(draft: draft)
                    .id(draft.id)
                    .transition(.opacity)
            }
        }
        .animation(.easeOut(duration: 0.15), value: launcher.newsDraft?.id)
        .overlay {
            if let draft = launcher.serviceDraft {
                ServiceTileEditor(draft: draft)
                    .id(draft.id)
                    .transition(.opacity)
            }
        }
        .animation(.easeOut(duration: 0.15), value: launcher.serviceDraft?.id)
        .environment(\.tileShape, store.settings.tileShape)
        .animation(.spring(response: 0.35, dampingFraction: 0.85), value: store.settings.tileShape)
        .animation(.easeInOut(duration: 0.25), value: store.settings.tileFinish)
        .animation(.easeInOut(duration: 0.25), value: store.settings.tileShadow)
        .ignoresSafeArea()
        .preferredColorScheme(.dark)
        .animation(.easeInOut(duration: 0.32), value: launcher.showingApps)
        .animation(.easeOut(duration: 0.15), value: launcher.query.isEmpty)
    }

    @ViewBuilder private func content(_ m: Metrics) -> some View {
        if !launcher.query.isEmpty {
            SearchResultsView(metrics: m).transition(.opacity)
        } else if launcher.showingApps {
            AppsView(metrics: m).transition(.move(edge: .bottom).combined(with: .opacity))
        } else {
            StartTilesView(metrics: m).transition(.move(edge: .top).combined(with: .opacity))
        }
    }
}

@MainActor
struct HeaderView: View {
    let metrics: Metrics
    @EnvironmentObject private var launcher: Launcher
    @EnvironmentObject private var store: LayoutStore

    var body: some View {
        HStack(alignment: .center, spacing: 20) {
            // No "Start" title and no search box: just start typing to search.
            if launcher.showingApps && launcher.query.isEmpty {
                Text("Apps")
                    .font(.system(size: 44, weight: .light))
                    .foregroundStyle(.white)
                    .transition(.opacity)
            }
            Spacer()
            userBadge
            menu
        }
        .padding(.leading, metrics.leftMargin)
        .padding(.trailing, 40)
        .padding(.top, 24)
        .frame(height: Metrics.headerHeight)
    }

    private var userBadge: some View {
        let parts = store.settings.userName.split(separator: " ", maxSplits: 1).map(String.init)
        let initials = parts.compactMap { $0.first }.map { String($0) }.joined().uppercased()
        return HStack(spacing: 12) {
            VStack(alignment: .trailing, spacing: -2) {
                Text(parts.first ?? "").font(.system(size: 22, weight: .light))
                if parts.count > 1 {
                    Text(parts[1]).font(.system(size: 13, weight: .light)).opacity(0.8)
                }
            }
            ZStack {
                Rectangle().fill(Color.white.opacity(0.2))
                Text(initials.isEmpty ? "?" : initials).font(.system(size: 16, weight: .medium))
            }
            .frame(width: 40, height: 40)
        }
        .foregroundStyle(.white)
    }

    private var menu: some View {
        Menu {
            Menu("Add Live Tile") {
                ForEach(TileKind.liveKinds) { kind in
                    Button { launcher.addLiveTile(kind) } label: { Label(kind.title, systemImage: kind.symbol) }
                }
            }
            Button { launcher.addWebTile() } label: { Label("Add Web Tile…", systemImage: "globe") }
            Button { launcher.addServiceTile() } label: { Label("Add Service Tile…", systemImage: "server.rack") }
            Divider()
            Button("Settings…") { launcher.openSettings() }
            Button("Quit MacTiles") { NSApp.terminate(nil) }
        } label: {
            Image(systemName: "ellipsis")
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .foregroundStyle(.white)
    }
}

@MainActor
struct FooterView: View {
    let metrics: Metrics
    @EnvironmentObject private var launcher: Launcher

    var body: some View {
        HStack {
            Button {
                launcher.showingApps.toggle()
            } label: {
                Image(systemName: launcher.showingApps ? "arrow.up.circle" : "arrow.down.circle")
                    .font(.system(size: 28, weight: .ultraLight))
                    .foregroundStyle(.white.opacity(0.85))
            }
            .buttonStyle(.plain)
            .help(launcher.showingApps ? "Back to Start" : "All apps")
            Spacer()
        }
        .padding(.leading, metrics.leftMargin)
        .frame(height: Metrics.footerHeight)
    }
}

/// Right-click on any empty part of the launcher (not a tile, app or group name).
@MainActor
struct BackgroundMenu: View {
    @EnvironmentObject private var launcher: Launcher

    var body: some View {
        Button("MacTiles Settings…") { launcher.openSettings() }
        Button("Change Wallpaper…") { launcher.openSettings() }
        Divider()
        Menu("Add Live Tile") {
            ForEach(TileKind.liveKinds) { kind in
                Button { launcher.addLiveTile(kind) } label: { Label(kind.title, systemImage: kind.symbol) }
            }
        }
        Button("Add Web Tile…") { launcher.addWebTile() }
        Button("Add Service Tile…") { launcher.addServiceTile() }
        Button(launcher.showingApps ? "Back to Start" : "All Apps") { launcher.showingApps.toggle() }
        Button("Show Desktop") { launcher.showDesktop() }
    }
}
