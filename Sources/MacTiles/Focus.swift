import AppKit

/// Hands keyboard focus to the app MacTiles opens.
///
/// Since macOS 14, activation is cooperative: an app only comes to the front if the
/// active app (MacTiles, after you click a tile or press Return) explicitly yields to it.
/// Without this, the launched app's window appears but keystrokes still go to MacTiles.
@MainActor
enum Focus {
    /// Call before opening: lets the app take focus when it launches or comes forward.
    static func yield(toAppAt appURL: URL) {
        if let id = Bundle(url: appURL)?.bundleIdentifier {
            NSApp.yieldActivation(toApplicationWithBundleIdentifier: id)
        }
    }

    /// Activates `app`, retrying briefly while a cold-launched app finishes starting.
    /// Stops as soon as the app is frontmost, or if you've switched to something else meanwhile.
    static func bringForward(_ app: NSRunningApplication) {
        Task { @MainActor in
            for attempt in 0..<12 {
                if app.isTerminated || app.isActive { return }
                let front = NSWorkspace.shared.frontmostApplication
                let stillOurs = front == nil || front?.processIdentifier == ProcessInfo.processInfo.processIdentifier
                if attempt > 0 && !stillOurs { return }       // the person moved on; don't steal focus

                NSApp.yieldActivation(to: app)
                if !app.activate(from: NSRunningApplication.current, options: [.activateAllWindows]) {
                    app.activate(options: [.activateAllWindows])
                }
                try? await Task.sleep(nanoseconds: 150_000_000)
            }
        }
    }
}
