import Foundation
import GRDB

/// Where the History view's next page starts: the last row shown, by time and then rowid, so visits in the same second are never skipped
/// or repeated across a page boundary.
public struct HistoryCursor: Equatable, Sendable {
    public var visitedAt: Date
    public var rowid: Int64

    public init(visitedAt: Date, rowid: Int64) {
        self.visitedAt = visitedAt; self.rowid = rowid
    }
}

/// One page of the History view, newest first, and the cursor for the next one (nil when this page is the last).
public struct HistoryPage: Equatable, Sendable {
    public var visits: [HistoryVisit]
    public var next: HistoryCursor?

    public init(visits: [HistoryVisit], next: HistoryCursor?) {
        self.visits = visits; self.next = next
    }
}

extension OrganizationStore {
    // MARK: - Recording

    /// Records a visit (decision 9). A non-web or over-long address is ignored. A visit to the same address within
    /// `HistoryRules.mergeWindow` of its newest row moves that row's time to `at` (never backwards) and keeps its title unless a new
    /// one is given; otherwise a new row is added.
    public func recordVisit(profileID: UUID, url: String, title: String, at date: Date) throws {
        guard HistoryRules.isRecordable(url) else { return }
        let at = Self.storedPrecision(date)
        let stamp = now()
        let cleanTitle = HistoryRules.storedTitle(title)
        try database.writer.write { db in
            if var last = try newestVisit(profileID: profileID, url: url, in: db),
               abs(at.timeIntervalSince(last.visitedAt)) <= HistoryRules.mergeWindow {
                last.visitedAt = max(last.visitedAt, at)
                if !cleanTitle.isEmpty { last.title = cleanTitle }
                last.modifiedAt = stamp
                try last.update(db)
                return
            }
            try HistoryVisit(profileID: profileID, url: url, title: cleanTitle, visitedAt: at, modifiedAt: stamp).insert(db)
        }
    }

    /// Gives the newest visit of `url` its title once the page reports it. A blank title changes nothing.
    public func updateVisitTitle(profileID: UUID, url: String, title: String) throws {
        let cleanTitle = HistoryRules.storedTitle(title)
        guard !cleanTitle.isEmpty, HistoryRules.isRecordable(url) else { return }
        let stamp = now()
        try database.writer.write { db in
            guard var last = try newestVisit(profileID: profileID, url: url, in: db), last.title != cleanTitle else { return }
            last.title = cleanTitle
            last.modifiedAt = stamp
            try last.update(db)
        }
    }

    private func newestVisit(profileID: UUID, url: String, in db: Database) throws -> HistoryVisit? {
        try HistoryVisit
            .filter(Column("profileID") == profileID && Column("url") == url)
            .order(Column("visitedAt").desc, Column("rowid").desc)
            .fetchOne(db)
    }

    // MARK: - Reading

    /// The profile's visits whose title or address contains `matching` (ASCII case-insensitive; empty matches all), newest first.
    public func history(profileID: UUID, matching: String, limit: Int) throws -> [HistoryVisit] {
        try historyPage(profileID: profileID, matching: matching, after: nil, limit: limit).visits
    }

    /// One page of the History view: up to `limit` visits after `cursor` (nil starts at the newest), ordered `visitedAt DESC, rowid DESC`.
    public func historyPage(profileID: UUID, matching: String, after cursor: HistoryCursor?, limit: Int) throws -> HistoryPage {
        guard limit > 0 else { return HistoryPage(visits: [], next: nil) }
        return try database.writer.read { db in
            var request = HistoryVisit.filter(Column("profileID") == profileID)
            let needle = matching.trimmingCharacters(in: .whitespacesAndNewlines)
            if !needle.isEmpty {
                let pattern = "%" + Self.likeEscaped(needle) + "%"
                request = request.filter(sql: "(title LIKE ? ESCAPE '\\' OR url LIKE ? ESCAPE '\\')", arguments: [pattern, pattern])
            }
            if let cursor {
                request = request.filter(
                    sql: "(visitedAt < ? OR (visitedAt = ? AND rowid < ?))",
                    arguments: [cursor.visitedAt, cursor.visitedAt, cursor.rowid]
                )
            }
            let rows = try Row.fetchAll(
                db,
                request.select(AllColumns(), Column("rowid").forKey("historyRowID"))
                    .order(Column("visitedAt").desc, Column("rowid").desc)
                    .limit(limit + 1)
            )
            let visits = try rows.prefix(limit).map { try HistoryVisit(row: $0) }
            let next: HistoryCursor? = rows.count > limit
                ? rows[limit - 1].historyCursor
                : nil
            return HistoryPage(visits: visits, next: next)
        }
    }

    /// `%`, `_` and the escape character itself are matched literally.
    private static func likeEscaped(_ text: String) -> String {
        text.replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "%", with: "\\%")
            .replacingOccurrences(of: "_", with: "\\_")
    }

    // MARK: - Removing (history rows only)

    /// Deletes the given visits; unknown IDs are skipped. Returns how many rows went.
    @discardableResult
    public func deleteVisits(ids: [UUID]) throws -> Int {
        guard !ids.isEmpty else { return 0 }
        return try database.writer.write { db in
            try HistoryVisit.filter(ids.contains(Column("id"))).deleteAll(db)
        }
    }

    /// History ▸ Clear History…: the profile's visits since `since` (all of them when nil). Never touches tabs, pinned tabs, workspaces or
    /// the archive. Task 14 extends it to ended download-list rows.
    @discardableResult
    public func clearHistory(profileID: UUID, since: Date?) throws -> Int {
        try database.writer.write { db in
            var request = HistoryVisit.filter(Column("profileID") == profileID)
            if let since { request = request.filter(Column("visitedAt") >= since) }
            return try request.deleteAll(db)
        }
    }

    /// Removes every profile's visits older than `retention` allows; `.manually` removes nothing.
    @discardableResult
    public func trimHistory(retention: HistoryRetention) throws -> Int {
        try trimHistory(retention: retention, now: now(), calendar: .current)
    }

    func trimHistory(retention: HistoryRetention, now: Date, calendar: Calendar) throws -> Int {
        guard let cutoff = retention.cutoff(now: now, calendar: calendar) else { return 0 }
        return try database.writer.write { db in
            try HistoryVisit.filter(Column("visitedAt") < cutoff).deleteAll(db)
        }
    }

    /// Trims by the stored "Remove history items" setting; run at launch maintenance and once a day.
    @discardableResult
    public func trimHistoryBySetting() throws -> Int {
        try trimHistory(retention: try setting(SettingKeys.historyRetention))
    }
}

private extension Row {
    /// The cursor of a row fetched with its rowid as `historyRowID`.
    var historyCursor: HistoryCursor? {
        guard let date = self["visitedAt"] as Date?, let rowid = self["historyRowID"] as Int64? else { return nil }
        return HistoryCursor(visitedAt: date, rowid: rowid)
    }
}
