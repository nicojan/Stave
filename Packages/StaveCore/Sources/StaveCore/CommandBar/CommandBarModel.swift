import Foundation
import Observation

/// The command bar's state: the typed text, the ranked results and the selected row. The view only draws it.
@MainActor @Observable
public final class CommandBarModel {
    public let mode: CommandBarMode
    public var query: String {
        didSet {
            guard query != oldValue else { return }
            results = CommandBarSearch.results(query: query, candidates: candidates)
            selectedIndex = 0
            pendingSearch = nil // editing the text leaves the engine picker; the search it held is no longer the one typed
        }
    }
    public private(set) var results: [CommandResult]
    public private(set) var selectedIndex = 0

    /// The search that is waiting for an engine, while the engine picker shows in the bar.
    public private(set) var pendingSearch: String?
    /// The highlighted engine; nil until the first ↓, so no engine is preselected (decision 27).
    public private(set) var engineIndex: Int?

    @ObservationIgnored private let candidates: CommandCandidates
    @ObservationIgnored private let currentWorkspaceID: UUID?
    @ObservationIgnored private let engine: SearchEngine?
    /// The tab a `.currentTab` address applies to, captured when the bar opens so a workspace switch or a close while it is open cannot
    /// redirect it onto another tab.
    public let targetTabID: UUID?

    public init(
        mode: CommandBarMode, candidates: CommandCandidates, currentURL: String?,
        currentWorkspaceID: UUID? = nil, searchEngine: SearchEngine? = nil, currentTabID: UUID? = nil
    ) {
        self.mode = mode
        self.targetTabID = mode == .currentTab ? currentTabID : nil
        self.candidates = candidates
        self.currentWorkspaceID = currentWorkspaceID
        self.engine = searchEngine
        let start = mode == .currentTab ? Self.prefill(for: currentURL) : ""
        query = start
        results = CommandBarSearch.results(query: start, candidates: candidates)
    }

    /// Only a web address is worth editing; a stored `file:`, `about:` or other URL must never land in the query and go to a search engine.
    private static func prefill(for url: String?) -> String {
        guard let url else { return "" }
        let lower = url.lowercased()
        return lower.hasPrefix("http://") || lower.hasPrefix("https://") ? url : ""
    }

    /// The rows to draw, one per result.
    public var rows: [CommandRow] {
        results.map { CommandRows.row(for: $0, currentWorkspaceID: currentWorkspaceID, engine: engine) }
    }

    public var isChoosingEngine: Bool { pendingSearch != nil }
    public var engineChoices: [SearchEngine] { SearchEngine.allCases }
    public var selectedEngine: SearchEngine? { engineIndex.flatMap { engineChoices.indices.contains($0) ? engineChoices[$0] : nil } }

    /// Selects a row by position (a click); out-of-range positions are ignored.
    public func select(index: Int) {
        guard results.indices.contains(index) else { return }
        selectedIndex = index
    }

    /// Selects an engine by position (a click) while the picker shows.
    public func selectEngine(at index: Int) {
        guard isChoosingEngine, engineChoices.indices.contains(index) else { return }
        engineIndex = index
    }

    public func moveSelection(by delta: Int) {
        if isChoosingEngine {
            guard let current = engineIndex else {
                if delta > 0 { engineIndex = 0 } // the first ↓ highlights the first engine; ↑ with nothing highlighted does nothing
                return
            }
            engineIndex = min(max(current + delta, 0), engineChoices.count - 1)
            return
        }
        guard !results.isEmpty else { selectedIndex = 0; return }
        selectedIndex = min(max(selectedIndex + delta, 0), results.count - 1)
    }

    public var selectedResult: CommandResult? {
        results.indices.contains(selectedIndex) ? results[selectedIndex] : nil
    }

    /// `.currentTab` with no tab to change (none was selected when the bar opened) is a new tab, never "whatever is selected now".
    private var effectiveMode: CommandBarMode { mode == .currentTab && targetTabID == nil ? .newTab : mode }

    /// What happened to the bar after Return or a click: it stays (an engine must be chosen, or nothing was selected), or it closes with the outcome
    /// the window could not handle itself.
    public enum Step: Equatable, Sendable { case stay, close(CommandOutcome) }

    /// Runs the selected result in the window. A search with no engine chosen keeps the bar open on the engine picker; picking an engine saves
    /// it and then runs that search.
    public func activate(in window: BrowserWindowModel) -> Step {
        if let query = pendingSearch {
            guard let engine = selectedEngine else { return .stay }
            window.chooseSearchEngine(engine, thenSearching: query, mode: effectiveMode, target: targetTabID)
            return .close(.done)
        }
        guard let result = selectedResult else { return .stay }
        let outcome = window.perform(result, mode: effectiveMode, target: targetTabID)
        guard outcome == .chooseSearchEngine, case .search(let query) = result else { return .close(outcome) }
        pendingSearch = query
        engineIndex = nil
        return .stay
    }
}
