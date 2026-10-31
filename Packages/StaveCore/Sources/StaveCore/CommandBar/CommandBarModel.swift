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
        }
    }
    public private(set) var results: [CommandResult]
    public private(set) var selectedIndex = 0

    @ObservationIgnored private let candidates: CommandCandidates

    public init(mode: CommandBarMode, candidates: CommandCandidates, currentURL: String?) {
        self.mode = mode
        self.candidates = candidates
        let start = mode == .currentTab ? (currentURL ?? "") : ""
        query = start
        results = CommandBarSearch.results(query: start, candidates: candidates)
    }

    public func moveSelection(by delta: Int) {
        guard !results.isEmpty else { selectedIndex = 0; return }
        selectedIndex = min(max(selectedIndex + delta, 0), results.count - 1)
    }

    public var selectedResult: CommandResult? {
        results.indices.contains(selectedIndex) ? results[selectedIndex] : nil
    }
}
