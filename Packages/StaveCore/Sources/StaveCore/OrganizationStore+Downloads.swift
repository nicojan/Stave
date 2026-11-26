import Foundation
import GRDB

/// Where a kept download row stands. `stopped` is a download that was still running when Stave quit.
public enum DownloadRecordState: String, Codable, Sendable, Equatable {
    case running, finished, failed, cancelled, stopped
}

/// One row of the kept downloads list (decision 33). It names the file but never owns it: deleting the row leaves the file alone.
public struct DownloadRecord: Codable, FetchableRecord, PersistableRecord, Sendable, Identifiable, Equatable {
    public var id: UUID
    public var profileID: UUID
    public var filename: String
    public var sourceHost: String?
    public var filePath: String?
    public var state: DownloadRecordState
    public var startedAt: Date
    public var endedAt: Date?

    public init(
        id: UUID, profileID: UUID, filename: String, sourceHost: String?, filePath: String? = nil,
        state: DownloadRecordState = .running, startedAt: Date, endedAt: Date? = nil
    ) {
        self.id = id; self.profileID = profileID; self.filename = filename; self.sourceHost = sourceHost
        self.filePath = filePath; self.state = state; self.startedAt = startedAt; self.endedAt = endedAt
    }
}

extension OrganizationStore {
    /// A download started in a profile's window. Never called for a private window.
    public func recordDownloadStarted(id: UUID, profileID: UUID, filename: String, sourceHost: String?, at date: Date) throws {
        let record = DownloadRecord(id: id, profileID: profileID, filename: filename, sourceHost: sourceHost, startedAt: Self.storedPrecision(date))
        try database.writer.write { db in try record.insert(db) }
    }

    /// The download ended: `finished` (with its file's path), `failed` or `cancelled`. An unknown ID changes nothing.
    public func recordDownloadEnded(id: UUID, state: DownloadRecordState, filePath: String?, at date: Date) throws {
        let ended = Self.storedPrecision(date)
        try database.writer.write { db in
            guard var record = try DownloadRecord.fetchOne(db, key: id) else { return }
            record.state = state
            record.filePath = filePath
            record.endedAt = ended
            try record.update(db)
        }
    }

    /// Every profile's kept rows, oldest first (ties by insertion).
    public func downloadRecords() throws -> [DownloadRecord] {
        try database.writer.read { db in
            try DownloadRecord.order(Column("startedAt"), Column("rowid")).fetchAll(db)
        }
    }

    /// A download still running when Stave quit has no process behind it now: its row becomes `stopped`.
    @discardableResult
    public func markRunningDownloadsStopped(at date: Date) throws -> Int {
        let stamp = Self.storedPrecision(date)
        return try database.writer.write { db in
            try DownloadRecord
                .filter(Column("state") == DownloadRecordState.running.rawValue)
                .updateAll(db, Column("state").set(to: DownloadRecordState.stopped.rawValue), Column("endedAt").set(to: stamp))
        }
    }

    /// Deletes the given rows (rows only, never a file). Unknown IDs are skipped.
    @discardableResult
    public func deleteDownloadRecords(ids: [UUID]) throws -> Int {
        guard !ids.isEmpty else { return 0 }
        return try database.writer.write { db in try DownloadRecord.filter(ids.contains(Column("id"))).deleteAll(db) }
    }

    /// Deletes ended rows (never a running one): one profile's or every profile's, optionally only those that started at or after
    /// `startedSince`.
    @discardableResult
    public func deleteEndedDownloads(profileID: UUID?, startedSince: Date?) throws -> Int {
        try database.writer.write { db in try Self.endedDownloads(profileID: profileID, in: db, startedSince: startedSince).deleteAll(db) }
    }

    /// Deletes ended rows that ended before `endedBefore` (rows with no end time count from when they started).
    @discardableResult
    public func deleteEndedDownloads(profileID: UUID?, endedBefore: Date) throws -> Int {
        try database.writer.write { db in
            try Self.endedDownloads(profileID: profileID, in: db, startedSince: nil)
                .filter(sql: "COALESCE(endedAt, startedAt) < ?", arguments: [endedBefore])
                .deleteAll(db)
        }
    }

    static func endedDownloads(profileID: UUID?, in db: Database, startedSince: Date?) -> QueryInterfaceRequest<DownloadRecord> {
        var request = DownloadRecord.filter(Column("state") != DownloadRecordState.running.rawValue)
        if let profileID { request = request.filter(Column("profileID") == profileID) }
        if let startedSince { request = request.filter(Column("startedAt") >= startedSince) }
        return request
    }
}
