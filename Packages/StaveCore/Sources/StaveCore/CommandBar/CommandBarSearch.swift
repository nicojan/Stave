import Foundation

/// Ranks command-bar candidates. Pure: the model and the tests both call it.
public enum CommandBarSearch {
    public static func results(query: String, candidates: CommandCandidates, limit: Int = 12) -> [CommandResult] {
        guard limit > 0 else { return [] }
        let typed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        let row: CommandResult
        switch AddressInput.classify(typed) {
        case .empty: return candidates.tabs.prefix(limit).map { .tab($0) }
        case .url(let url): row = .open(url: url)
        case .search(let text): row = .search(query: text)
        }
        let needle = fold(typed)
        let matches = entries(candidates).enumerated().compactMap { index, entry -> Ranked? in
            guard let score = score(needle, title: entry.title, url: entry.url) else { return nil }
            return Ranked(score: score, kind: entry.kind, index: index, result: entry.result)
        }
        let sorted = matches.sorted { ($0.score, $0.kind, $0.index) < ($1.score, $1.kind, $1.index) }
        return [row] + sorted.prefix(limit - 1).map(\.result)
    }

    private struct Entry { var kind: Int; var title: String; var url: String?; var result: CommandResult }
    private struct Ranked { var score: Int; var kind: Int; var index: Int; var result: CommandResult }

    /// Candidate order, with kind order open tabs, workspaces, actions, archived tabs.
    private static func entries(_ candidates: CommandCandidates) -> [Entry] {
        candidates.tabs.map { Entry(kind: 0, title: DisplayText.title(for: $0.tab), url: $0.tab.url, result: .tab($0)) }
            + candidates.workspaces.map { Entry(kind: 1, title: $0.name, url: nil, result: .workspace($0)) }
            + candidates.actions.map { Entry(kind: 2, title: $0.title, url: nil, result: .action($0)) }
            + candidates.archived.map { Entry(kind: 3, title: DisplayText.title(title: $0.title, url: $0.url), url: $0.url, result: .archived($0)) }
    }

    /// 0 title prefix, 1 word prefix, 2 substring of the title or URL; nil for no match.
    private static func score(_ needle: String, title: String, url: String?) -> Int? {
        let title = fold(title)
        if title.hasPrefix(needle) { return 0 }
        let words = title.split { !$0.isLetter && !$0.isNumber }
        if words.contains(where: { $0.hasPrefix(needle) }) { return 1 }
        if title.contains(needle) { return 2 }
        if let url, fold(url).contains(needle) { return 2 }
        return nil
    }

    private static func fold(_ text: String) -> String {
        text.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
    }
}
