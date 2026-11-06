import AppKit
import SwiftUI

final class LauncherWindow: NSWindow {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
}

/// Lets one click on a tile launch the app even while Start is on the desktop and
/// MacTiles isn't the active app (otherwise macOS spends that click activating MacTiles).
final class FirstMouseHostingView<Content: View>: NSHostingView<Content> {
    /// AppKit fallback for the right-click menu, used only where SwiftUI offers none.
    var fallbackMenu: (() -> NSMenu)?

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func menu(for event: NSEvent) -> NSMenu? {
        super.menu(for: event) ?? fallbackMenu?()
    }
}

/// An NSMenuItem that runs a closure.
final class ActionMenuItem: NSMenuItem {
    private let handler: () -> Void

    init(_ title: String, _ handler: @escaping () -> Void) {
        self.handler = handler
        super.init(title: title, action: #selector(run), keyEquivalent: "")
        target = self
    }

    required init(coder: NSCoder) { fatalError("not used") }

    @objc private func run() { handler() }
}

/// Coordinates the Start window. Like Windows 8, Start is always there:
///
/// - **Front**: Start covers the screen (⌥ Space, Dock icon, hot corner, menu-bar icon).
/// - **Background**: after you launch an app or press Esc, Start drops behind every
///   window and stays on the desktop, so it's what you see whenever you close or
///   minimize your apps. Its tiles are still clickable there.
/// - **Desktop**: the Desktop tile hides Start entirely to reveal Finder's desktop,
///   until you open Start again.
///
/// "Keep Start on the desktop" can be turned off in Settings for the classic
/// overlay-only behavior.
@MainActor
final class Launcher: ObservableObject {
    let store: LayoutStore
    let catalog: AppCatalog
    let hub: LiveHub
    let services: ServiceHub
    let webIcons = WebIconCache()
    let running = RunningApps()

    /// Start is the frontmost, focused overlay.
    @Published private(set) var isFront = false
    /// Live tiles should animate and poll: Start is on screen and not covered by other windows.
    @Published private(set) var tilesLive = false
    /// Space taken by the menu bar and Dock, so content isn't hidden behind them in background mode.
    @Published private(set) var chromeInsets = EdgeInsets()
    @Published var query = ""
    @Published var showingApps = false
    /// The add/edit web tile panel, when it's open.
    @Published var webDraft: WebTileDraft?
    @Published var newsDraft: NewsTileDraft?
    /// The add/edit service tile panel, when it's open.
    @Published var serviceDraft: ServiceTileDraft?
    /// Asks Settings to open the Integrations editor (adding, or editing one service).
    @Published var integrationRequest: IntegrationRequest?
    @Published private(set) var appearToken = 0

    private var window: LauncherWindow?
    private var isOnScreen = false
    private var settingsWindow: NSWindow?
    private var previousApp: NSRunningApplication?
    private var hotKey: HotKey?
    private var monitors: [Any] = []
    private var cornerMonitor: Any?
    /// While Start is in front, MacTiles is the active app and global monitors go quiet; this one covers that.
    private var localCornerMonitor: Any?
    private var cornerArmed = true
    private var lastScan = Date.distantPast

    private var persistent: Bool { store.settings.keepOnDesktop }

    private static let frontLevel = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.mainMenuWindow)) + 1)
    private static let desktopLevel = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.desktopIconWindow)) + 1)

    init() {
        let store = LayoutStore()
        self.store = store
        self.catalog = AppCatalog()
        self.hub = LiveHub(store: store)
        self.services = ServiceHub(store: store)
    }

    func start() {
        catalog.startWatching()
        lastScan = Date()
        applyHotKey()
        applyHotCorner()
        applyDockIcon()
        installObservers()
        hub.refreshStale()
        if persistent { placeInBackground() }
    }

    // MARK: - Showing Start

    func toggle() {
        if isFront { dismiss(restoreFocus: true) } else { show() }
    }

    /// Brings Start to the front, full screen, with the tile cascade.
    func show() {
        let w = window ?? makeWindow()
        window = w
        if isFront {
            w.makeKeyAndOrderFront(nil)
            return
        }
        rememberFrontApp()

        let screen = persistent ? primaryScreen : screenUnderPointer
        if w.frame != screen.frame { w.setFrame(screen.frame, display: false) }
        updateInsets(for: screen)

        query = ""
        showingApps = false
        if Date().timeIntervalSince(lastScan) > 5 * 60 {
            catalog.refresh()
            lastScan = Date()
        }
        hub.refreshStale()      // weather and news, if they're due

        let wasOnScreen = isOnScreen && w.isVisible
        isFront = true
        isOnScreen = true
        appearToken &+= 1
        w.level = Self.frontLevel

        NSApp.activate()
        if wasOnScreen {
            w.alphaValue = 1
            w.makeKeyAndOrderFront(nil)
        } else {
            w.alphaValue = 0
            w.makeKeyAndOrderFront(nil)
            NSAnimationContext.runAnimationGroup { ctx in
                MainActor.assumeIsolated {
                    ctx.duration = 0.18
                    w.animator().alphaValue = 1
                }
            }
        }
        updateLiveState()
    }

    /// Leaves the front. In persistent mode Start drops behind your windows; otherwise it hides.
    func dismiss(restoreFocus: Bool) {
        guard isFront, let w = window else { return }
        isFront = false
        query = ""
        showingApps = false
        webDraft = nil
        newsDraft = nil
        serviceDraft = nil
        store.draggingID = nil
        store.draggingGroupID = nil

        if persistent {
            w.level = Self.desktopLevel
            let screen = primaryScreen
            if w.frame != screen.frame { w.setFrame(screen.frame, display: true) }
            updateInsets(for: screen)
            if restoreFocus { reactivatePreviousApp() }
            updateLiveState()
        } else {
            isOnScreen = false
            updateLiveState()
            NSAnimationContext.runAnimationGroup({ ctx in
                MainActor.assumeIsolated {
                    ctx.duration = 0.12
                    w.animator().alphaValue = 0
                }
            }, completionHandler: { [weak self] in
                MainActor.assumeIsolated {
                    guard let self, !self.isFront else { return }
                    w.orderOut(nil)
                    if restoreFocus { self.reactivatePreviousApp() }
                }
            })
        }
    }

    /// The Desktop tile: hide Start completely to reveal Finder's desktop.
    func showDesktop() {
        guard let w = window else { return }
        isFront = false
        isOnScreen = false
        query = ""
        showingApps = false
        webDraft = nil
        newsDraft = nil
        serviceDraft = nil
        w.orderOut(nil)
        updateLiveState()
        reactivatePreviousApp()
    }

    /// Puts Start on the desktop behind all windows, without taking focus.
    private func placeInBackground() {
        let w = window ?? makeWindow()
        window = w
        let screen = primaryScreen
        w.setFrame(screen.frame, display: false)
        updateInsets(for: screen)
        w.level = Self.desktopLevel
        w.alphaValue = 1
        w.orderFrontRegardless()
        isFront = false
        isOnScreen = true
        appearToken &+= 1
        updateLiveState()
    }

    /// Called when "Keep Start on the desktop" changes.
    func applyPersistence() {
        guard !isFront else { return }
        if persistent {
            placeInBackground()
        } else if let w = window, isOnScreen {
            w.orderOut(nil)
            isOnScreen = false
            updateLiveState()
        }
    }

    func applyDockIcon() {
        NSApp.setActivationPolicy(store.settings.showInDock ? .regular : .accessory)
    }

    // MARK: - Actions

    var results: [AppInfo] { AppSearch.rank(query, in: catalog.apps) }

    func launchFirstResult() {
        if let first = results.first { launch(path: first.path) }
    }

    func launch(path: String) {
        // An app that was deleted or moved: say so with the system beep, and leave Start open.
        guard FileManager.default.fileExists(atPath: path) else {
            NSSound.beep()
            return
        }
        let url = URL(fileURLWithPath: path)
        Focus.yield(toAppAt: url)
        dismiss(restoreFocus: false)      // Start stays on the desktop, behind the app
        let config = NSWorkspace.OpenConfiguration()
        config.activates = true
        NSWorkspace.shared.openApplication(at: url, configuration: config) { app, _ in
            guard let app else { return }
            Task { @MainActor in Focus.bringForward(app) }
        }
    }

    func open(url: URL) {
        if let handler = NSWorkspace.shared.urlForApplication(toOpen: url) { Focus.yield(toAppAt: handler) }
        dismiss(restoreFocus: false)
        let config = NSWorkspace.OpenConfiguration()
        config.activates = true
        NSWorkspace.shared.open(url, configuration: config) { app, _ in
            guard let app else { return }
            Task { @MainActor in Focus.bringForward(app) }
        }
    }

    func reveal(path: String) {
        NSApp.yieldActivation(toApplicationWithBundleIdentifier: "com.apple.finder")
        dismiss(restoreFocus: false)
        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)])
        if let finder = NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.finder").first {
            Focus.bringForward(finder)
        }
    }

    /// Opens the "Add a web tile" panel, filled in from the clipboard if it holds a web address.
    func addWebTile(at destination: TileDestination? = nil) {
        if !isFront { show() }
        var address = ""
        if let copied = NSPasteboard.general.string(forType: .string)?.trimmingCharacters(in: .whitespacesAndNewlines),
           let url = WebLink.normalize(copied), WebLink.isFetchable(url), copied.contains(".") {
            address = copied
        }
        webDraft = WebTileDraft(tileID: nil, address: address, name: "", destination: destination)
    }

    func editWebTile(_ tile: Tile) {
        if !isFront { show() }
        webDraft = WebTileDraft(tileID: tile.id, address: tile.url ?? "", name: tile.title ?? "", destination: nil)
    }

    /// Opens the "Add a service tile" panel (Plex, Pi-hole, Home Assistant…).
    func addServiceTile(at destination: TileDestination? = nil) {
        if !isFront { show() }
        serviceDraft = ServiceTileDraft(tileID: nil, integrationID: nil, widget: nil, entity: "", name: "", destination: destination)
    }

    func editServiceTile(_ tile: Tile) {
        if !isFront { show() }
        serviceDraft = ServiceTileDraft(tileID: tile.id, integrationID: tile.integrationID, widget: tile.widget,
                                        entity: tile.entity ?? "", name: tile.title ?? "", destination: nil)
    }

    /// Clicking a service tile: Home Assistant switches toggle and scripts run; everything else
    /// opens the service's web page.
    func activateService(_ tile: Tile, openOnly: Bool = false) {
        guard let integration = services.integration(for: tile) else {
            editServiceTile(tile)
            return
        }
        if !openOnly, tile.widget == .entity, let entity = tile.entity {
            let domain = HomeAssistant.domain(entity)
            // Locks only change from the menu, never from a stray click.
            if domain != "lock", HomeAssistant.service(for: domain) != nil {
                services.perform(.toggleEntity(entity), on: tile)
                return
            }
        }
        if integration.kind == .docker, integration.url.trimmingCharacters(in: .whitespaces).isEmpty {
            let apps = ["/Applications/Docker.app", "/Applications/OrbStack.app", "/Applications/Rancher Desktop.app"]
            if let app = apps.first(where: { FileManager.default.fileExists(atPath: $0) }) { launch(path: app) }
            return
        }
        if let url = integration.webURL { open(url: url) }
    }

    /// Opens the News tile panel: choose a feed for a new tile, or change an existing tile's.
    func addNewsTile() {
        if !isFront { show() }
        newsDraft = NewsTileDraft(tileID: nil, feed: store.settings.newsFeed, name: "")
    }

    func editNewsTile(_ tile: Tile) {
        if !isFront { show() }
        newsDraft = NewsTileDraft(tileID: tile.id, feed: store.newsFeed(of: tile), name: tile.title ?? "")
    }

    func addLiveTile(_ kind: TileKind) {
        // Each News tile can show its own source, so ask which one.
        if kind == .news { return addNewsTile() }
        withAnimation(.spring(response: 0.35, dampingFraction: 0.85)) { store.addLive(kind) }
        hub.refreshStale()
        if tilesLive { hub.setActive(true) }
    }

    func openSettings(addingIntegration: Bool = false, editing integration: UUID? = nil) {
        if addingIntegration { integrationRequest = IntegrationRequest(target: nil) }
        if let integration { integrationRequest = IntegrationRequest(target: integration) }
        dismiss(restoreFocus: false)
        if settingsWindow == nil {
            let controller = NSHostingController(rootView: SettingsView().mactilesEnvironment(self))
            let w = NSWindow(contentViewController: controller)
            w.title = "MacTiles Settings"
            w.styleMask = [.titled, .closable, .miniaturizable]
            w.isReleasedWhenClosed = false
            w.center()
            settingsWindow = w
        }
        NSApp.activate()
        settingsWindow?.makeKeyAndOrderFront(nil)
    }

    /// Same items as the SwiftUI right-click menu (BackgroundMenu), for AppKit-level clicks.
    func backgroundMenu() -> NSMenu {
        let menu = NSMenu()
        menu.addItem(ActionMenuItem("MacTiles Settings…") { [weak self] in self?.openSettings() })
        menu.addItem(ActionMenuItem("Change Wallpaper…") { [weak self] in self?.openSettings() })
        menu.addItem(.separator())
        let live = NSMenuItem(title: "Add Live Tile", action: nil, keyEquivalent: "")
        let liveMenu = NSMenu()
        for kind in TileKind.liveKinds {
            let item = ActionMenuItem(kind.title) { [weak self] in self?.addLiveTile(kind) }
            item.image = NSImage(systemSymbolName: kind.symbol, accessibilityDescription: nil)
            liveMenu.addItem(item)
        }
        live.submenu = liveMenu
        menu.addItem(live)
        menu.addItem(ActionMenuItem("Add Web Tile…") { [weak self] in self?.addWebTile() })
        menu.addItem(ActionMenuItem("Add Service Tile…") { [weak self] in self?.addServiceTile() })
        menu.addItem(ActionMenuItem(showingApps ? "Back to Start" : "All Apps") { [weak self] in self?.showingApps.toggle() })
        menu.addItem(ActionMenuItem("Show Desktop") { [weak self] in self?.showDesktop() })
        return menu
    }

    // MARK: - Hot key & hot corner

    func applyHotKey() {
        hotKey?.unregister()
        hotKey = nil
        guard let preset = HotKeyPreset.find(store.settings.hotKey), preset.id != "none" else { return }
        hotKey = HotKey(keyCode: preset.keyCode, modifiers: preset.modifiers) { [weak self] in
            self?.toggle()
        }
        if hotKey == nil {
            // Another app (often an old copy that is still quitting) holds the shortcut; retry shortly.
            Task { @MainActor [weak self] in
                try? await Task.sleep(nanoseconds: 2_000_000_000)
                guard let self, self.hotKey == nil else { return }
                self.hotKey = HotKey(keyCode: preset.keyCode, modifiers: preset.modifiers) { [weak self] in
                    self?.toggle()
                }
            }
        }
    }

    func applyHotCorner() {
        if store.settings.hotCorner, cornerMonitor == nil {
            cornerMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.mouseMoved]) { [weak self] _ in
                MainActor.assumeIsolated { self?.checkHotCorner() }
            }
            localCornerMonitor = NSEvent.addLocalMonitorForEvents(matching: [.mouseMoved], handler: { [weak self] event in
                let input = Box(event)
                MainActor.assumeIsolated { self?.checkHotCorner() }
                return input.value
            })
        } else if !store.settings.hotCorner {
            if let monitor = cornerMonitor { NSEvent.removeMonitor(monitor) }
            if let monitor = localCornerMonitor { NSEvent.removeMonitor(monitor) }
            cornerMonitor = nil
            localCornerMonitor = nil
        }
    }

    private func checkHotCorner() {
        let p = NSEvent.mouseLocation
        let inCorner = NSScreen.screens.contains { screen in
            let f = screen.frame
            return p.x >= f.minX - 1 && p.x <= f.minX + 2 && p.y >= f.minY - 1 && p.y <= f.minY + 2
        }
        if inCorner && cornerArmed {
            // Fires once per visit: leave the corner before it can fire again.
            cornerArmed = false
            if !isFront {
                show()
            } else if store.settings.hotCornerToggles {
                showDesktop()       // a toggle: Start is open, so put it away and show the desktop
            }
        } else if !inCorner {
            cornerArmed = true
        }
    }

    // MARK: - Helpers

    private var primaryScreen: NSScreen { NSScreen.screens.first ?? NSScreen.main ?? NSScreen() }

    private var screenUnderPointer: NSScreen {
        let mouse = NSEvent.mouseLocation
        return NSScreen.screens.first(where: { NSMouseInRect(mouse, $0.frame, false) }) ?? primaryScreen
    }

    private func updateInsets(for screen: NSScreen) {
        let f = screen.frame, v = screen.visibleFrame
        let insets = EdgeInsets(top: f.maxY - v.maxY, leading: v.minX - f.minX,
                                bottom: v.minY - f.minY, trailing: f.maxX - v.maxX)
        if insets != chromeInsets { chromeInsets = insets }
    }

    private func rememberFrontApp() {
        if let app = NSWorkspace.shared.frontmostApplication,
           app.processIdentifier != ProcessInfo.processInfo.processIdentifier {
            previousApp = app
        }
    }

    private func reactivatePreviousApp() {
        if let app = previousApp, !app.isTerminated {
            NSApp.yieldActivation(to: app)
            Focus.bringForward(app)
        }
        previousApp = nil
    }

    /// Live tiles run only when Start can actually be seen.
    private func updateLiveState() {
        var live = false
        if let w = window, isOnScreen {
            live = isFront || w.occlusionState.contains(.visible)
        }
        if live != tilesLive {
            tilesLive = live
            hub.setActive(live)
            services.setActive(live)
        }
    }

    // MARK: - Window & event plumbing

    private func makeWindow() -> LauncherWindow {
        let frame = primaryScreen.frame
        let w = LauncherWindow(contentRect: frame, styleMask: [.borderless], backing: .buffered, defer: false)
        w.acceptsMouseMovedEvents = true     // so the hot corner works while Start is in front
        w.isOpaque = false
        w.backgroundColor = .clear
        w.hasShadow = false
        w.isReleasedWhenClosed = false
        w.level = Self.desktopLevel
        w.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle, .fullScreenAuxiliary]
        w.appearance = NSAppearance(named: .darkAqua)

        let host = FirstMouseHostingView(rootView: RootView().mactilesEnvironment(self))
        host.sizingOptions = []   // the window is sized to the screen, not to SwiftUI's ideal size
        host.fallbackMenu = { [weak self] in self?.backgroundMenu() ?? NSMenu() }
        w.contentView = host

        _ = NotificationCenter.default.addObserver(forName: NSWindow.didChangeOcclusionStateNotification,
                                                   object: w, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.updateLiveState() }
        }
        return w
    }

    private func installObservers() {
        // Local event monitors run on the main thread. NSEvent isn't Sendable, so it is
        // boxed to cross into MainActor.assumeIsolated (needed for Swift 6 strictness).
        if let m = NSEvent.addLocalMonitorForEvents(matching: .keyDown, handler: { [weak self] event in
            let input = Box(event)
            return MainActor.assumeIsolated { () -> Box<NSEvent?> in
                guard let self else { return Box(input.value) }
                return Box(self.handleKeyDown(input.value))
            }.value
        }) { monitors.append(m) }

        // A plain mouse wheel scrolls Start sideways, like Windows 8.
        if let m = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel, handler: { [weak self] event in
            let input = Box(event)
            return MainActor.assumeIsolated { () -> Box<NSEvent?> in
                let event = input.value
                guard let self, self.isOnScreen, event.windowNumber == self.window?.windowNumber else { return Box(event) }
                return Box(Launcher.horizontalized(event))
            }.value
        }) { monitors.append(m) }

        let center = NotificationCenter.default
        // Switching to another app sends Start back (or away, if not persistent).
        _ = center.addObserver(forName: NSApplication.didResignActiveNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.dismiss(restoreFocus: false)
                self?.query = ""
            }
        }
        // Displays added/removed/rearranged, or the Dock moved.
        _ = center.addObserver(forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.screensChanged() }
        }
        _ = NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.activeSpaceDidChangeNotification,
                                                              object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.dismiss(restoreFocus: false)
                self?.updateLiveState()
            }
        }
    }

    private func screensChanged() {
        guard let w = window, isOnScreen else { return }
        let screen = isFront ? (w.screen ?? primaryScreen) : primaryScreen
        w.setFrame(screen.frame, display: true)
        updateInsets(for: screen)
    }

    private func handleKeyDown(_ event: NSEvent) -> NSEvent? {
        guard let w = window, event.window === w else { return event }
        if event.modifierFlags.contains(.command), event.charactersIgnoringModifiers == "," {
            openSettings()
            return nil
        }
        // Renaming a group: that text field gets the keys.
        if w.firstResponder is NSText { return event }

        // A panel (web, news or service tile) is open: Escape closes it, other keys stay with it.
        if webDraft != nil || newsDraft != nil || serviceDraft != nil {
            guard event.keyCode == 53 else { return event }
            webDraft = nil
            newsDraft = nil
            serviceDraft = nil
            return nil
        }

        if event.keyCode == 53 {   // Escape
            if !query.isEmpty { query = "" }
            else if showingApps { showingApps = false }
            else if isFront { dismiss(restoreFocus: true) }
            else { return event }
            return nil
        }

        // Just start typing to search.
        let action = TypeToSearch.action(keyCode: event.keyCode, characters: event.characters,
                                         flags: event.modifierFlags, query: query)
        switch action {
        case .ignore:
            return event
        case .submit:
            launchFirstResult()
        default:
            query = TypeToSearch.apply(action, to: query)
        }
        return nil
    }

    static func horizontalized(_ event: NSEvent) -> NSEvent {
        guard !event.hasPreciseScrollingDeltas,          // leave trackpads alone
              event.scrollingDeltaX == 0, event.scrollingDeltaY != 0,
              let cg = event.cgEvent?.copy() else { return event }
        cg.setIntegerValueField(.scrollWheelEventDeltaAxis2, value: cg.getIntegerValueField(.scrollWheelEventDeltaAxis1))
        cg.setIntegerValueField(.scrollWheelEventDeltaAxis1, value: 0)
        cg.setIntegerValueField(.scrollWheelEventPointDeltaAxis2, value: cg.getIntegerValueField(.scrollWheelEventPointDeltaAxis1))
        cg.setIntegerValueField(.scrollWheelEventPointDeltaAxis1, value: 0)
        cg.setDoubleValueField(.scrollWheelEventFixedPtDeltaAxis2, value: cg.getDoubleValueField(.scrollWheelEventFixedPtDeltaAxis1))
        cg.setDoubleValueField(.scrollWheelEventFixedPtDeltaAxis1, value: 0)
        return NSEvent(cgEvent: cg) ?? event
    }
}

extension View {
    @MainActor
    func mactilesEnvironment(_ launcher: Launcher) -> some View {
        self
            .environmentObject(launcher)
            .environmentObject(launcher.store)
            .environmentObject(launcher.catalog)
            .environmentObject(launcher.hub)
            .environmentObject(launcher.hub.weather)
            .environmentObject(launcher.hub.system)
            .environmentObject(launcher.hub.battery)
            .environmentObject(launcher.hub.calendar)
            .environmentObject(launcher.hub.photos)
            .environmentObject(launcher.hub.desktop)
            .environmentObject(launcher.webIcons)
            .environmentObject(launcher.services)
            .environmentObject(launcher.running)
    }
}

/// "Open Settings at Integrations, with the editor showing" — `target` nil means a new service.
struct IntegrationRequest: Identifiable, Equatable {
    let id = UUID()
    let target: UUID?
}
