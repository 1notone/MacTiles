import AppKit
import SwiftUI

/// Keeps track of which apps are running, so their tiles can show a small dot — like the Dock.
/// Updated from launch/quit notifications; costs nothing in between.
@MainActor
final class RunningApps: ObservableObject {
    @Published private(set) var bundleIDs: Set<String> = []
    @Published private(set) var paths: Set<String> = []
    private var bundleIDCache: [String: String] = [:]
    private var observers: [Any] = []

    init(observe: Bool = true) {
        guard observe else { return }
        refresh()
        let nc = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.didLaunchApplicationNotification, NSWorkspace.didTerminateApplicationNotification] {
            observers.append(nc.addObserver(forName: name, object: nil, queue: .main) { [weak self] note in
                let quit = note.name == NSWorkspace.didTerminateApplicationNotification
                    ? note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication : nil
                let quitID = quit?.bundleIdentifier
                let quitPath = quit?.bundleURL.map(Self.normalize)
                MainActor.assumeIsolated { self?.refresh(excludingID: quitID, path: quitPath) }
            })
        }
    }

    /// Re-reads the running apps. A quitting app can still be listed for a moment, so it's excluded explicitly.
    func refresh(excludingID quitID: String? = nil, path quitPath: String? = nil) {
        let me = ProcessInfo.processInfo.processIdentifier
        let apps = NSWorkspace.shared.runningApplications.filter {
            $0.activationPolicy == .regular && !$0.isTerminated && $0.processIdentifier != me
        }
        var ids = Set(apps.compactMap(\.bundleIdentifier))
        var urls = Set(apps.compactMap { $0.bundleURL.map(Self.normalize) })
        if let quitID, !apps.contains(where: { $0.bundleIdentifier == quitID && $0.processIdentifier != me }) { ids.remove(quitID) }
        if let quitPath { urls.remove(quitPath) }
        if ids != bundleIDs { bundleIDs = ids }
        if urls != paths { paths = urls }
    }

    /// Whether the app at this path (a tile's app) is running.
    func isRunning(path: String) -> Bool {
        if paths.contains(Self.normalize(URL(fileURLWithPath: path))) { return true }
        guard let id = bundleID(for: path) else { return false }
        return bundleIDs.contains(id)
    }

    /// The running instances of the app at this path.
    func instances(of path: String) -> [NSRunningApplication] {
        let target = Self.normalize(URL(fileURLWithPath: path))
        let id = bundleID(for: path)
        let me = ProcessInfo.processInfo.processIdentifier
        return NSWorkspace.shared.runningApplications.filter { app in
            guard !app.isTerminated, app.processIdentifier != me, app.activationPolicy == .regular else { return false }
            if let url = app.bundleURL, Self.normalize(url) == target { return true }
            return id != nil && app.bundleIdentifier == id
        }
    }

    /// Asks the app to quit, as if you chose Quit in its menu (it can still ask to save documents).
    func quit(path: String) {
        for app in instances(of: path) { app.terminate() }
    }

    /// Ends the app immediately — for apps that aren't responding. Unsaved changes are lost.
    func forceQuit(path: String) {
        for app in instances(of: path) { app.forceTerminate() }
        // Force-quit apps can vanish before the notification arrives; check again shortly.
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 500_000_000)
            self.refresh()
        }
    }

    private func bundleID(for path: String) -> String? {
        if let cached = bundleIDCache[path] { return cached.isEmpty ? nil : cached }
        let id = Bundle(path: path)?.bundleIdentifier ?? ""
        bundleIDCache[path] = id
        return id.isEmpty ? nil : id
    }

    nonisolated static func normalize(_ url: URL) -> String {
        url.resolvingSymlinksInPath().standardizedFileURL.path.lowercased()
    }

    /// For tests.
    func set(bundleIDs ids: Set<String>, paths: Set<String>) {
        bundleIDs = ids
        self.paths = Set(paths.map { Self.normalize(URL(fileURLWithPath: $0)) })
    }
}

/// The "this app is running" mark: a small glowing dot.
struct RunningDot: View {
    var size: CGFloat = 6

    var body: some View {
        Circle()
            .fill(Color.white)
            .frame(width: size, height: size)
            .shadow(color: .white.opacity(0.7), radius: size * 0.6)
            .shadow(color: .black.opacity(0.35), radius: 1, y: 0.5)
            .accessibilityLabel("Running")
            .allowsHitTesting(false)
    }
}

/// "Quit Safari" and "Force Quit Safari" for a running app's right-click menu.
@MainActor
struct QuitMenuItems: View {
    let path: String
    let name: String
    @EnvironmentObject private var running: RunningApps

    var body: some View {
        // Sandboxed apps (the App Store edition) aren't allowed to quit other apps.
        if !Edition.isAppStore {
            Button("Quit \(name)") { running.quit(path: path) }
            Button("Force Quit \(name)…") { confirmForceQuit() }
        }
    }

    private func confirmForceQuit() {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "Force quit \(name)?"
        alert.informativeText = "Any unsaved changes in \(name) will be lost. Use this only if the app isn't responding."
        alert.addButton(withTitle: "Force Quit")
        alert.addButton(withTitle: "Cancel")
        alert.buttons.first?.hasDestructiveAction = true
        // MacTiles' window sits above everything while Start is open; keep the alert in front of it.
        alert.window.level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.mainMenuWindow)) + 2)
        if alert.runModal() == .alertFirstButtonReturn { running.forceQuit(path: path) }
    }
}
