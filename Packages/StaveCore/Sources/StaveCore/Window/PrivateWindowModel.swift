import Foundation
import Observation

/// One tab of a private window. It lives in memory only and is gone when its window closes.
public struct PrivateTab: Equatable, Sendable, Identifiable {
    public let id: UUID
    public var url: String
    public var title: String

    public init(id: UUID = UUID(), url: String, title: String = "") {
        self.id = id; self.url = url; self.title = title
    }

    /// The new value with the page's address and title.
    func with(url: String, title: String) -> PrivateTab { PrivateTab(id: id, url: url, title: title) }
}

/// What a private window shows and does (plan 3, decision 15): a plain tab list, held in memory only. It has no store, no archive and no
/// window state, so nothing it does is written to disk and nothing of it is restored. Closing a tab drops it for good.
@MainActor @Observable
public final class PrivateWindowModel {
    public let windowID: UUID
    public private(set) var tabs: [PrivateTab] = []
    public private(set) var selectedTabID: UUID?
    /// The engine searches use: the app's setting when the window opened, or one picked in this window's bar, which is kept here only.
    public private(set) var searchEngine: SearchEngine?

    /// The page host, told about closed and deselected tabs. Weak: the app owns both.
    @ObservationIgnored public weak var pages: PageLifecycle?
    /// Set by the app: opens an address from the command bar in the tab's live page (judged as typed) and moves focus into it. False when
    /// the tab has no page to take it; the address is then kept on the tab, and the page made for it later loads it.
    @ObservationIgnored public var loadTyped: ((_ tabID: UUID, _ url: String) -> Bool)?
    @ObservationIgnored private let newTabEdge: NewTabEdge

    public init(windowID: UUID = UUID(), searchEngine: SearchEngine? = nil, newTabEdge: NewTabEdge = SettingKeys.newTabEdge.defaultValue) {
        self.windowID = windowID
        self.searchEngine = searchEngine
        self.newTabEdge = newTabEdge
    }

    public var selectedTab: PrivateTab? { selectedTabID.flatMap { id in tabs.first { $0.id == id } } }

    // MARK: - Tabs

    /// Opens a tab directly below `opener` (a link), or at the new-tab edge when there is no opener or it is gone. Returns the new tab's ID.
    @discardableResult
    public func open(url: String, below opener: UUID?, select shouldSelect: Bool) -> UUID {
        let tab = PrivateTab(url: url)
        let index: Int = if let opener, let found = tabs.firstIndex(where: { $0.id == opener }) {
            found + 1
        } else {
            newTabEdge == .top ? 0 : tabs.count
        }
        tabs = Array(tabs[..<index]) + [tab] + Array(tabs[index...])
        if shouldSelect { select(tab.id) }
        return tab.id
    }

    /// Drops the tab and its page. Closing the selected tab selects the row below it, else the one above, else nothing.
    public func close(_ id: UUID) {
        guard let index = tabs.firstIndex(where: { $0.id == id }) else { return }
        let wasSelected = id == selectedTabID
        let remaining = tabs.filter { $0.id != id }
        tabs = remaining
        if wasSelected {
            selectedTabID = remaining.isEmpty ? nil : remaining[min(index, remaining.count - 1)].id
        }
        pages?.tabClosed(id)
    }

    /// Selects a tab (nil for none); an ID that is no tab here is ignored. The tab that was shown is told it was deselected.
    public func select(_ id: UUID?) {
        guard id != selectedTabID else { return }
        if let id, !tabs.contains(where: { $0.id == id }) { return }
        let old = selectedTabID
        selectedTabID = id
        if let old { pages?.tabDeselected(old) }
    }

    /// The page's committed address and title. A tab already closed is ignored.
    public func update(_ id: UUID, url: String, title: String) {
        guard let index = tabs.firstIndex(where: { $0.id == id }) else { return }
        guard tabs[index].url != url || tabs[index].title != title else { return }
        tabs = tabs.enumerated().map { offset, tab in offset == index ? tab.with(url: url, title: title) : tab }
    }

    // MARK: - Command bar

    /// Nothing to match: the private bar shows only the typed row (an address or a search).
    public var commandCandidates: CommandCandidates { CommandCandidates() }
}

extension PrivateWindowModel: CommandBarWindow {
    /// Only the typed row exists here; any other result does nothing.
    public func perform(_ result: CommandResult, mode: CommandBarMode, target: UUID?) -> CommandOutcome {
        switch result {
        case .open(let url):
            open(typed: url, mode: mode, target: target)
        case .search(let query):
            guard let engine = searchEngine else { return .chooseSearchEngine }
            open(typed: engine.searchURL(for: query), mode: mode, target: target)
        case .tab, .archived, .workspace, .action:
            break
        }
        return .done
    }

    /// The picked engine is used for this window only; a private window writes nothing, so it is not saved.
    public func chooseSearchEngine(_ engine: SearchEngine, thenSearching query: String, mode: CommandBarMode, target: UUID?) {
        searchEngine = engine
        open(typed: engine.searchURL(for: query), mode: mode, target: target)
    }

    private func open(typed url: String, mode: CommandBarMode, target: UUID?) {
        guard mode == .currentTab, let id = target ?? selectedTabID, tabs.contains(where: { $0.id == id }) else {
            let created = open(url: url, below: nil, select: true)
            _ = loadTyped?(created, url)
            return
        }
        if loadTyped?(id, url) == true { return }
        update(id, url: url, title: "")
    }
}

/// The text of the private window.
public enum PrivateWindowText {
    public static let menuItem = "New Private Window"
    public static let sidebarTitle = "Private"
    public static let windowTitle = "Private"
    public static let tabListLabel = "Private tabs"
    public static let newTabButton = "New Tab"
    public static let closeTabLabel = "Close Tab"
    public static let emptyHint = "Pages you open here leave no history, cookies or tabs behind when the window closes."

    /// A tab's row title: its page title, else its address, else "New Tab".
    public static func title(for tab: PrivateTab) -> String {
        DisplayText.title(title: tab.title, url: tab.url)
    }

    public static func windowTitle(selected: PrivateTab?) -> String {
        guard let selected else { return windowTitle }
        return "\(title(for: selected)) — \(windowTitle)"
    }
}
