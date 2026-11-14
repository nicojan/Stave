import Foundation
import GRDB
import Observation

/// Rolling copies of the database in `<data folder>/Backups/` (plan 5 decisions 1 and 2): one at `start()`, then one an hour, each
/// made off the main actor. A failure never stops Stave; it is counted, reported through `onFailure`, and retried at the next hour.
@MainActor @Observable
public final class DatabaseBackups {
    public let folder: URL
    /// Failures since the last good copy. Settings shows its message once this reaches 3.
    public private(set) var consecutiveFailures = 0
    public private(set) var lastFailure: BackupError?
    public private(set) var lastSuccess: Date?
    /// Called on the main actor after each failed copy, for the log.
    @ObservationIgnored public var onFailure: ((BackupError) -> Void)?

    @ObservationIgnored private let database: StaveDatabase
    @ObservationIgnored private let excludedTables: [String]
    @ObservationIgnored private let now: () -> Date
    @ObservationIgnored private let verify: @Sendable (URL) throws -> Void
    @ObservationIgnored private var running: Task<Result<URL, BackupError>, Never>?
    @ObservationIgnored private var loop: Task<Void, Never>?

    /// `excludedTables` and `verify` are for tests; the app keeps the defaults (`BackupPolicy.excludedTables`, `quick_check`).
    public init(
        database: StaveDatabase,
        folder: URL,
        excludedTables: [String] = BackupPolicy.excludedTables,
        now: @escaping () -> Date,
        verify: @escaping @Sendable (URL) throws -> Void = DatabaseBackups.quickCheck
    ) {
        self.database = database
        self.folder = folder
        self.excludedTables = excludedTables
        self.now = now
        self.verify = verify
    }

    /// Makes one regular copy now, then prunes the folder. A call made while a copy is running waits for that copy and shares its result.
    public func backUpNow() async -> Result<URL, BackupError> {
        if let running { return await running.value }
        let date = now()
        let task = Task.detached { [database, folder, excludedTables, verify] in
            DatabaseBackups.backUpAndPrune(
                from: database.writer, to: folder, excludedTables: excludedTables, now: date, verify: verify
            )
        }
        running = task
        let result = await task.value
        running = nil
        record(result, at: date)
        return result
    }

    /// Copies now (the launch copy) and then every `BackupPolicy.interval` until `stop()`.
    public func start() {
        guard loop == nil else { return }
        loop = Task { [weak self] in
            var isFirst = true
            while !Task.isCancelled {
                if !isFirst {
                    do { try await Task.sleep(for: .seconds(BackupPolicy.interval)) } catch { return }
                }
                isFirst = false
                guard let self else { return }
                _ = await self.backUpNow()
            }
        }
    }

    public func stop() {
        loop?.cancel()
        loop = nil
    }

    private func record(_ result: Result<URL, BackupError>, at date: Date) {
        switch result {
        case .success:
            consecutiveFailures = 0
            lastFailure = nil
            lastSuccess = date
        case .failure(let error):
            consecutiveFailures += 1
            lastFailure = error
            onFailure?(error)
        }
    }

    // MARK: - The copy (off the main actor)

    /// Writes one self-contained copy of `reader` into `folder` and returns its final URL. The copy goes to `<name>.partial`, loses the
    /// rows of `excludedTables` that exist, is vacuumed and switched to `journal_mode=DELETE`, closed, checked by `verify`, and only then
    /// renamed. On any failure the partial files are removed and no file has a final name. Used by `backUpNow()` and by
    /// `StaveDatabase.open(at:backupBeforeMigrating:)`.
    nonisolated public static func copy(
        from reader: any DatabaseReader,
        to folder: URL,
        kind: BackupKind,
        excludedTables: [String],
        now: Date,
        verify: @Sendable (URL) throws -> Void = DatabaseBackups.quickCheck
    ) throws -> URL {
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        } catch {
            throw BackupError.folderUnavailable
        }
        let final = folder.appendingPathComponent(BackupPolicy.fileName(at: now, kind: kind))
        let partial = URL(fileURLWithPath: final.path + ".partial")
        removePartial(partial)
        do {
            try writePartial(from: reader, to: partial, excludedTables: excludedTables)
        } catch {
            removePartial(partial)
            throw BackupError.copyFailed(String(describing: error))
        }
        do {
            try verify(partial)
        } catch {
            removePartial(partial)
            throw BackupError.checkFailed
        }
        guard rename(partial.path, final.path) == 0 else {
            removePartial(partial)
            throw BackupError.renameFailed
        }
        return final
    }

    /// `PRAGMA quick_check` on a read-only connection; anything but a single "ok" fails.
    nonisolated public static func quickCheck(_ url: URL) throws {
        var configuration = Configuration()
        configuration.readonly = true
        let queue = try DatabaseQueue(path: url.path, configuration: configuration)
        defer { try? queue.close() }
        let rows = try queue.read { db in try String.fetchAll(db, sql: "PRAGMA quick_check") }
        guard rows == ["ok"] else { throw BackupError.checkFailed }
    }

    nonisolated private static func writePartial(from reader: any DatabaseReader, to partial: URL, excludedTables: [String]) throws {
        var configuration = Configuration()
        // The copy keeps every row it isn't told to drop, so a delete never cascades into kept tables.
        configuration.foreignKeysEnabled = false
        let destination = try DatabaseQueue(path: partial.path, configuration: configuration)
        do {
            try reader.backup(to: destination)
            try destination.writeWithoutTransaction { db in
                for table in excludedTables where try db.tableExists(table) {
                    try db.execute(sql: "DELETE FROM \(table.quotedDatabaseIdentifier)")
                }
                try db.execute(sql: "VACUUM")
                let mode = try String.fetchOne(db, sql: "PRAGMA journal_mode = DELETE")
                guard mode?.lowercased() == "delete" else { throw BackupError.copyFailed("journal_mode stayed \(mode ?? "unknown")") }
            }
            try destination.close()
        } catch {
            try? destination.close()
            throw error
        }
    }

    nonisolated private static func removePartial(_ partial: URL) {
        for suffix in ["", "-wal", "-shm", "-journal"] {
            try? FileManager.default.removeItem(atPath: partial.path + suffix)
        }
    }

    // MARK: - Pruning

    nonisolated private static func backUpAndPrune(
        from reader: any DatabaseReader, to folder: URL, excludedTables: [String], now: Date, verify: @Sendable (URL) throws -> Void
    ) -> Result<URL, BackupError> {
        let url: URL
        do {
            url = try copy(from: reader, to: folder, kind: .regular, excludedTables: excludedTables, now: now, verify: verify)
        } catch let error as BackupError {
            return .failure(error)
        } catch {
            return .failure(.copyFailed(String(describing: error)))
        }
        prune(folder: folder, now: now)
        return .success(url)
    }

    /// Deletes only files whose names are Stave's own: copies `BackupPolicy.toDelete` names, and stale `.partial` files. A file that
    /// can't be listed or removed is logged and left; pruning never fails a backup.
    nonisolated static func prune(folder: URL, now: Date) {
        let names: [String]
        do {
            names = try FileManager.default.contentsOfDirectory(atPath: folder.path)
        } catch {
            NSLog("Stave: could not list the backups folder: \(error)")
            return
        }
        let stale = names.filter(BackupPolicy.isStalePartial(fileName:))
        let doomed = BackupPolicy.toDelete(existing: names.compactMap(BackupPolicy.copy(fromFileName:)), now: now).map(\.fileName)
        for name in stale + doomed {
            do {
                try FileManager.default.removeItem(at: folder.appendingPathComponent(name))
            } catch {
                NSLog("Stave: could not remove an old backup: \(error)")
            }
        }
    }
}
