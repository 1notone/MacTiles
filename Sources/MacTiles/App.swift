import AppKit
import SwiftUI

@main
@MainActor
enum MacTilesApp {
    static func main() {
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        withExtendedLifetime(delegate) { app.run() }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var launcher: Launcher?
    private var statusItem: NSStatusItem?
    private var termSignal: DispatchSourceSignal?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        if Installer.offerMoveIfNeeded() { return }   // relaunching from /Applications

        let launcher = Launcher()
        self.launcher = launcher
        buildMainMenu()
        buildStatusItem()
        launcher.start()
        Installer.registerLoginItemOnFirstRun()
        saveOnTerminateSignal()

        // Windows 8 greets you with Start; so does MacTiles, at login and when opened by hand.
        launcher.show()
    }

    /// Clicking the Dock icon (the "Start button") or opening MacTiles again shows Start.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        launcher?.show()
        return false
    }

    /// Layout changes are saved a moment after they happen; don't lose the last one on quit.
    func applicationWillTerminate(_ notification: Notification) {
        launcher?.store.saveNow()
    }

    /// The installer and `make install` stop MacTiles with SIGTERM, which skips
    /// applicationWillTerminate; save first, then quit.
    private func saveOnTerminateSignal() {
        signal(SIGTERM, SIG_IGN)
        let source = DispatchSource.makeSignalSource(signal: SIGTERM, queue: .main)
        source.setEventHandler { [weak self] in
            MainActor.assumeIsolated {
                self?.launcher?.store.saveNow()
                exit(0)
            }
        }
        source.resume()
        termSignal = source
    }

    /// Start is the shell: closing windows never quits it.
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    func applicationDockMenu(_ sender: NSApplication) -> NSMenu? {
        let menu = NSMenu()
        menu.addItem(item("Show Start", #selector(showStart)))
        menu.addItem(item("Show Desktop", #selector(showDesktop)))
        return menu
    }

    // MARK: Menus

    /// The app menu, plus an Edit menu so ⌘C/⌘V/⌘A work in text fields.
    private func buildMainMenu() {
        let main = NSMenu()

        let appItem = NSMenuItem()
        let appMenu = NSMenu()
        appMenu.addItem(item("Settings…", #selector(openSettings), key: ","))
        appMenu.addItem(.separator())
        appMenu.addItem(item("Show Start", #selector(showStart)))
        appMenu.addItem(item("Show Desktop", #selector(showDesktop)))
        appMenu.addItem(.separator())
        appMenu.addItem(NSMenuItem(title: "Quit MacTiles", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
        appItem.submenu = appMenu
        main.addItem(appItem)

        let editItem = NSMenuItem()
        let edit = NSMenu(title: "Edit")
        edit.addItem(NSMenuItem(title: "Undo", action: Selector(("undo:")), keyEquivalent: "z"))
        edit.addItem(NSMenuItem(title: "Redo", action: Selector(("redo:")), keyEquivalent: "Z"))
        edit.addItem(.separator())
        edit.addItem(NSMenuItem(title: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x"))
        edit.addItem(NSMenuItem(title: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c"))
        edit.addItem(NSMenuItem(title: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v"))
        edit.addItem(NSMenuItem(title: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a"))
        editItem.submenu = edit
        main.addItem(editItem)

        NSApp.mainMenu = main
    }

    private func buildStatusItem() {
        let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        statusItem.button?.image = NSImage(systemSymbolName: "square.grid.2x2.fill", accessibilityDescription: "MacTiles")

        let menu = NSMenu()
        menu.addItem(item("Show Start", #selector(showStart)))
        menu.addItem(item("Show Desktop", #selector(showDesktop)))

        let liveItem = NSMenuItem(title: "Add Live Tile", action: nil, keyEquivalent: "")
        let liveMenu = NSMenu()
        for kind in TileKind.liveKinds {
            let i = item(kind.title, #selector(addLiveTile(_:)))
            i.representedObject = kind.rawValue
            i.image = NSImage(systemSymbolName: kind.symbol, accessibilityDescription: nil)
            liveMenu.addItem(i)
        }
        liveItem.submenu = liveMenu
        menu.addItem(liveItem)
        let web = item("Add Web Tile…", #selector(addWebTile))
        web.image = NSImage(systemSymbolName: "globe", accessibilityDescription: nil)
        menu.addItem(web)
        let service = item("Add Service Tile…", #selector(addServiceTile))
        service.image = NSImage(systemSymbolName: "server.rack", accessibilityDescription: nil)
        menu.addItem(service)

        menu.addItem(.separator())
        menu.addItem(item("Settings…", #selector(openSettings), key: ","))
        menu.addItem(.separator())
        menu.addItem(item("Quit MacTiles", #selector(quit), key: "q"))
        statusItem.menu = menu
        self.statusItem = statusItem
    }

    private func item(_ title: String, _ action: Selector, key: String = "") -> NSMenuItem {
        let i = NSMenuItem(title: title, action: action, keyEquivalent: key)
        i.target = self
        return i
    }

    @objc private func showStart() { launcher?.show() }
    @objc private func showDesktop() { launcher?.showDesktop() }
    @objc private func openSettings() { launcher?.openSettings() }
    @objc private func quit() { NSApp.terminate(nil) }
    @objc private func addWebTile() { launcher?.addWebTile() }
    @objc private func addServiceTile() { launcher?.addServiceTile() }

    @objc private func addLiveTile(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String, let kind = TileKind(rawValue: raw) else { return }
        launcher?.addLiveTile(kind)
        launcher?.show()
    }
}
