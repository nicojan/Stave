import Foundation

/// Which of decision 16's tab items are enabled for the key window. ⌘D's rule is `PageMenuState.canPinSelected`; the page items keep theirs.
public struct TabShortcutMenuState: Equatable, Sendable {
    /// ⌘1–9, ⌃Tab and ⌃⇧Tab: the window has a tab to go to.
    public var canSelectTab: Bool
    /// ⇧⌘T: a browser window (a private window has no archive). With nothing archived it does nothing, as Safari does.
    public var canReopenClosedTab: Bool
    /// ⌥⌘L: the window's downloads button is there to open.
    public var canShowDownloads: Bool

    public init(canSelectTab: Bool, canReopenClosedTab: Bool, canShowDownloads: Bool) {
        self.canSelectTab = canSelectTab; self.canReopenClosedTab = canReopenClosedTab; self.canShowDownloads = canShowDownloads
    }

    public static let disabled = TabShortcutMenuState(canSelectTab: false, canReopenClosedTab: false, canShowDownloads: false)

    /// Nothing while the window is busy (`MenuCommandGate`), as every window command.
    public static func from(busy: Bool, isPrivate: Bool, tabCount: Int, hasDownloads: Bool) -> TabShortcutMenuState {
        TabShortcutMenuState(
            canSelectTab: MenuCommandGate.isEnabled(.selectTab, busy: busy) && tabCount > 0,
            canReopenClosedTab: MenuCommandGate.isEnabled(.reopenClosedTab, busy: busy) && !isPrivate,
            canShowDownloads: MenuCommandGate.isEnabled(.showDownloads, busy: busy) && hasDownloads
        )
    }
}
