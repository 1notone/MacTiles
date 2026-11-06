import AppKit
import ServiceManagement
import SwiftUI

@MainActor
struct SettingsView: View {
    @EnvironmentObject private var launcher: Launcher
    @EnvironmentObject private var store: LayoutStore

    @State private var cityQuery = ""
    @State private var cityStatus = ""
    @State private var launchAtLogin = SMAppService.mainApp.status == .enabled
    @State private var loginError = ""
    @State private var confirmReset = false
    @State private var hexDraft = ""
    @State private var hexError = ""
    @State private var wallpaperError = ""
    @State private var importingWallpaper = false
    @State private var integrationEditor: IntegrationsSection.EditorTarget?

    static var version: String {
        let info = Bundle.main.infoDictionary
        let short = info?["CFBundleShortVersionString"] as? String ?? "dev"
        let build = info?["CFBundleVersion"] as? String
        return build.map { "\(short) (\($0))" } ?? short
    }

    /// The background as a SwiftUI color, for the color wheel. Stored as "#RRGGBB" in layout.json.
    private var backgroundColor: Binding<Color> {
        Binding(
            get: { Color(hex: store.settings.background) },
            set: { color in
                let hex = NSColor(color).hexString
                if hex != store.settings.background { store.settings.background = hex }
            })
    }

    /// Start's "Connect a Service…" and a tile's "Edit Connection…" open the editor.
    private func takeIntegrationRequest() {
        guard let request = launcher.integrationRequest else { return }
        launcher.integrationRequest = nil
        let target = request.target.flatMap { id in store.settings.integrations.first { $0.id == id } }
        integrationEditor = IntegrationsSection.EditorTarget(integration: target)
    }

    private func applyHex() {
        if let hex = Palette.normalizedHex(hexDraft) {
            store.settings.background = hex
            hexError = ""
        } else {
            hexError = "Use six hex digits, like #25115A"
        }
    }

    var body: some View {
        Form {
            Section("Start screen") {
                TextField("Name", text: $store.settings.userName)
                Picker("Background", selection: $store.settings.backgroundStyle) {
                    ForEach(BackgroundStyle.allCases) { style in Text(style.title).tag(style) }
                }
                .pickerStyle(.segmented)
                switch store.settings.backgroundStyle {
                case .color:
                    colorRows(label: "Color")
                case .media:
                    mediaRows
                case .live:
                    LabeledContent("Style") { livePreviews }
                    colorRows(label: "Tint")
                }
                if store.settings.backgroundStyle != .color {
                    Text("Animated wallpapers pause when Start is hidden or covered, in Low Power Mode, and when Reduce Motion is on.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                LabeledContent("Tile size") {
                    Slider(value: $store.settings.tileScale, in: 0.8...1.5).frame(width: 220)
                }
                Picker("Tile shape", selection: $store.settings.tileShape) {
                    ForEach(TileShape.allCases) { shape in
                        Text(shape.title).tag(shape)
                    }
                }
                .pickerStyle(.segmented)
                Picker("Tile finish", selection: $store.settings.tileFinish) {
                    ForEach(TileFinish.allCases) { finish in Text(finish.title).tag(finish) }
                }
                .pickerStyle(.segmented)
                if store.settings.tileFinish == .glass {
                    LabeledContent("Glass tint") {
                        HStack(spacing: 8) {
                            Text("Clear").font(.caption).foregroundStyle(.secondary)
                            Slider(value: $store.settings.glassTint, in: 0.1...0.9).frame(width: 170)
                            Text("Colored").font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    Text("Glass shows your wallpaper through the tiles — it looks best with a picture, video or live wallpaper.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Picker("Tile shadow", selection: $store.settings.tileShadow) {
                    ForEach(TileShadow.allCases) { shadow in Text(shadow.title).tag(shadow) }
                }
                .pickerStyle(.segmented)
                Toggle("Color app tiles from their icons", isOn: $store.settings.iconColoredTiles)
                Toggle("Show a dot on tiles of apps that are running", isOn: $store.settings.showRunningIndicator)
            }

            Section("Behavior") {
                Toggle("Keep Start on the desktop behind your apps", isOn: $store.settings.keepOnDesktop)
                Text(store.settings.keepOnDesktop
                     ? "Like Windows 8: launching an app puts Start behind it, and you see Start whenever your windows are closed or minimized."
                     : "Start appears only when you open it, and disappears when you launch an app.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Toggle("Show MacTiles in the Dock (click it to open Start)", isOn: $store.settings.showInDock)
            }

            Section("Opening Start") {
                Picker("Keyboard shortcut", selection: $store.settings.hotKey) {
                    ForEach(HotKeyPreset.all) { preset in Text(preset.label).tag(preset.id) }
                }
                Toggle("Open by moving the pointer into the bottom-left corner", isOn: $store.settings.hotCorner)
                Toggle("Corner also closes Start and shows the desktop when Start is open", isOn: $store.settings.hotCornerToggles)
                    .disabled(!store.settings.hotCorner)
                    .padding(.leading, 18)
                Toggle("Open MacTiles at login", isOn: $launchAtLogin)
                if !loginError.isEmpty {
                    Text(loginError).font(.caption).foregroundStyle(.secondary)
                }
            }

            Section("Live tiles") {
                LabeledContent("Weather city") {
                    HStack {
                        TextField("", text: $cityQuery, prompt: Text("e.g. Lisbon"))
                            .frame(width: 180)
                            .onSubmit(findCity)
                        Button("Find", action: findCity)
                    }
                }
                if !cityStatus.isEmpty {
                    Text(cityStatus).font(.caption).foregroundStyle(.secondary)
                }
                Toggle("Show temperatures in Fahrenheit", isOn: $store.settings.fahrenheit)
                HStack(spacing: 0) {
                    Text("Weather data by ")
                    Link("Open-Meteo.com", destination: WeatherAPI.attributionURL)
                    Text(" (CC BY 4.0).")
                }
                .font(.caption)
                .foregroundStyle(.secondary)
                TextField("News feed (RSS or Atom URL)", text: $store.settings.newsFeed)
                    .onSubmit { launcher.hub.liveSettingsChanged(active: launcher.tilesLive) }
                LabeledContent("Photos folder") {
                    HStack {
                        Text((store.settings.photosFolder as NSString).abbreviatingWithTildeInPath)
                            .lineLimit(1)
                            .truncationMode(.middle)
                            .foregroundStyle(.secondary)
                        Button("Choose…", action: choosePhotosFolder)
                    }
                }
                Toggle("Show upcoming events on the Calendar tile", isOn: $store.settings.calendarEvents)
            }

            IntegrationsSection(editing: $integrationEditor)

            Section {
                HStack {
                    Button("Show Layout File") {
                        NSWorkspace.shared.activateFileViewerSelecting([LayoutStore.fileURL])
                    }
                    Button("Reset Layout…") { confirmReset = true }
                    Button("Uninstall MacTiles…") { Installer.confirmAndUninstall() }
                    Spacer()
                    Text("MacTiles \(Self.version)").foregroundStyle(.secondary)
                }
            }
        }
        .formStyle(.grouped)
        .frame(width: 600, height: 840)
        .sheet(item: $integrationEditor) { target in
            IntegrationEditor(original: target.integration) { integrationEditor = nil }
                .mactilesEnvironment(launcher)
        }
        .onAppear(perform: takeIntegrationRequest)
        .onChange(of: launcher.integrationRequest) { _, _ in takeIntegrationRequest() }
        .onAppear {
            cityQuery = store.settings.weatherCity ?? ""
            hexDraft = store.settings.background
            // Open the system color panel on its wheel, without an opacity slider.
            NSColorPanel.shared.mode = .wheel
            NSColorPanel.shared.showsAlpha = false
        }
        .onChange(of: store.settings.background) { _, hex in
            hexDraft = hex
            hexError = ""
        }
        .onChange(of: store.settings.hotKey) { _, _ in launcher.applyHotKey() }
        .onChange(of: store.settings.hotCorner) { _, _ in launcher.applyHotCorner() }
        .onChange(of: store.settings.keepOnDesktop) { _, _ in launcher.applyPersistence() }
        .onChange(of: store.settings.showInDock) { _, _ in launcher.applyDockIcon() }
        .onChange(of: store.settings.fahrenheit) { _, _ in
            launcher.hub.weather.refresh(settings: store.settings, force: true)
        }
        .onChange(of: store.settings.calendarEvents) { _, on in
            if on { launcher.hub.calendar.requestAccess() }
        }
        .onChange(of: launchAtLogin) { _, on in setLaunchAtLogin(on) }
        .alert("Reset the Start layout?", isPresented: $confirmReset) {
            Button("Reset", role: .destructive) { store.resetLayout() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("All tiles and groups will be replaced with the default layout. Your settings are kept.")
        }
    }

    // MARK: - Wallpaper

    @ViewBuilder
    private func colorRows(label: String) -> some View {
        LabeledContent(label) {
            HStack(spacing: 6) {
                ForEach(Palette.backgrounds, id: \.self) { hex in
                    Circle()
                        .fill(Color(hex: hex))
                        .frame(width: 20, height: 20)
                        .overlay(Circle().strokeBorder(Color.primary, lineWidth: store.settings.background == hex ? 2 : 0))
                        .onTapGesture { store.settings.background = hex }
                        .help(hex)
                }
            }
        }
        LabeledContent("Any color") {
            HStack(spacing: 10) {
                // Opens the macOS color wheel; the Start screen changes live as you drag.
                ColorPicker("Background color", selection: backgroundColor, supportsOpacity: false)
                    .labelsHidden()
                    .help("Pick any color or shade")
                TextField("", text: $hexDraft, prompt: Text("#25115A"))
                    .font(.system(.body, design: .monospaced))
                    .frame(width: 90)
                    .onSubmit(applyHex)
                if !hexError.isEmpty {
                    Text(hexError).font(.caption).foregroundStyle(.secondary)
                }
            }
        }
    }

    @ViewBuilder
    private var mediaRows: some View {
        let stored = store.settings.wallpaperFile
        let missing = Wallpapers.url(for: stored).map { !FileManager.default.fileExists(atPath: $0.path) } ?? false
        LabeledContent("File") {
            HStack {
                Text(Wallpapers.displayName(stored) ?? "None")
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .foregroundStyle(.secondary)
                if importingWallpaper { ProgressView().controlSize(.small) }
                Button("Choose…", action: chooseWallpaper)
                    .disabled(importingWallpaper)
            }
        }
        if missing {
            Text("This file can't be found any more. Choose another one.")
                .font(.caption).foregroundStyle(.red)
        }
        if !wallpaperError.isEmpty {
            Text(wallpaperError).font(.caption).foregroundStyle(.red)
        }
        dimRow
        Text("Pictures, animated GIFs and videos (MP4, MOV, M4V). Videos loop without sound. MacTiles keeps its own copy, so you can move or delete the original.")
            .font(.caption).foregroundStyle(.secondary)
    }

    private var dimRow: some View {
        LabeledContent("Dim") {
            Slider(value: $store.settings.wallpaperDim, in: 0...0.7).frame(width: 220)
        }
    }

    /// Small previews of each live wallpaper in the current tint; the selected one animates.
    private var livePreviews: some View {
        HStack(spacing: 10) {
            ForEach(LiveWallpaper.allCases) { style in
                let selected = store.settings.liveWallpaper == style
                VStack(spacing: 4) {
                    ZStack {
                        Color(hex: store.settings.background)
                        LiveWallpaperView(style: style, tint: store.settings.background, animating: selected, frameRate: 20)
                    }
                    .frame(width: 76, height: 48)
                    .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .strokeBorder(selected ? Color.accentColor : Color.primary.opacity(0.15), lineWidth: selected ? 2.5 : 1))
                    Text(style.title).font(.caption)
                }
                .contentShape(Rectangle())
                .onTapGesture { store.settings.liveWallpaper = style }
            }
        }
    }

    private func chooseWallpaper() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = Wallpapers.contentTypes
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.message = "Choose a picture, animated GIF or video for the Start screen"
        panel.directoryURL = FileManager.default.urls(for: .picturesDirectory, in: .userDomainMask).first
        guard panel.runModal() == .OK, let url = panel.url else { return }
        guard Wallpapers.kind(of: url) != nil else {
            wallpaperError = "MacTiles can't use this kind of file. Choose a picture or a video."
            return
        }
        wallpaperError = ""
        importingWallpaper = true
        let old = store.settings.wallpaperFile
        Task { @MainActor in
            // Copying a large video can take a moment; keep Settings responsive.
            let result = await Task.detached(priority: .userInitiated) {
                Result { try Wallpapers.importFile(url, replacing: old) }
            }.value
            importingWallpaper = false
            switch result {
            case .success(let name):
                store.settings.wallpaperFile = name
                store.settings.backgroundStyle = .media
            case .failure(let error):
                wallpaperError = "Couldn't copy the file: \(error.localizedDescription)"
            }
        }
    }

    private func findCity() {
        let q = cityQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else { return }
        cityStatus = "Searching…"
        Task { @MainActor in
            do {
                guard let place = try await WeatherAPI.geocode(q) else {
                    cityStatus = "No place called “\(q)” was found."
                    return
                }
                store.settings.weatherCity = place.name
                store.settings.weatherLat = place.latitude
                store.settings.weatherLon = place.longitude
                cityQuery = place.name
                cityStatus = "Using \(place.label)"
                launcher.hub.weather.refresh(settings: store.settings, force: true)
            } catch {
                cityStatus = "Couldn't reach the weather service. Check your connection."
            }
        }
    }

    private func choosePhotosFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.directoryURL = URL(fileURLWithPath: store.settings.photosFolder)
        if panel.runModal() == .OK, let url = panel.url {
            store.settings.photosFolder = url.path
            launcher.hub.liveSettingsChanged(active: launcher.tilesLive)
        }
    }

    private func setLaunchAtLogin(_ on: Bool) {
        do {
            if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
            loginError = ""
        } catch {
            loginError = "macOS didn't allow this (\(error.localizedDescription)). Move MacTiles to /Applications and try again."
        }
    }
}
