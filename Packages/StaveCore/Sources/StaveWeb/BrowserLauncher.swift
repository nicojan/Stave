import AppKit
import os

/// Finds the other browsers and opens an address in one (plan 5, decision 25). A seam so tests never open another app.
struct BrowserLauncher {
    private static let log = Logger(subsystem: "com.nicojan.Stave", category: "open-elsewhere")

    /// Whether an app with this bundle ID is installed.
    var isInstalled: (String) -> Bool
    /// Opens the address in the app with this bundle ID. Called with a web address only.
    var open: (URL, String) -> Void

    static var system: BrowserLauncher {
        BrowserLauncher(
            isInstalled: { NSWorkspace.shared.urlForApplication(withBundleIdentifier: $0) != nil },
            open: { url, bundleID in
                guard let app = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) else {
                    log.error("Open in \(bundleID, privacy: .public): the app is not installed")
                    return
                }
                // A failure is logged without the address (it is the user's browsing).
                NSWorkspace.shared.open([url], withApplicationAt: app, configuration: NSWorkspace.OpenConfiguration()) { _, error in
                    if let error { log.error("Open in \(bundleID, privacy: .public) failed: \(error.localizedDescription, privacy: .public)") }
                }
            }
        )
    }
}
