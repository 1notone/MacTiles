import AppKit
import SwiftUI

// MARK: - Tile content

/// A service tile: Pi-hole stats, what's playing on Plex, a Home Assistant light, your Proxmox
/// cluster… Every service is drawn from the same `ServiceSnapshot`, in MacTiles' Metro style.
@MainActor
struct ServiceTileContent: View {
    let tile: Tile
    let frame: CGSize
    let phase: Double
    @EnvironmentObject private var services: ServiceHub

    private var integration: Integration? { services.integration(for: tile) }
    private var widget: ServiceWidget { tile.widget ?? .resources }

    var body: some View {
        let status = services.status(for: tile)
        Group {
            if let snapshot = status?.snapshot {
                content(snapshot)
                    .overlay(alignment: .topTrailing) {
                        if let error = status?.error { ErrorBadge(message: error) }
                    }
            } else if let error = status?.error {
                message(symbol: "exclamationmark.triangle", text: tile.size == .small ? nil : error)
            } else {
                message(symbol: integration?.kind.symbol ?? "server.rack", text: tile.size == .small ? nil : "Connecting…")
            }
        }
        .overlay {
            if tile.size != .small { TileLabel(text: label(status?.snapshot)) }
        }
    }

    private func label(_ snapshot: ServiceSnapshot?) -> String {
        if let t = tile.title, !t.isEmpty { return t }
        if widget == .entity, let name = snapshot?.caption, !name.isEmpty { return name }
        if let name = snapshot?.name, !name.isEmpty { return name }
        guard let integration else { return "Service" }
        if integration.kind.widgets.count > 1 && tile.size != .medium { return "\(integration.displayName) · \(widget.title)" }
        return integration.displayName
    }

    private func message(symbol: String, text: String?) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Image(systemName: symbol).font(.system(size: tile.size == .small ? 22 : 26, weight: .light))
            if let text {
                Text(text)
                    .font(.system(size: 11))
                    .opacity(0.85)
                    .lineLimit(tile.size == .medium ? 3 : 4)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(EdgeInsets(top: 10, leading: 10, bottom: 26, trailing: 10))
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: tile.size == .small ? .center : .topLeading)
    }

    @ViewBuilder private func content(_ s: ServiceSnapshot) -> some View {
        switch tile.size {
        case .small:
            SmallServiceFace(snapshot: s, symbol: s.symbol ?? integration?.kind.symbol ?? "server.rack")
        case .medium:
            let pages = mediumPages(s)
            FlipFaces(count: pages, interval: 7, phase: phase) { i in
                if i == 0 { SummaryFace(snapshot: s, widget: widget, size: tile.size) }
                else { ItemFace(item: s.items[i - 1], compact: true) }
            }
        case .wide:
            let pages = widePages(s)
            FlipFaces(count: pages, interval: 7, phase: phase) { i in
                if i == 0 { WideSummaryFace(snapshot: s, widget: widget) }
                else { ItemFace(item: s.items[i - 1], compact: false) }
            }
        case .large:
            LargeServiceFace(snapshot: s, widget: widget)
        }
    }

    /// Media and calendar widgets flip through posters; health widgets stay on their numbers.
    private var showsItems: Bool {
        switch widget {
        case .nowPlaying, .recentlyAdded, .upcoming, .requests, .generation: return true
        default: return false
        }
    }

    // While a job runs, the tile stays on its live progress instead of flipping away.
    private func mediumPages(_ s: ServiceSnapshot) -> Int { showsItems && !s.busy ? 1 + min(s.items.count, 4) : 1 }
    private func widePages(_ s: ServiceSnapshot) -> Int { showsItems && !s.busy ? 1 + min(s.items.count, 5) : 1 }
}

private struct ErrorBadge: View {
    let message: String

    var body: some View {
        Image(systemName: "exclamationmark.triangle.fill")
            .font(.system(size: 10))
            .foregroundStyle(.yellow)
            .padding(6)
            .help(message)
    }
}

/// 1×1: the state at a glance.
private struct SmallServiceFace: View {
    let snapshot: ServiceSnapshot
    let symbol: String

    var body: some View {
        VStack(spacing: 2) {
            if snapshot.headline.count <= 5 && snapshot.symbol == nil {
                Text(snapshot.headline).font(.system(size: 17, weight: .light)).monospacedDigit()
                    .lineLimit(1).minimumScaleFactor(0.6)
            } else {
                Image(systemName: symbol).font(.system(size: 22, weight: .light))
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .opacity(snapshot.isOn == false ? 0.55 : 1)
    }
}

/// The headline number with its caption, and a gauge or the first stats underneath.
private struct SummaryFace: View {
    let snapshot: ServiceSnapshot
    let widget: ServiceWidget
    let size: TileSize

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(alignment: .top) {
                if let symbol = snapshot.symbol {
                    Image(systemName: symbol).font(.system(size: 22, weight: .light))
                }
                Spacer(minLength: 0)
                StateBadge(snapshot: snapshot, widget: widget)
            }
            Spacer(minLength: 0)
            Text(snapshot.headline.isEmpty ? "—" : snapshot.headline)
                .font(.system(size: 30, weight: .ultraLight))
                .monospacedDigit()
                .lineLimit(1)
                .minimumScaleFactor(0.5)
            if widget != .entity, !snapshot.caption.isEmpty {
                Text(caption).font(.system(size: 11)).opacity(0.85).lineLimit(1)
            }
            if !snapshot.series.isEmpty {
                Sparkline(values: snapshot.series).frame(height: size == .medium ? 18 : 22).padding(.top, 2)
            } else if let progress = snapshot.progress {
                Bar(fraction: progress).padding(.top, 2)
            } else if let gauge = snapshot.gauges.first {
                Bar(fraction: gauge.fraction).padding(.top, 2)
            }
        }
        .padding(EdgeInsets(top: 10, leading: 10, bottom: 26, trailing: 10))
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private var caption: String {
        if widget == .dnsSummary, snapshot.isOn == false { return "blocking paused" }
        if snapshot.items.isEmpty, !snapshot.emptyText.isEmpty, snapshot.headline == "0" { return snapshot.emptyText }
        return snapshot.caption
    }
}

/// "Paused", "Off", "Down" — shown only when something isn't in its normal state.
private struct StateBadge: View {
    let snapshot: ServiceSnapshot
    let widget: ServiceWidget

    var body: some View {
        if let text {
            Text(text)
                .font(.system(size: 9, weight: .bold))
                .textCase(.uppercase)
                .padding(.horizontal, 5)
                .padding(.vertical, 2)
                .background(Color.black.opacity(0.3))
        }
    }

    private var text: String? {
        guard snapshot.isOn == false else { return nil }
        switch widget {
        case .dnsSummary: return "Paused"
        case .network: return "Offline"
        case .firewall: return "Gateway down"
        case .systems: return "System down"
        case .resources: return "Check"
        case .entity: return nil       // the headline already says Off / Closed
        default: return nil
        }
    }
}

/// 4×2: headline on the left, stats or gauges on the right.
private struct WideSummaryFace: View {
    let snapshot: ServiceSnapshot
    let widget: ServiceWidget

    var body: some View {
        HStack(alignment: .top, spacing: 14) {
            SummaryFace(snapshot: snapshot, widget: widget, size: .wide)
                .padding(.trailing, -10)
                .frame(maxWidth: 150)
            VStack(alignment: .leading, spacing: 5) {
                if !snapshot.traffic.isEmpty {
                    ForEach(snapshot.traffic.prefix(4)) { t in TrafficRow(traffic: t) }
                } else if !snapshot.gauges.isEmpty && widget != .dnsSummary {
                    ForEach(Array(snapshot.gauges.prefix(3).enumerated()), id: \.offset) { _, g in GaugeRow(gauge: g) }
                } else if !snapshot.stats.isEmpty {
                    ForEach(Array(snapshot.stats.prefix(4).enumerated()), id: \.offset) { _, s in StatRow(stat: s) }
                } else {
                    ForEach(snapshot.items.prefix(3)) { item in
                        Text(item.title).font(.system(size: 11)).lineLimit(1)
                    }
                }
            }
            .padding(.top, 12)
            .padding(.trailing, 10)
            .frame(maxWidth: .infinity, alignment: .topLeading)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}

/// 4×4: everything — headline, gauges, stats and the list.
private struct LargeServiceFace: View {
    let snapshot: ServiceSnapshot
    let widget: ServiceWidget
    @EnvironmentObject private var services: ServiceHub

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                if let symbol = snapshot.symbol { Image(systemName: symbol).font(.system(size: 26, weight: .light)) }
                Text(snapshot.headline.isEmpty ? "—" : snapshot.headline)
                    .font(.system(size: 40, weight: .ultraLight))
                    .monospacedDigit()
                    .lineLimit(1)
                    .minimumScaleFactor(0.5)
                if widget != .entity {
                    Text(snapshot.isOn == false && widget == .dnsSummary ? "blocking paused" : snapshot.caption)
                        .font(.system(size: 12)).opacity(0.85).lineLimit(1)
                }
                Spacer(minLength: 0)
                StateBadge(snapshot: snapshot, widget: widget)
            }
            if !snapshot.series.isEmpty {
                Sparkline(values: snapshot.series).frame(height: 34)
            }
            if let progress = snapshot.progress {
                Bar(fraction: progress)
            }
            if !snapshot.traffic.isEmpty {
                VStack(alignment: .leading, spacing: 3) {
                    ForEach(snapshot.traffic.prefix(5)) { t in TrafficRow(traffic: t) }
                }
            }
            ForEach(Array(snapshot.gauges.prefix(4).enumerated()), id: \.offset) { _, g in GaugeRow(gauge: g) }
            if !snapshot.stats.isEmpty {
                LazyVGrid(columns: [GridItem(.flexible(), alignment: .leading), GridItem(.flexible(), alignment: .leading)], spacing: 4) {
                    ForEach(Array(snapshot.stats.prefix(6).enumerated()), id: \.offset) { _, s in StatRow(stat: s) }
                }
            }
            if !snapshot.items.isEmpty {
                Rectangle().fill(Color.white.opacity(0.25)).frame(height: 1)
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(snapshot.items.prefix(rowCount)) { item in ItemRow(item: item, poster: item.image.flatMap { services.posters[$0] }) }
                }
            } else if !snapshot.emptyText.isEmpty && widget != .entity {
                Text(snapshot.emptyText).font(.system(size: 12)).opacity(0.7)
            }
            Spacer(minLength: 0)
        }
        .padding(EdgeInsets(top: 10, leading: 10, bottom: 26, trailing: 10))
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .clipped()
    }

    private var rowCount: Int {
        // Lines already used by the parts above the list (split up so the compiler checks it quickly).
        let gaugeLines: Int = min(snapshot.gauges.count, 4)
        let statLines: Int = snapshot.stats.isEmpty ? 0 : (min(snapshot.stats.count, 6) + 1) / 2
        let graphLines: Int = snapshot.series.isEmpty ? 0 : 2
        let trafficLines: Int = (min(snapshot.traffic.count, 5) + 1) / 2
        let used: Int = gaugeLines + statLines + graphLines + trafficLines
        return max(1, 7 - used)
    }
}

/// One movie, episode, container or guest — with its poster filling the tile when there is one.
private struct ItemFace: View {
    let item: ServiceSnapshot.Item
    let compact: Bool
    @EnvironmentObject private var services: ServiceHub

    var body: some View {
        ZStack(alignment: .bottomLeading) {
            if let url = item.image, let poster = services.posters[url] {
                GeometryReader { geo in
                    Image(nsImage: poster)
                        .resizable()
                        .aspectRatio(contentMode: .fill)
                        .frame(width: geo.size.width, height: geo.size.height, alignment: .top)
                        .clipped()
                }
                LinearGradient(colors: [.clear, .black.opacity(0.75)], startPoint: .center, endPoint: .bottom)
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(item.title)
                    .font(.system(size: compact ? 12 : 14, weight: .semibold))
                    .lineLimit(2)
                if !item.subtitle.isEmpty {
                    Text(item.subtitle).font(.system(size: 10.5)).opacity(0.9).lineLimit(compact ? 1 : 2)
                }
                if let progress = item.progress { Bar(fraction: progress).padding(.top, 3) }
            }
            .shadow(color: .black.opacity(0.5), radius: 2)
            .padding(EdgeInsets(top: 10, leading: 10, bottom: 26, trailing: 10))
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

private struct ItemRow: View {
    let item: ServiceSnapshot.Item
    let poster: NSImage?

    var body: some View {
        HStack(spacing: 8) {
            if let poster {
                Image(nsImage: poster).resizable().aspectRatio(contentMode: .fill).frame(width: 22, height: 32).clipped()
            } else {
                Circle().fill(Color.white.opacity(item.isActive ? 0.95 : 0.3)).frame(width: 6, height: 6)
            }
            VStack(alignment: .leading, spacing: 0) {
                Text(item.title).font(.system(size: 12, weight: .medium)).lineLimit(1)
                if !item.subtitle.isEmpty { Text(item.subtitle).font(.system(size: 10)).opacity(0.8).lineLimit(1) }
            }
            Spacer(minLength: 0)
            if let progress = item.progress {
                Text(Fmt.percent(progress)).font(.system(size: 10)).monospacedDigit().opacity(0.8)
            }
        }
    }
}

/// "WAN   ↓ 48 Mb/s  ↑ 3.1 Mb/s"
private struct TrafficRow: View {
    let traffic: ServiceSnapshot.Traffic

    var body: some View {
        HStack(spacing: 6) {
            Text(traffic.name).font(.system(size: 10, weight: .semibold)).opacity(0.85).lineLimit(1)
            Spacer(minLength: 4)
            Text("↓ " + Fmt.bitrate(traffic.down)).font(.system(size: 10.5)).monospacedDigit().lineLimit(1)
            Text("↑ " + Fmt.bitrate(traffic.up)).font(.system(size: 10.5)).monospacedDigit().opacity(0.8).lineLimit(1)
        }
        .minimumScaleFactor(0.75)
    }
}

private struct GaugeRow: View {
    let gauge: ServiceSnapshot.Gauge

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                Text(gauge.label).font(.system(size: 10, weight: .semibold)).opacity(0.85).lineLimit(1)
                Spacer(minLength: 4)
                Text(gauge.detail).font(.system(size: 10)).monospacedDigit().opacity(0.85).lineLimit(1)
            }
            Bar(fraction: gauge.fraction)
        }
    }
}

private struct StatRow: View {
    let stat: ServiceSnapshot.Stat

    var body: some View {
        HStack(spacing: 6) {
            Text(stat.label).font(.system(size: 10, weight: .semibold)).opacity(0.75).lineLimit(1)
            Spacer(minLength: 2)
            Text(stat.value).font(.system(size: 11)).monospacedDigit().lineLimit(1).minimumScaleFactor(0.7)
        }
    }
}

/// A thin Metro progress bar.
private struct Bar: View {
    let fraction: Double

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Rectangle().fill(Color.white.opacity(0.25))
                Rectangle().fill(Color.white).frame(width: geo.size.width * min(max(fraction, 0), 1))
            }
        }
        .frame(height: 4)
    }
}

// MARK: - Right-click menu

/// Refresh, pause blocking, toggle, start/stop containers…
@MainActor
struct ServiceMenuItems: View {
    let tile: Tile
    @EnvironmentObject private var services: ServiceHub
    @EnvironmentObject private var launcher: Launcher

    var body: some View {
        let snapshot = services.status(for: tile)?.snapshot
        if let integration = services.integration(for: tile) {
            Button("Open \(integration.displayName)") { launcher.activateService(tile, openOnly: true) }
            Button("Refresh") { services.refresh(tile) }
            switch tile.widget {
            case .dnsSummary:
                if snapshot?.isOn == false {
                    Button("Resume Blocking") { services.perform(.resumeBlocking, on: tile) }
                } else {
                    Menu("Pause Blocking") {
                        Button("For 1 Minute") { services.perform(.pauseBlocking(seconds: 60), on: tile) }
                        Button("For 5 Minutes") { services.perform(.pauseBlocking(seconds: 300), on: tile) }
                        Button("For 30 Minutes") { services.perform(.pauseBlocking(seconds: 1800), on: tile) }
                        Button("For 1 Hour") { services.perform(.pauseBlocking(seconds: 3600), on: tile) }
                        Divider()
                        Button("Until I Resume") { services.perform(.pauseBlocking(seconds: nil), on: tile) }
                    }
                }
            case .entity:
                if let entity = tile.entity, HomeAssistant.service(for: HomeAssistant.domain(entity)) != nil {
                    Button(HomeAssistant.isRunnable(HomeAssistant.domain(entity)) ? "Run" : "Toggle") {
                        services.perform(.toggleEntity(entity), on: tile)
                    }
                }
            case .generation:
                if snapshot?.busy == true {
                    Button("Interrupt Current Job") { services.perform(.interrupt, on: tile) }
                }
                Button("Clear Queue") { services.perform(.clearQueue, on: tile) }
            case .containers where integration.kind == .docker:
                if let items = snapshot?.items, !items.isEmpty {
                    Menu("Containers") {
                        ForEach(items.prefix(25)) { item in
                            Menu(item.title) {
                                if item.isActive {
                                    Button("Stop") { services.perform(.container(id: item.id, verb: "stop"), on: tile) }
                                    Button("Restart") { services.perform(.container(id: item.id, verb: "restart"), on: tile) }
                                } else {
                                    Button("Start") { services.perform(.container(id: item.id, verb: "start"), on: tile) }
                                }
                            }
                        }
                    }
                }
            default:
                EmptyView()
            }
            Divider()
            Button("Edit Tile…") { launcher.editServiceTile(tile) }
            Button("Edit \(integration.displayName) Connection…") { launcher.openSettings(editing: integration.id) }
        } else {
            Button("Choose a Service…") { launcher.editServiceTile(tile) }
        }
    }
}

// MARK: - Add / edit panel

struct ServiceTileDraft: Identifiable, Equatable {
    let id = UUID()
    var tileID: UUID?
    var integrationID: UUID?
    var widget: ServiceWidget?
    var entity: String
    var name: String
    var destination: TileDestination?
}

/// A Metro-style panel over Start: pick a connected service, what to show, and (for Home
/// Assistant) which entity.
@MainActor
struct ServiceTileEditor: View {
    let draft: ServiceTileDraft
    @EnvironmentObject private var launcher: Launcher
    @EnvironmentObject private var store: LayoutStore
    @EnvironmentObject private var services: ServiceHub

    @State private var integrationID: UUID?
    @State private var widget: ServiceWidget = .resources
    @State private var entity = ""
    @State private var name = ""
    @State private var entities: [ServiceAPI.HAEntity] = []
    @State private var entityQuery = ""
    @State private var entityStatus = ""
    @State private var error = ""

    private var integrations: [Integration] { store.settings.integrations }
    private var integration: Integration? { integrations.first { $0.id == integrationID } }
    private var isEditing: Bool { draft.tileID != nil }

    var body: some View {
        ZStack {
            Color.black.opacity(0.55)
                .ignoresSafeArea()
                .onTapGesture(perform: cancel)
            VStack(alignment: .leading, spacing: 16) {
                Text(isEditing ? "Edit service tile" : "Add a service tile")
                    .font(.system(size: 28, weight: .light))
                if integrations.isEmpty {
                    emptyState
                } else {
                    form
                }
            }
            .foregroundStyle(.white)
            .padding(28)
            .frame(width: 520)
            .background(Color(hex: "#1D1D1D"))
            .overlay(Rectangle().strokeBorder(Color.white.opacity(0.12), lineWidth: 1))
            .shadow(color: .black.opacity(0.5), radius: 30, y: 10)
        }
        .onAppear(perform: load)
        .onChange(of: integrationID) { _, _ in
            // Keep the widget valid for the newly chosen service.
            if let kind = integration?.kind, !kind.widgets.contains(widget) { widget = kind.widgets[0] }
            error = ""
        }
        .onExitCommand(perform: cancel)
    }

    private var emptyState: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Connect Plex, Pi-hole, Home Assistant, Proxmox and more in Settings → Integrations, then add their tiles here.")
                .font(.system(size: 14))
                .opacity(0.85)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 10) {
                Spacer()
                Button("Cancel", action: cancel).buttonStyle(MetroButtonStyle(filled: false))
                Button("Connect a Service…") {
                    launcher.serviceDraft = nil
                    launcher.openSettings(addingIntegration: true)
                }
                .buttonStyle(MetroButtonStyle(filled: true))
            }
        }
    }

    @ViewBuilder private var form: some View {
        labeled("Service") {
            Picker("", selection: $integrationID) {
                ForEach(ServiceKind.Category.allCases) { category in
                    let members = integrations.filter { $0.kind.category == category }
                    if !members.isEmpty {
                        Section(category.rawValue) {
                            ForEach(members) { i in
                                Label(i.displayName, systemImage: i.kind.symbol).tag(Optional(i.id))
                            }
                        }
                    }
                }
            }
            .labelsHidden()
            .pickerStyle(.menu)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        if let integration {
            if integration.kind.widgets.count > 1 {
                labeled("Show") {
                    Picker("", selection: $widget) {
                        ForEach(integration.kind.widgets) { w in Text(w.title).tag(w) }
                    }
                    .labelsHidden()
                    .pickerStyle(.segmented)
                }
            }
            Text(widget.detail).font(.system(size: 12)).opacity(0.65)
            if integration.kind == .homeAssistant || integration.kind == .beszel { entityPicker }
        }
        labeled("Name (optional)") {
            TextField("", text: $name, prompt: Text(integration?.displayName ?? "Shown on the tile").foregroundColor(.white.opacity(0.35)))
                .textFieldStyle(.plain)
                .font(.system(size: 15))
                .padding(.horizontal, 10)
                .padding(.vertical, 8)
                .background(Color.white.opacity(0.09))
                .onSubmit(save)
        }
        if !error.isEmpty {
            Text(error).font(.system(size: 12)).foregroundStyle(Color(hex: "#FF8A80"))
        }
        HStack(spacing: 10) {
            Button("Manage Services…") {
                launcher.serviceDraft = nil
                launcher.openSettings()
            }
            .buttonStyle(.plain)
            .font(.system(size: 12))
            .opacity(0.75)
            Spacer()
            Button("Cancel", action: cancel).buttonStyle(MetroButtonStyle(filled: false))
            Button(isEditing ? "Save" : "Add", action: save).buttonStyle(MetroButtonStyle(filled: true))
        }
    }

    private var filteredEntities: [ServiceAPI.HAEntity] {
        let q = entityQuery.trimmingCharacters(in: .whitespaces).lowercased()
        guard !q.isEmpty else { return entities }
        return entities.filter { $0.name.lowercased().contains(q) || $0.id.lowercased().contains(q) }
    }

    private var pickingSystems: Bool { integration?.kind == .beszel }

    private var entityPicker: some View {
        labeled(pickingSystems ? "System" : "Entity") {
            VStack(alignment: .leading, spacing: 6) {
                TextField("", text: $entityQuery, prompt: Text(pickingSystems ? "Search systems…" : "Search lights, switches, sensors…").foregroundColor(.white.opacity(0.35)))
                    .textFieldStyle(.plain)
                    .font(.system(size: 14))
                    .padding(.horizontal, 10)
                    .padding(.vertical, 7)
                    .background(Color.white.opacity(0.09))
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        if pickingSystems {
                            Button {
                                entity = ""
                                error = ""
                            } label: {
                                HStack(spacing: 8) {
                                    Image(systemName: "square.grid.2x2").frame(width: 18)
                                    Text("All systems").font(.system(size: 13))
                                    Spacer()
                                }
                                .padding(.horizontal, 8)
                                .padding(.vertical, 7)
                                .background(entity.isEmpty ? Color.white.opacity(0.22) : Color.clear)
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                        }
                        ForEach(filteredEntities.prefix(300)) { e in
                            Button {
                                entity = e.id
                                error = ""
                            } label: {
                                HStack(spacing: 8) {
                                    Image(systemName: pickingSystems ? "server.rack" : HomeAssistant.symbol(domain: e.domain, deviceClass: nil, on: e.state == "on"))
                                        .frame(width: 18)
                                    VStack(alignment: .leading, spacing: 0) {
                                        Text(e.name).font(.system(size: 13)).lineLimit(1)
                                        if !pickingSystems {
                                            Text(e.id).font(.system(size: 10)).opacity(0.55).lineLimit(1)
                                        }
                                    }
                                    Spacer()
                                    Text(pickingSystems ? e.state.capitalized : HomeAssistant.label(e.state)).font(.system(size: 11)).opacity(0.7).lineLimit(1)
                                }
                                .padding(.horizontal, 8)
                                .padding(.vertical, 5)
                                .background(entity == e.id ? Color.white.opacity(0.22) : Color.clear)
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
                .frame(height: 180)
                .background(Color.white.opacity(0.04))
                if !entityStatus.isEmpty {
                    Text(entityStatus).font(.system(size: 11)).opacity(0.7)
                }
            }
        }
        .task(id: integrationID) { await loadEntities() }
    }

    private func labeled<Content: View>(_ label: String, @ViewBuilder _ content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(label).font(.system(size: 12, weight: .semibold)).opacity(0.75)
            content()
        }
    }

    private func load() {
        let id = draft.integrationID ?? integrations.first?.id
        integrationID = id
        let kind = integrations.first { $0.id == id }?.kind
        widget = draft.widget ?? kind?.widgets.first ?? .resources
        entity = draft.entity
        name = draft.name
    }

    private func loadEntities() async {
        guard let integration, integration.kind == .homeAssistant || integration.kind == .beszel else { return }
        entities = []
        entityStatus = "Loading entities…"
        do {
            entities = try await services.entities(of: integration)
            entityStatus = entities.isEmpty ? (integration.kind == .beszel ? "No systems found." : "No entities found.") : ""
        } catch {
            entityStatus = ServiceHub.message(error)
        }
    }

    private func save() {
        guard let integration else { return }
        let chosen = integration.kind.widgets.contains(widget) ? widget : integration.kind.widgets[0]
        if integration.kind == .homeAssistant, entity.isEmpty {
            error = "Choose an entity."
            return
        }
        let title = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let entityValue: String?
        switch integration.kind {
        case .homeAssistant: entityValue = entity
        case .beszel: entityValue = entity.isEmpty ? nil : entity      // empty = all systems
        default: entityValue = nil
        }
        withAnimation(.spring(response: 0.35, dampingFraction: 0.85)) {
            if let id = draft.tileID {
                store.update(id) { tile in
                    if tile.widget != chosen, !chosen.sizes.contains(tile.size) { tile.size = chosen.defaultSize }
                    tile.integrationID = integration.id
                    tile.widget = chosen
                    tile.entity = entityValue
                    tile.title = title.isEmpty ? nil : title
                }
            } else {
                var tile = Tile.service(integration.id, widget: chosen, entity: entityValue, title: title.isEmpty ? nil : title)
                if chosen == .entity { tile.size = HomeAssistant.isRunnable(HomeAssistant.domain(entity)) ? .small : .medium }
                if chosen == .systems, entityValue != nil { tile.size = .medium }
                store.addService(tile, at: draft.destination ?? .lastGroup)
            }
        }
        launcher.serviceDraft = nil
        if services.active { services.tick() }
    }

    private func cancel() { launcher.serviceDraft = nil }
}
