import AppKit
import ServiceManagement

/// First-run installation: offer to move MacTiles into /Applications (so it can start at
/// login and survive the DMG being ejected), then register it as a login item.
@MainActor
enum Installer {
    static let destination = URL(fileURLWithPath: "/Applications/MacTiles.app")

    static var isInApplications: Bool {
        Bundle.main.bundlePath.hasPrefix("/Applications/")
    }

    /// Returns true if MacTiles is relaunching from /Applications and this copy should quit.
    static func offerMoveIfNeeded() -> Bool {
        let path = Bundle.main.bundlePath
        let defaults = UserDefaults.standard
        guard !isInApplications,
              !path.contains("/MacTiles-build/"),        // running a local dev build
              !path.contains("/build/"),
              !defaults.bool(forKey: "skipMoveToApplications") else { return false }

        NSApp.activate()
        let alert = NSAlert()
        alert.messageText = "Move \(Edition.name) to your Applications folder?"
        alert.informativeText = "\(Edition.name) needs to be in Applications to start automatically when you log in and keep your Start screen running."
        alert.addButton(withTitle: "Move to Applications")
        alert.addButton(withTitle: "Not Now")
        alert.showsSuppressionButton = true
        alert.suppressionButton?.title = "Don't ask again"
        let response = alert.runModal()
        if alert.suppressionButton?.state == .on { defaults.set(true, forKey: "skipMoveToApplications") }
        guard response == .alertFirstButtonReturn else { return false }

        do {
            let fm = FileManager.default
            if fm.fileExists(atPath: destination.path) {
                try fm.trashItem(at: destination, resultingItemURL: nil)
            }
            try fm.copyItem(at: Bundle.main.bundleURL, to: destination)
        } catch {
            let failure = NSAlert(error: error)
            failure.messageText = "\(Edition.name) couldn't be moved"
            failure.informativeText = "Drag \(Edition.name) into your Applications folder in Finder instead. (\(error.localizedDescription))"
            failure.runModal()
            return false
        }

        // Start the installed copy once this one has quit, so the two don't fight over the hot key.
        let relaunch = Process()
        relaunch.executableURL = URL(fileURLWithPath: "/bin/sh")
        relaunch.arguments = ["-c", "sleep 1; /usr/bin/open \"$0\"", destination.path]
        try? relaunch.run()
        NSApp.terminate(nil)
        return true
    }

    /// On the first launch from /Applications, start MacTiles at login, like Windows' Start.
    static func registerLoginItemOnFirstRun() {
        let key = "loginItemConfigured"
        guard isInApplications, !UserDefaults.standard.bool(forKey: key) else { return }
        UserDefaults.standard.set(true, forKey: key)
        if SMAppService.mainApp.status != .enabled {
            do { try SMAppService.mainApp.register() } catch {
                NSLog("MacTiles: couldn't add login item: \(error.localizedDescription)")
            }
        }
    }

    // MARK: - Uninstall

    /// Settings → Uninstall MacTiles…: removes the login item, optionally the user's layout
    /// and settings, moves the app to the Trash and quits.
    static func confirmAndUninstall() {
        NSApp.activate()
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "Uninstall \(Edition.name)?"
        alert.informativeText = "\(Edition.name) will stop opening at login, move itself to the Trash and quit."
        alert.addButton(withTitle: "Uninstall")
        alert.addButton(withTitle: "Cancel")
        alert.buttons.first?.hasDestructiveAction = true
        alert.showsSuppressionButton = true
        alert.suppressionButton?.title = "Also delete my tiles, settings and saved service keys"
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        uninstall(deleteData: alert.suppressionButton?.state == .on)
    }

    static func uninstall(deleteData: Bool) {
        try? SMAppService.mainApp.unregister()

        if deleteData {
            IntegrationSecrets.removeAll()      // service passwords, tokens and API keys
            try? FileManager.default.removeItem(at: LayoutStore.directory)
            if let id = Bundle.main.bundleIdentifier {
                UserDefaults.standard.removePersistentDomain(forName: id)
            }
        }

        let bundle = Bundle.main.bundleURL
        NSWorkspace.shared.recycle([bundle]) { _, error in
            DispatchQueue.main.async {
                if error != nil {
                    // Installed by the package as root: let Finder (which can ask for a password) do it.
                    let note = NSAlert()
                    note.messageText = "Drag \(Edition.name) to the Trash to finish"
                    note.informativeText = "\(Edition.name) has been removed from your login items. macOS needs your permission to delete the app, so it will be shown in Finder — drag it to the Trash."
                    note.runModal()
                    NSWorkspace.shared.activateFileViewerSelecting([bundle])
                }
                NSApp.terminate(nil)
            }
        }
    }
}
