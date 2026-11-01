import Foundation

/// StaveCore's mirror of the web layer's page status; the app maps one onto the other.
public struct PageStatusSummary: Equatable, Sendable {
    public var isLoading: Bool
    public var canGoBack: Bool
    public var canGoForward: Bool
    public var hasPage: Bool
    /// Whether content blocking is on for the page's site; nil when it does not apply.
    public var blockingOn: Bool?

    public init(isLoading: Bool = false, canGoBack: Bool = false, canGoForward: Bool = false, hasPage: Bool = false, blockingOn: Bool? = nil) {
        self.isLoading = isLoading; self.canGoBack = canGoBack; self.canGoForward = canGoForward
        self.hasPage = hasPage; self.blockingOn = blockingOn
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

    public static let disabled = PageMenuState(canGoBack: false, canGoForward: false, canReload: false, canStop: false, blockingOn: nil)

    /// No page, or a sheet over the window, disables everything.
    public static func from(status: PageStatusSummary?, sheetOpen: Bool) -> PageMenuState {
        guard let status, status.hasPage, !sheetOpen else { return .disabled }
        return PageMenuState(
            canGoBack: status.canGoBack, canGoForward: status.canGoForward,
            canReload: true, canStop: status.isLoading, blockingOn: status.blockingOn
        )
    }
}

/// The page commands' menu titles.
public enum PageMenuText {
    public static let back = "Back"
    public static let forward = "Forward"
    public static let reload = "Reload Page"
    public static let stop = "Stop"
    /// Debug builds only.
    public static let debugMenu = "Debug"
    public static let crashPageProcess = "Crash Page Process"
}
