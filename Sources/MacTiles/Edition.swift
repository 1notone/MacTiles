import Foundation

/// Which build this is. The same code builds two editions:
///
/// - **MacTiles** — the free GitHub release, with every feature.
/// - **meTiles** — the Mac App Store edition (`swift build -Xswiftc -DAPPSTORE`, see
///   `make appstore`). It runs in Apple's App Sandbox, so a few things work differently:
///   no "Move to Applications" or "Uninstall", start-at-login is off until you turn it on,
///   Docker is reached over the network only, and folders outside Pictures are granted by
///   choosing them once.
enum Edition {
    #if APPSTORE
    static let isAppStore = true
    #else
    static let isAppStore = false
    #endif

    /// The app's name as people see it: "MacTiles", or "meTiles" in the App Store edition.
    static let name: String = {
        let info = Bundle.main.infoDictionary
        if let display = info?["CFBundleDisplayName"] as? String, !display.isEmpty { return display }
        return isAppStore ? "meTiles" : "MacTiles"
    }()

    /// Running inside the App Sandbox (always true for the App Store edition).
    static var isSandboxed: Bool { ProcessInfo.processInfo.environment["APP_SANDBOX_CONTAINER_ID"] != nil }
}
