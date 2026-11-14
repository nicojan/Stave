public enum PageFailure: Sendable, Equatable {
    case refused(url: String)
    /// A stored or restored `file:` tab: refused like any address Stave won't open, with "Open Again" (decision 6).
    case fileNotReopened(url: String)
    case noAppForLink(url: String)
    case loadFailed(host: String, message: String)
    case insecure(host: String)
    case crashed
}

/// Every string shown in the page area.
public enum PageText {
    public static func title(_ f: PageFailure) -> String {
        switch f {
        case .refused, .fileNotReopened: "Stave won't open this address"
        case .noAppForLink: "No app can open this link"
        case .loadFailed: "Stave couldn't open this page"
        case .insecure: "This connection isn't private"
        case .crashed: "This page stopped working"
        }
    }

    public static func detail(_ f: PageFailure) -> String {
        switch f {
        case .refused(let url): "Stave only opens web addresses. It won't open \(url)."
        case .fileNotReopened(let url): "Stave doesn't open files again by itself. Choose Open Again to open \(url)."
        case .noAppForLink(let url): "Nothing on this Mac is set up to open \(url)."
        case .loadFailed(_, let message): message
        case .insecure(let host): "Stave can't confirm that \(host) is the site it says it is, so it didn't open it."
        case .crashed: "Reload the tab to try again."
        }
    }

    public static let newTabHint = "Press ⌘L to enter an address or search."

    public static func externalAppQuestion(appName: String) -> String { "Open this link in \(appName)?" }

    public static func mediaQuestion(host: String, camera: Bool, microphone: Bool) -> String {
        let what = switch (camera, microphone) {
        case (true, true): "camera and microphone"
        case (true, false): "camera"
        default: "microphone"
        }
        return "Allow \(host) to use your \(what)?"
    }

    public static let elsewhereTitle = "This tab is open in another window"
    public static let bringHereButton = "Bring It Here"
    public static let reloadButton = "Reload"
    public static let openAgainButton = "Open Again"

    /// The panel offers "Open Again" (in place of Reload) only for a stored or restored file tab.
    public static func offersOpenAgain(_ f: PageFailure) -> Bool {
        if case .fileNotReopened = f { true } else { false }
    }
    /// The panel offers Reload except in place of Open Again, and for a refused address in a tab with nothing loaded (`hasDocument` false:
    /// a refused link from another app, a refused typed address in a blank tab), where Reload could only refuse it again.
    public static func offersReload(_ f: PageFailure, hasDocument: Bool) -> Bool {
        switch f {
        case .fileNotReopened: false
        case .refused: hasDocument
        case .noAppForLink, .loadFailed, .insecure, .crashed: true
        }
    }
    public static let backButton = "Back"
    public static let okButton = "OK"
    public static let cancelButton = "Cancel"
    public static let openButton = "Open"
    /// Added to a page's link menu, before WebKit's "Open Link in New Window".
    public static let openLinkInNewTab = "Open Link in New Tab"
    /// The heading of a blank tab's content area.
    public static let newTabTitle = "New Tab"
}
