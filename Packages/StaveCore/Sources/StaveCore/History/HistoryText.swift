import Foundation

/// The History menu, the History view and the Clear History prompt: their labels and their enablement rule (decision 9, question 16).
public enum HistoryText {
    public static let menu = "History"
    public static let showAllHistory = "Show All History"
    public static let clearHistoryMenuItem = "Clear History…"

    public static let title = "History"
    public static let searchPlaceholder = "Search History"
    public static let searchLabel = "Search history"
    public static let listLabel = "Visited pages"
    public static let delete = "Delete"
    public static let clearButton = "Clear History…"
    public static let today = "Today"
    public static let yesterday = "Yesterday"

    public static let clearPromptTitle = "Clear History"
    public static let clearPromptMessage = "The pages you visited in the chosen range are removed from history. With the box ticked, cookies and other website data from the same range are removed too, which may sign you out of websites. Your tabs, pinned tabs, archive and downloaded files stay."
    /// The Clear History sheet's checkbox (question 16, answered 2026-11-14): ticked by default, as Safari and Firefox clear website data
    /// with history.
    public static let clearWebsiteDataCheckbox = "Also remove cookies and website data"
    public static let clearWebsiteDataByDefault = true
    /// Shown when the history was cleared but the website data could not be removed.
    public static let websiteDataNotRemoved = "History was cleared, but Stave couldn't remove the cookies and website data."
    public static let clearRangeLabel = "Clear:"
    public static let clearConfirm = "Clear History"
    public static let cancel = "Cancel"

    /// The empty view's text: nothing recorded yet, or nothing matching the search.
    public static func emptyState(searching: Bool) -> String { searching ? "No matching history" : "No history" }

    /// "Today", "Yesterday", else the full local date ("Sunday, November 8, 2026" in English).
    public static func dayHeading(_ day: Date, now: Date, calendar: Calendar, locale: Locale) -> String {
        let today = calendar.startOfDay(for: now)
        let start = calendar.startOfDay(for: day)
        if start == today { return Self.today }
        if let yesterday = calendar.date(byAdding: .day, value: -1, to: today), start == yesterday { return Self.yesterday }
        let formatter = DateFormatter()
        formatter.calendar = calendar
        formatter.timeZone = calendar.timeZone
        formatter.locale = locale
        formatter.dateStyle = .full
        formatter.timeStyle = .none
        return formatter.string(from: start)
    }

    /// A row's title: the page title, else its address shown as everywhere else.
    public static func rowTitle(_ visit: HistoryVisit) -> String {
        DisplayText.title(title: visit.title, url: visit.url)
    }

    /// A row's secondary line: the address as the sidebar shows it.
    public static func rowAddress(_ visit: HistoryVisit) -> String {
        DisplayText.address(for: visit.url)
    }

    /// The visit time, short ("10:42 AM" in English).
    public static func rowTime(_ visit: HistoryVisit, calendar: Calendar, locale: Locale) -> String {
        let formatter = DateFormatter()
        formatter.calendar = calendar
        formatter.timeZone = calendar.timeZone
        formatter.locale = locale
        formatter.dateStyle = .none
        formatter.timeStyle = .short
        return formatter.string(from: visit.visitedAt)
    }

    /// VoiceOver's label for a row: title, address, time.
    public static func rowLabel(_ visit: HistoryVisit, calendar: Calendar, locale: Locale) -> String {
        "\(rowTitle(visit)), \(rowAddress(visit)), \(rowTime(visit, calendar: calendar, locale: locale))"
    }

    /// History ▸ Show All History (⌘Y) and Clear History…: a browser window that is free. A private window has no History view (Stave's
    /// choice), and a sheet over the window waits.
    public static func isShowAllHistoryEnabled(isPrivate: Bool, busy: Bool) -> Bool {
        !isPrivate && MenuCommandGate.isEnabled(.showHistory, busy: busy)
    }
}
