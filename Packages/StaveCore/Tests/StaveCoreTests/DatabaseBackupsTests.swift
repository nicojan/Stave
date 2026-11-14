import Foundation
import GRDB
import Testing
@testable import StaveCore

@MainActor @Suite struct DatabaseBackupsTests {
    private struct InjectedCheckFailure: Error {}

    private let fixedNow = Date(timeIntervalSince1970: 1_794_312_000) // 2026-11-10 12:00:00 UTC

    private func backupsFolder(beside file: URL) -> URL {
        file.deletingLastPathComponent().appendingPathComponent(BackupPolicy.folderName, isDirectory: true)
    }

    private func names(in folder: URL) -> [String] {
        ((try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []).sorted()
    }

    private func readOnlyQueue(_ url: URL) throws -> DatabaseQueue {
        var configuration = Configuration()
        configuration.readonly = true
        return try DatabaseQueue(path: url.path, configuration: configuration)
    }

    private func quickCheck(_ url: URL) throws -> String? {
        let queue = try readOnlyQueue(url)
        defer { try? queue.close() }
        return try queue.read { db in try String.fetchOne(db, sql: "PRAGMA quick_check") }
    }

    @Test func backupIsAReadableCopy() async throws {
        let (database, file) = try makeTempDatabase()
        let profile = Profile(name: "Invented", sortIndex: 1)
        try await database.writer.write { db in try profile.insert(db) }
        let folder = backupsFolder(beside: file)
        let now = fixedNow
        let backups = DatabaseBackups(database: database, folder: folder, now: { now })

        let url = try await backups.backUpNow().get()

        #expect(url.lastPathComponent == BackupPolicy.fileName(at: fixedNow, kind: .regular))
        #expect(names(in: folder) == [url.lastPathComponent])
        let queue = try readOnlyQueue(url)
        let (names, check, mode) = try await queue.read { db in
            (try Profile.fetchAll(db).map(\.name),
             try String.fetchOne(db, sql: "PRAGMA quick_check"),
             try String.fetchOne(db, sql: "PRAGMA journal_mode"))
        }
        try queue.close()
        #expect(names == ["Invented"])
        #expect(check == "ok")
        #expect(mode?.lowercased() != "wal")
        #expect(!FileManager.default.fileExists(atPath: url.path + "-wal"))
        #expect(!FileManager.default.fileExists(atPath: url.path + "-shm"))
        #expect(backups.consecutiveFailures == 0)
        #expect(backups.lastSuccess == fixedNow)
        #expect(backups.lastFailure == nil)
    }

    @Test func copyOmitsExcludedTables() async throws {
        let (database, file) = try makeTempDatabase()
        try await database.writer.write { db in
            try db.execute(sql: "CREATE TABLE backupTestRows (id INTEGER PRIMARY KEY, value TEXT)")
            try db.execute(sql: "INSERT INTO backupTestRows (value) VALUES ('a'), ('b'), ('c')")
            try Profile(name: "Kept", sortIndex: 1).insert(db)
        }
        let now = fixedNow
        let backups = DatabaseBackups(
            database: database, folder: backupsFolder(beside: file),
            excludedTables: ["backupTestRows", "noSuchTable"], now: { now }
        )

        let url = try await backups.backUpNow().get()

        let queue = try readOnlyQueue(url)
        let (rows, profiles, check) = try await queue.read { db in
            (try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM backupTestRows"),
             try Profile.fetchCount(db),
             try String.fetchOne(db, sql: "PRAGMA quick_check"))
        }
        try queue.close()
        #expect(rows == 0)
        #expect(profiles == 1)
        #expect(check == "ok")
        // The live database keeps its rows.
        let live = try await database.writer.read { db in try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM backupTestRows") }
        #expect(live == 3)
    }

    @Test func failedCopyLeavesNoFinalFile() async throws {
        let (database, file) = try makeTempDatabase()
        let folder = backupsFolder(beside: file)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: folder.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: folder.path) }
        let now = fixedNow
        let backups = DatabaseBackups(database: database, folder: folder, now: { now })

        let result = await backups.backUpNow()

        guard case .failure = result else { Issue.record("expected a failure, got \(result)"); return }
        #expect(names(in: folder).isEmpty)
        #expect(backups.consecutiveFailures == 1)
        #expect(backups.lastFailure != nil)
        #expect(backups.lastSuccess == nil)
    }

    @Test func failedCheckLeavesNoFinalFile() async throws {
        let (database, file) = try makeTempDatabase()
        let folder = backupsFolder(beside: file)
        let now = fixedNow
        let backups = DatabaseBackups(database: database, folder: folder, now: { now }, verify: { _ in throw InjectedCheckFailure() })

        let result = await backups.backUpNow()

        #expect(result == .failure(.checkFailed))
        #expect(names(in: folder).isEmpty, "left: \(names(in: folder))")
        #expect(backups.consecutiveFailures == 1)
        // A second failure counts up; a success resets the count.
        _ = await backups.backUpNow()
        #expect(backups.consecutiveFailures == 2)
        let healthy = DatabaseBackups(database: database, folder: folder, now: { now })
        _ = await healthy.backUpNow()
        #expect(healthy.consecutiveFailures == 0)
    }

    @Test func successResetsFailures() async throws {
        let (database, file) = try makeTempDatabase()
        let folder = backupsFolder(beside: file)
        let failing = LockedFlag(true)
        let now = fixedNow
        let backups = DatabaseBackups(database: database, folder: folder, now: { now }, verify: { url in
            if failing.value { throw InjectedCheckFailure() }
            try DatabaseBackups.quickCheck(url)
        })
        _ = await backups.backUpNow()
        #expect(backups.consecutiveFailures == 1)
        failing.value = false
        _ = try await backups.backUpNow().get()
        #expect(backups.consecutiveFailures == 0)
        #expect(backups.lastFailure == nil)
    }

    @Test func pruneKeepsOnlyOwnFiles() async throws {
        let (database, file) = try makeTempDatabase()
        let folder = backupsFolder(beside: file)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        // 14 old Stave copies half an hour apart on the same UTC day, plus strangers.
        let oldNames = (1...14).map { BackupPolicy.fileName(at: fixedNow.addingTimeInterval(-Double($0) * 1800), kind: .regular) }
        for name in oldNames + ["notes.txt", "stave-old.sqlite", "notes.partial"] {
            try Data("x".utf8).write(to: folder.appendingPathComponent(name))
        }
        let now = fixedNow
        let backups = DatabaseBackups(database: database, folder: folder, now: { now })

        let url = try await backups.backUpNow().get()

        let left = Set(names(in: folder))
        #expect(left.contains("notes.txt"))
        #expect(left.contains("stave-old.sqlite"))
        #expect(left.contains("notes.partial"))
        #expect(left.contains(url.lastPathComponent))
        // The new copy plus the 9 newest old ones are the 10 hourly copies.
        #expect(left.subtracting(["notes.txt", "stave-old.sqlite", "notes.partial"]) == Set([url.lastPathComponent] + oldNames.prefix(9)))
    }

    @Test func prunesStalePartials() async throws {
        let (database, file) = try makeTempDatabase()
        let folder = backupsFolder(beside: file)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let stale = "stave-20261110-110000.sqlite.partial"
        for name in [stale, stale + "-wal", "notes.partial"] {
            try Data("x".utf8).write(to: folder.appendingPathComponent(name))
        }
        let now = fixedNow
        let backups = DatabaseBackups(database: database, folder: folder, now: { now })

        let url = try await backups.backUpNow().get()

        #expect(Set(names(in: folder)) == [url.lastPathComponent, "notes.partial"])
    }

    @Test func migrationBacksUpFirst() throws {
        let (database, file) = try makeTempDatabase()
        try database.close()
        let folder = file.deletingLastPathComponent().appendingPathComponent("older", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let olderFile = folder.appendingPathComponent(StavePaths.databaseFileName)
        let migrations = StaveDatabase.makeMigrator().migrations
        let secondNewest = migrations[migrations.count - 2]
        let queue = try DatabaseQueue(path: olderFile.path)
        try StaveDatabase.makeMigrator().migrate(queue, upTo: secondNewest)
        try queue.write { db in try Profile(name: "Before", sortIndex: 1).insert(db) }
        try queue.close()

        let opened = try StaveDatabase.open(at: olderFile, backupBeforeMigrating: true)

        let backups = folder.appendingPathComponent(BackupPolicy.folderName, isDirectory: true)
        let copies = names(in: backups)
        #expect(copies.count == 1)
        let copyName = try #require(copies.first)
        #expect(BackupPolicy.copy(fromFileName: copyName)?.kind == .premigration)
        let copy = try readOnlyQueue(backups.appendingPathComponent(copyName))
        let (applied, profiles) = try copy.read { db in
            (try String.fetchAll(db, sql: "SELECT identifier FROM grdb_migrations"),
             try Profile.fetchAll(db).map(\.name))
        }
        try copy.close()
        #expect(applied.last == secondNewest)
        #expect(!applied.contains(migrations.last!))
        #expect(profiles == ["Before"])
        let openedApplied = try opened.writer.read { db in try StaveDatabase.makeMigrator().appliedIdentifiers(db) }
        #expect(openedApplied.contains(migrations.last!))
        try opened.close()

        // Control: a file already at the newest migration gets no copy.
        let reopened = try StaveDatabase.open(at: olderFile, backupBeforeMigrating: true)
        try reopened.close()
        #expect(names(in: backups) == copies)
        let current = try StaveDatabase.open(at: file, backupBeforeMigrating: true)
        try current.close()
        #expect(names(in: backupsFolder(beside: file)).isEmpty)
    }

    @Test func newFileAndDefaultOpenMakeNoCopy() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("StaveTests-\(UUID().uuidString)", isDirectory: true)
        let fresh = try StaveDatabase.open(at: folder.appendingPathComponent(StavePaths.databaseFileName), backupBeforeMigrating: true)
        try fresh.close()
        #expect(names(in: folder.appendingPathComponent(BackupPolicy.folderName)).isEmpty)

        // Without the flag, an older file migrates with no copy (tests and tools keep the default).
        let olderFile = folder.appendingPathComponent("older.sqlite")
        let queue = try DatabaseQueue(path: olderFile.path)
        try StaveDatabase.makeMigrator().migrate(queue, upTo: "v1")
        try queue.close()
        let opened = try StaveDatabase.open(at: olderFile)
        try opened.close()
        #expect(names(in: folder.appendingPathComponent(BackupPolicy.folderName)).isEmpty)
    }

    @Test func newerSchemaRefusedBeforeAnyCopy() throws {
        let (database, file) = try makeTempDatabase()
        try database.close()
        var migrator = DatabaseMigrator()
        migrator.registerMigration("v1") { _ in }
        migrator.registerMigration("v999") { db in try db.execute(sql: "CREATE TABLE future (id INTEGER)") }
        let queue = try DatabaseQueue(path: file.path)
        try migrator.migrate(queue)
        try queue.close()

        #expect(throws: StoreError.newerSchema) { try StaveDatabase.open(at: file, backupBeforeMigrating: true) }
        #expect(!FileManager.default.fileExists(atPath: backupsFolder(beside: file).path))
    }

    @Test func failedPremigrationCopyRefusesOpen() throws {
        let (database, file) = try makeTempDatabase()
        try database.close()
        let folder = file.deletingLastPathComponent().appendingPathComponent("older", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let olderFile = folder.appendingPathComponent(StavePaths.databaseFileName)
        let queue = try DatabaseQueue(path: olderFile.path)
        try StaveDatabase.makeMigrator().migrate(queue, upTo: "v1")
        try queue.close()
        // A plain file where the Backups folder should be: the copy can't be written.
        try Data("x".utf8).write(to: folder.appendingPathComponent(BackupPolicy.folderName))
        let before = try Data(contentsOf: olderFile)

        #expect(throws: StoreError.backupFailed) { try StaveDatabase.open(at: olderFile, backupBeforeMigrating: true) }

        #expect(try Data(contentsOf: olderFile) == before)
        let check = try quickCheck(olderFile)
        #expect(check == "ok")
        let applied = try readOnlyQueue(olderFile).read { db in try StaveDatabase.makeMigrator().appliedIdentifiers(db) }
        #expect(applied == ["v1"])
    }

    @Test func backupFailedHasAMessage() {
        #expect(StoreErrorText.message(for: StoreError.backupFailed) == "Stave couldn't back up your data before updating it, so it didn't open it. Free some disk space and try again.")
    }

    @Test func startMakesALaunchCopyAndStopEnds() async throws {
        let (database, file) = try makeTempDatabase()
        let folder = backupsFolder(beside: file)
        let now = fixedNow
        let backups = DatabaseBackups(database: database, folder: folder, now: { now })
        backups.start()
        for _ in 0..<200 where backups.lastSuccess == nil {
            try await Task.sleep(for: .milliseconds(20))
        }
        backups.stop()
        #expect(backups.lastSuccess == fixedNow)
        #expect(names(in: folder) == [BackupPolicy.fileName(at: fixedNow, kind: .regular)])
    }
}

/// A Bool shared with a `@Sendable` closure.
final class LockedFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: Bool
    init(_ value: Bool) { stored = value }
    var value: Bool {
        get { lock.lock(); defer { lock.unlock() }; return stored }
        set { lock.lock(); defer { lock.unlock() }; stored = newValue }
    }
}
