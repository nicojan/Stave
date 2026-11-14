import Foundation

/// What one find in the page answered. WebKit's public find reports only whether a match was found, never a count (decision 11; the
/// Task 8 spike found no system find bar on WKWebView).
public enum FindOutcome: Equatable, Sendable {
    case found, notFound
}

/// One search to run on the page: the text, and which way from the current match.
public struct FindSearch: Equatable, Sendable {
    public let query: String
    public let backwards: Bool

    public init(query: String, backwards: Bool) {
        self.query = query
        self.backwards = backwards
    }
}

/// The find bar's strings and the Edit ▸ Find menu's titles.
public enum FindText {
    public static let notFound = "Not found"
    public static let menu = "Find"
    public static let findMenuItem = "Find…"
    public static let findNextMenuItem = "Find Next"
    public static let findPreviousMenuItem = "Find Previous"
    public static let useSelectionMenuItem = "Use Selection for Find"
    public static let fieldLabel = "Find on Page"
    public static let fieldPlaceholder = "Find on Page"
    public static let nextButton = "Next Match"
    public static let previousButton = "Previous Match"
    public static let doneButton = "Done"
}

/// One tab's find bar: whether it shows, its text and the last search's outcome. Escape hides the bar and keeps the text, so ⌘G finds it
/// again with the bar closed, as Safari does.
public struct FindState: Equatable, Sendable {
    /// The longest text kept: a selection or paste longer than this is cut, since page text is outside input.
    public static let maxQueryLength = 1_000

    public private(set) var query: String
    public private(set) var isVisible: Bool
    /// The outcome for `query`; nil before a search, after the text changes, and while the bar is hidden.
    public private(set) var result: FindOutcome?

    public init(query: String = "", isVisible: Bool = false, result: FindOutcome? = nil) {
        self.query = Self.capped(query)
        self.isVisible = isVisible
        self.result = result
    }

    /// ⌘F.
    public mutating func show() { isVisible = true }

    /// The field's text changed. A different text forgets the old outcome.
    public mutating func setQuery(_ text: String) {
        let next = Self.capped(text)
        guard next != query else { return }
        query = next
        result = nil
    }

    /// Escape or Done: the bar goes, the text stays for ⌘G.
    public mutating func hide() {
        isVisible = false
        result = nil
    }

    /// ⌘E: the page's selection becomes the text, without showing the bar. An empty or blank selection changes nothing.
    public mutating func useSelection(_ text: String) {
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        setQuery(text)
    }

    /// Return, ⇧Return, ⌘G and ⇧⌘G: the search to run, which also shows the bar. Nil with no text.
    public mutating func findNext(backwards: Bool) -> FindSearch? {
        guard !query.isEmpty else { return nil }
        isVisible = true
        return FindSearch(query: query, backwards: backwards)
    }

    public mutating func record(_ outcome: FindOutcome) { result = outcome }

    /// Records an outcome only if it answers the current text; an answer for older text arrives late and is dropped.
    public mutating func record(_ outcome: FindOutcome, for searched: String) {
        guard searched == query else { return }
        record(outcome)
    }

    /// Whether Find Next and Find Previous have something to find.
    public var canFindAgain: Bool { !query.isEmpty }

    /// The bar's status line, which VoiceOver reads: "Not found" after a search that found nothing, else nothing.
    public var statusText: String? { isVisible && result == .notFound ? FindText.notFound : nil }

    private static func capped(_ text: String) -> String {
        text.count > maxQueryLength ? String(text.prefix(maxQueryLength)) : text
    }
}

/// A window's find bars, one per tab, as in Safari, Chrome and Firefox. Only a shown bar is kept; a tab without one reads a hidden bar holding
/// the last text searched in the window, so ⌘G and a newly opened bar start from it.
public struct FindSessions: Equatable, Sendable {
    private var shown: [UUID: FindState] = [:]
    public private(set) var lastQuery = ""

    public init() {}

    /// The bar for `tabID` (nil: no tab), or a hidden one with the last text.
    public func state(for tabID: UUID?) -> FindState {
        tabID.flatMap { shown[$0] } ?? FindState(query: lastQuery)
    }

    /// Applies `change` to the tab's bar. The bar is kept while it shows; its text becomes the window's last text.
    public mutating func update(_ tabID: UUID, _ change: (inout FindState) -> Void) {
        var state = state(for: tabID)
        change(&state)
        lastQuery = state.query
        shown[tabID] = state.isVisible ? state : nil
    }

    /// The tab closed or its page went.
    public mutating func forget(_ tabID: UUID) { shown[tabID] = nil }
}

/// Edit ▸ Find's enablement for the key window.
public struct FindMenuState: Equatable, Sendable {
    public var canFind: Bool
    public var canFindAgain: Bool
    public var canUseSelection: Bool

    public init(canFind: Bool, canFindAgain: Bool, canUseSelection: Bool) {
        self.canFind = canFind
        self.canFindAgain = canFindAgain
        self.canUseSelection = canUseSelection
    }

    public static let disabled = FindMenuState(canFind: false, canFindAgain: false, canUseSelection: false)

    /// Everything needs a page the user can see (`PageMenuState.canFind`); Find Next and Previous also need text.
    public static func from(pageMenu: PageMenuState, find: FindState) -> FindMenuState {
        guard pageMenu.canFind else { return .disabled }
        return FindMenuState(canFind: true, canFindAgain: find.canFindAgain, canUseSelection: true)
    }
}
