import Foundation

/// StaveCore's mirror of the web layer's page status; the app maps one onto the other.
public struct PageStatusSummary: Equatable, Sendable {
    public var isLoading: Bool
    public var canGoBack: Bool
    public var canGoForward: Bool
    public var hasPage: Bool
    /// Whether content blocking is on for the page's site; nil when it does not apply.
    public var blockingOn: Bool?
    /// The failure panel shows in place of the page.
    public var hasFailure: Bool
    /// A blank tab (`PageMenuState.isBlank`): nothing to print, zoom or show the source of.
    public var isBlank: Bool
    /// The page's `pageZoom`.
    public var zoom: Double
    /// WebKit's in-app inspector is there for this page (its private piece exists and the page has developer extras).
    public var inspectorAvailable: Bool
    /// The inspector can open on the page's source.
    public var sourceAvailable: Bool
    /// Where the selected tab sits; nil with no tab selected. ⌘D pins only a regular tab (question 18).
    public var selectedSection: SlotSection?
    /// The page is in a private window, which has nothing to pin to.
    public var isPrivate: Bool

    public init(
        isLoading: Bool = false, canGoBack: Bool = false, canGoForward: Bool = false, hasPage: Bool = false, blockingOn: Bool? = nil,
        hasFailure: Bool = false, isBlank: Bool = false, zoom: Double = ZoomLevels.defaultLevel, inspectorAvailable: Bool = false,
        sourceAvailable: Bool = false, selectedSection: SlotSection? = nil, isPrivate: Bool = false
    ) {
        self.isLoading = isLoading; self.canGoBack = canGoBack; self.canGoForward = canGoForward
        self.hasPage = hasPage; self.blockingOn = blockingOn
        self.hasFailure = hasFailure; self.isBlank = isBlank; self.zoom = zoom
        self.inspectorAvailable = inspectorAvailable; self.sourceAvailable = sourceAvailable
        self.selectedSection = selectedSection; self.isPrivate = isPrivate
    }
}

/// Which page commands in the menu bar are enabled right now.
public struct PageMenuState: Equatable, Sendable {
    public var canGoBack: Bool
    public var canGoForward: Bool
    public var canReload: Bool
    public var canStop: Bool
    /// The blocking toggle's state, nil when the toggle is disabled.
    public var blockingOn: Bool?
    /// Edit ▸ Find and its items (`FindMenuState`): a page the user can see.
    public var canFind = false
    /// File ▸ Print… (decision 13): a page with content, not a blank tab or a failure panel.
    public var canPrint = false
    /// View ▸ Zoom In, Zoom Out and Actual Size (decision 12): a page with content, and a level to go to.
    public var canZoomIn = false
    public var canZoomOut = false
    public var canResetZoom = false
    /// Develop ▸ Show Web Inspector and Show Page Source (decision 14): the piece each needs is there, and no failure panel hides the page.
    public var canInspect = false
    public var canShowSource = false
    /// Tab ▸ Pin Tab (⌘D, question 18): a regular tab's web page in a normal window. Never on a pinned tab or an Essential, so ⌘D never unpins.
    public var canPinSelected = false

    public static let disabled = PageMenuState(canGoBack: false, canGoForward: false, canReload: false, canStop: false, blockingOn: nil)

    /// Whether View ▸ Content Blocking on This Site applies to a page at `url`: only a web page with a host (http or https). A blank tab,
    /// `about:blank`, a file, `data:` and other schemes have no site to remember the choice for.
    public static func contentBlockingEnabled(url: String) -> Bool { URLScheme.hasWebAuthority(url) }

    /// The blocking toggle's state for a page at `url` whose blocking is `isOn`: nil (disabled) where blocking does not apply.
    public static func blockingState(url: String, isOn: Bool) -> Bool? { contentBlockingEnabled(url: url) ? isOn : nil }

    /// A tab with no address, or `about:blank`.
    public static func isBlank(url: String) -> Bool { url.isEmpty || url == "about:blank" }

    /// No page, a sheet over the window, or the History view in place of the page disables everything: the page behind it is hidden.
    public static func from(status: PageStatusSummary?, sheetOpen: Bool, historyShown: Bool = false) -> PageMenuState {
        guard let status, status.hasPage, !sheetOpen, !historyShown else { return .disabled }
        let visible = !status.hasFailure
        let hasContent = visible && !status.isBlank
        return PageMenuState(
            canGoBack: status.canGoBack, canGoForward: status.canGoForward,
            canReload: true, canStop: status.isLoading, blockingOn: status.blockingOn, canFind: true,
            canPrint: hasContent,
            canZoomIn: hasContent && ZoomLevels.canZoomIn(from: status.zoom),
            canZoomOut: hasContent && ZoomLevels.canZoomOut(from: status.zoom),
            canResetZoom: hasContent && !ZoomLevels.isDefault(status.zoom),
            canInspect: visible && status.inspectorAvailable,
            canShowSource: hasContent && status.sourceAvailable,
            canPinSelected: hasContent && status.selectedSection == .regular && !status.isPrivate
        )
    }
}

/// The page commands' menu titles.
public enum PageMenuText {
    public static let back = "Back"
    public static let forward = "Forward"
    public static let reload = "Reload Page"
    public static let stop = "Stop"
    public static let contentBlocking = "Content Blocking on This Site"
    public static let zoomIn = "Zoom In"
    public static let zoomOut = "Zoom Out"
    public static let actualSize = "Actual Size"
    public static let print = "Print…"
    /// Always visible, with Safari's names and keys (decision 14).
    public static let developMenu = "Develop"
    public static let showWebInspector = "Show Web Inspector"
    public static let showPageSource = "Show Page Source"

    /// The print job's name (decision 13): the page's title, else its host, else its address, else "New Tab".
    public static func printJobTitle(title: String, url: String) -> String {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.isEmpty else { return trimmed }
        return url.isEmpty ? DisplayText.newTabTitle : DisplayText.address(for: url)
    }
    /// Debug builds only.
    public static let debugMenu = "Debug"
    public static let crashPageProcess = "Crash Page Process"
}
