import Foundation

/// What the archive popover lists: newest first, filtered by title or address.
public enum ArchiveFilter {
    public static let emptyText = "Nothing in the archive"
    public static let noMatchesText = "No matches"

    public static func results(_ tabs: [ArchivedTab], query: String) -> [ArchivedTab] {
        let needle = query.trimmingCharacters(in: .whitespacesAndNewlines)
        let matching = needle.isEmpty ? tabs : tabs.filter { $0.title.localizedStandardContains(needle) || $0.url.localizedStandardContains(needle) }
        return matching.sorted { $0.closedAt > $1.closedAt }
    }

    /// What the popover says when the list is empty.
    public static func emptyMessage(archiveCount: Int) -> String { archiveCount == 0 ? emptyText : noMatchesText }

    /// Return restores the selected row if it is still listed, else the first.
    public static func restoreTarget(in results: [ArchivedTab], selected: UUID?) -> UUID? {
        if let selected, results.contains(where: { $0.id == selected }) { return selected }
        return results.first?.id
    }
}
