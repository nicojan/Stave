import Foundation
import Observation

/// The History view's state (decision 9, question 16): the search text, the visits loaded so far grouped by local day, and the selection.
/// It lives only while the view shows and is never saved. The view draws it; Return, double-click and Delete come here.
@MainActor @Observable
public final class HistoryBrowser {
    public let profileID: UUID
    /// The search field's text; changing it reloads from the newest visit.
    public var query: String {
        didSet { if query != oldValue { reload() } }
    }
    public private(set) var visits: [HistoryVisit] = []
    public private(set) var sections: [HistoryDaySection] = []
    public var selection: Set<UUID> = []
    public private(set) var canLoadMore = false
    public private(set) var lastError: String?

    @ObservationIgnored private let store: OrganizationStore
    @ObservationIgnored private let pageSize: Int
    @ObservationIgnored private let now: () -> Date
    @ObservationIgnored public let calendar: Calendar
    @ObservationIgnored public let locale: Locale
    @ObservationIgnored private var next: HistoryCursor?

    public static let defaultPageSize = 200

    public init(
        store: OrganizationStore, profileID: UUID, pageSize: Int = HistoryBrowser.defaultPageSize,
        now: @escaping () -> Date = Date.init, calendar: Calendar = .current, locale: Locale = .current
    ) {
        self.store = store
        self.profileID = profileID
        self.pageSize = max(pageSize, 1)
        self.now = now
        self.calendar = calendar
        self.locale = locale
        self.query = ""
        reload()
    }

    /// Reads the first page again (after a search change, a delete or Clear History). The selection keeps only visits still listed.
    public func reload() {
        next = nil
        load(replacing: true)
    }

    /// Appends the next page, when there is one (the list's last row appeared).
    public func loadMore() {
        guard canLoadMore else { return }
        load(replacing: false)
    }

    private func load(replacing: Bool) {
        do {
            let page = try store.historyPage(profileID: profileID, matching: query, after: replacing ? nil : next, limit: pageSize)
            let all = (replacing ? [] : visits) + page.visits
            next = page.next
            canLoadMore = page.next != nil
            visits = all
            sections = HistoryGrouping.byDay(all, now: now(), calendar: calendar, locale: locale)
            selection = selection.intersection(all.map(\.id))
            lastError = nil
        } catch {
            lastError = StoreErrorText.message(for: error)
        }
    }

    /// Delete: removes the selected visits (history rows only) and reloads. Returns how many went.
    @discardableResult
    public func deleteSelected() -> Int {
        guard !selection.isEmpty else { return 0 }
        do {
            let removed = try store.deleteVisits(ids: Array(selection))
            selection = []
            reload()
            return removed
        } catch {
            lastError = StoreErrorText.message(for: error)
            return 0
        }
    }

    /// The visit Return or a double-click opens: the clicked row, else the first selected row in list order.
    public func visitToOpen(clicked: UUID?) -> HistoryVisit? {
        if let clicked, let visit = visits.first(where: { $0.id == clicked }) { return visit }
        return visits.first { selection.contains($0.id) }
    }
}
