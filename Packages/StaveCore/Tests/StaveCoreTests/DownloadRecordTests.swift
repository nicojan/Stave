import Foundation
import GRDB
import Testing
@testable import StaveCore

/// The kept downloads list (plan 5 decision 33, question 22): per profile in the database, never for a private window, trimmed by
/// "Remove download list items", and never touching a file.
@MainActor
struct DownloadRecordTests {
    private struct World {
        let store: OrganizationStore
        let database: StaveDatabase
        let file: URL
        let clock: TestClock
        let profile: Profile
        var owner: DownloadOwner { .profile(profile.id) }
    }

    private func makeWorld() throws -> World {
        let clock = TestClock()
        let (store, database, file) = try makeTempStore(now: clock.now)
        let profile = try store.ensureDefaultProfile()
        return World(store: store, database: database, file: file, clock: clock, profile: profile)
    }

    private func makeList(_ world: World, retention: DownloadListRetention = .day) -> DownloadList {
        let clock = world.clock
        return DownloadList(store: world.store, retention: { retention }, now: { clock.date })
    }

    private func recordCount(_ world: World) throws -> Int {
        try world.database.writer.read { db in try DownloadRecord.fetchCount(db) }
    }

    private func tempFile(_ name: String) throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("StaveDLRecords-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let file = dir.appendingPathComponent(name)
        try Data("bytes".utf8).write(to: file)
        return file
    }

    @Test func listSurvivesRelaunch() throws {
        let world = try makeWorld()
        let list = makeList(world)
        let file = try tempFile("kept.txt")
        defer { try? FileManager.default.removeItem(at: file.deletingLastPathComponent()) }
        let done = list.begin(owner: world.owner, filename: "kept.txt", sourceHost: "example.com")
        list.finish(done, at: file)
        let failed = list.begin(owner: world.owner, filename: "bad.bin", sourceHost: "example.org")
        list.fail(failed, message: "Network lost")
        let cancelled = list.begin(owner: world.owner, filename: "stop.bin", sourceHost: nil)
        list.cancel(cancelled)

        // A relaunch: the same file opened again, a new list.
        let reopened = OrganizationStore(database: try StaveDatabase.open(at: world.file), now: world.clock.now)
        let relaunched = DownloadList(store: reopened, retention: { .day }, now: world.clock.now)
        relaunched.loadPersisted()
        let items = relaunched.items(for: world.owner)
        #expect(items.map(\.filename) == ["stop.bin", "bad.bin", "kept.txt"], "newest first")
        #expect(items.first { $0.id == done }?.state == .finished(file))
        #expect(items.first { $0.id == done }?.sourceHost == "example.com")
        if case .failed? = items.first(where: { $0.id == failed })?.state {} else { Issue.record("a failed row stays failed") }
        #expect(items.first { $0.id == cancelled }?.state == .cancelled)
        #expect(relaunched.hasItems(for: world.owner))
    }

    @Test func privateRowsNeverStored() throws {
        let world = try makeWorld()
        let list = makeList(world)
        let window = DownloadOwner.privateWindow(UUID())
        let id = list.begin(owner: window, filename: "secret.bin", sourceHost: "example.com")
        list.progress(id, fraction: 0.5)
        list.finish(id, at: URL(fileURLWithPath: "/private/tmp/secret.bin"))
        let other = list.begin(owner: window, filename: "x.bin", sourceHost: nil)
        list.fail(other, message: "no")
        list.clearFinished(owner: window)
        #expect(try recordCount(world) == 0)
    }

    @Test func runningAtQuitShowsStopped() throws {
        let world = try makeWorld()
        let list = makeList(world)
        let running = list.begin(owner: world.owner, filename: "big.iso", sourceHost: "example.net")
        list.progress(running, fraction: 0.4)
        // Stave quits here: the row was never ended.
        let relaunched = makeList(world)
        relaunched.restoreAtLaunch()
        let row = try #require(relaunched.items(for: world.owner).first)
        #expect(row.state == .stopped)
        #expect(row.state.hasEnded)
        #expect(DownloadRowText.status(row, missingFile: false) == "Stopped")
        #expect(!DownloadRowText.canCancel(row))
        // The stopped row is a finished row now: it is stored as such, not running, and can be cleared.
        let state = try world.database.writer.read { db in try DownloadRecord.fetchOne(db)?.state }
        #expect(state == .stopped)
        #expect(DownloadRowText.canClear(relaunched.items(for: world.owner)))
    }

    @Test func retentionRemovesOldRowsNotFiles() throws {
        let world = try makeWorld()
        let list = makeList(world, retention: .day)
        let file = try tempFile("old.txt")
        defer { try? FileManager.default.removeItem(at: file.deletingLastPathComponent()) }
        let old = list.begin(owner: world.owner, filename: "old.txt", sourceHost: nil)
        list.finish(old, at: file)
        let oldRunning = list.begin(owner: world.owner, filename: "running.bin", sourceHost: nil)
        world.clock.advance(by: 2 * 86_400)
        let recent = list.begin(owner: world.owner, filename: "new.txt", sourceHost: nil)
        list.finish(recent, at: URL(fileURLWithPath: "/private/tmp/new.txt"))

        list.trimAtLaunch()

        #expect(list.items(for: world.owner).map(\.id) == [recent, oldRunning])
        #expect(FileManager.default.fileExists(atPath: file.path), "removing a row never touches the file")
        #expect(try recordCount(world) == 2)
    }

    @Test func dayRetentionTrimsOnDailyTick() throws {
        let world = try makeWorld()
        let list = makeList(world, retention: .day)
        let first = list.begin(owner: world.owner, filename: "a.txt", sourceHost: nil)
        list.finish(first, at: URL(fileURLWithPath: "/private/tmp/a.txt"))
        world.clock.advance(by: 20 * 3600)
        list.trimDaily()
        #expect(list.items(for: world.owner).map(\.id) == [first], "not yet a day old")
        world.clock.advance(by: 6 * 3600)
        list.trimDaily()
        #expect(list.items(for: world.owner).isEmpty)
        #expect(try recordCount(world) == 0)
        #expect(!list.hasItems(for: world.owner))
    }

    @Test func otherRetentionsKeepRowsOnTheDailyTickAndTrimAsAsked() throws {
        let world = try makeWorld()
        for retention in [DownloadListRetention.manually, .onQuit, .onSuccess] {
            let list = makeList(world, retention: retention)
            let id = list.begin(owner: world.owner, filename: "a.txt", sourceHost: nil)
            if retention != .onSuccess { list.finish(id, at: URL(fileURLWithPath: "/private/tmp/a.txt")) }
            world.clock.advance(by: 10 * 86_400)
            list.trimDaily()
            if retention != .onSuccess { #expect(!list.items(for: world.owner).isEmpty, "\(retention)") }
        }
        // Manually never trims, at launch or at quit.
        let manual = makeList(world, retention: .manually)
        manual.restoreAtLaunch()
        let before = manual.items(for: world.owner).count
        manual.trimAtLaunch()
        manual.trimAtQuit()
        #expect(manual.items(for: world.owner).count == before)
        // "When Stave quits" trims ended rows at quit and at launch, and keeps a running one.
        let quit = makeList(world, retention: .onQuit)
        quit.restoreAtLaunch()
        let running = quit.begin(owner: world.owner, filename: "live.bin", sourceHost: nil)
        quit.trimAtQuit()
        #expect(quit.items(for: world.owner).map(\.id) == [running])
        // The launch trim runs before the stop-marking: the download that was running at the clean quit shows as Stopped (it is not
        // trimmed away unseen), and is trimmed at the launch after, like any ended row.
        let relaunched = makeList(world, retention: .onQuit)
        relaunched.restoreAtLaunch()
        let stoppedRow = try #require(relaunched.items(for: world.owner).first)
        #expect(stoppedRow.id == running)
        #expect(stoppedRow.state == .stopped)
        let again = makeList(world, retention: .onQuit)
        again.restoreAtLaunch()
        #expect(again.items(for: world.owner).isEmpty)
    }

    @Test func onSuccessRemovesRowKeepsFile() throws {
        let world = try makeWorld()
        let list = makeList(world, retention: .onSuccess)
        let file = try tempFile("fine.txt")
        defer { try? FileManager.default.removeItem(at: file.deletingLastPathComponent()) }
        let good = list.begin(owner: world.owner, filename: "fine.txt", sourceHost: nil)
        let bad = list.begin(owner: world.owner, filename: "bad.bin", sourceHost: nil)
        list.fail(bad, message: "Network lost")
        list.finish(good, at: file)
        #expect(list.items(for: world.owner).map(\.id) == [bad], "the failed row stays, the finished one went")
        #expect(FileManager.default.fileExists(atPath: file.path))
        #expect(try recordCount(world) == 1)
        // A private window's row is in memory only; Upon successful download removes it too.
        let window = DownloadOwner.privateWindow(UUID())
        let privateRow = list.begin(owner: window, filename: "p.txt", sourceHost: nil)
        list.finish(privateRow, at: file)
        #expect(list.items(for: window).isEmpty)
    }

    @Test func removingARowNeverTouchesItsFile() throws {
        let world = try makeWorld()
        let list = makeList(world)
        let file = try tempFile("stay.txt")
        defer { try? FileManager.default.removeItem(at: file.deletingLastPathComponent()) }
        let id = list.begin(owner: world.owner, filename: "stay.txt", sourceHost: nil)
        list.finish(id, at: file)
        list.clearFinished(owner: world.owner)
        #expect(list.items(for: world.owner).isEmpty)
        #expect(try recordCount(world) == 0)
        #expect(FileManager.default.fileExists(atPath: file.path))
    }

    @Test func missingFileShownAsNotFound() throws {
        let world = try makeWorld()
        let list = makeList(world)
        let here = try tempFile("here.txt")
        defer { try? FileManager.default.removeItem(at: here.deletingLastPathComponent()) }
        let gone = here.deletingLastPathComponent().appendingPathComponent("gone.txt")
        let a = list.begin(owner: world.owner, filename: "here.txt", sourceHost: nil)
        list.finish(a, at: here)
        let b = list.begin(owner: world.owner, filename: "gone.txt", sourceHost: nil)
        list.finish(b, at: gone)
        let c = list.begin(owner: world.owner, filename: "run.bin", sourceHost: nil)
        let items = list.items(for: world.owner)
        let missing = DownloadRowText.missingFileIDs(items) { FileManager.default.fileExists(atPath: $0.path) }
        #expect(missing == [b])
        let rowB = try #require(items.first { $0.id == b })
        let rowA = try #require(items.first { $0.id == a })
        let rowC = try #require(items.first { $0.id == c })
        #expect(DownloadRowText.status(rowB, missingFile: true) == "File not found")
        #expect(DownloadRowText.status(rowA, missingFile: false) == "Done")
        #expect(DownloadRowText.status(rowC, missingFile: true) != "File not found", "only a finished row can be missing")
        #expect(DownloadRowText.canShowInFinder(rowB, missingFile: true) == false)
        #expect(DownloadRowText.canShowInFinder(rowA, missingFile: false))
        #expect(DownloadRowText.finishedFile(rowB) == gone)
    }

    @Test func nanProgressIgnored() {
        let list = DownloadList()
        let owner = DownloadOwner.profile(UUID())
        let id = list.begin(owner: owner, filename: "a.bin", sourceHost: nil)
        list.progress(id, fraction: .nan)
        #expect(list.items(for: owner).first?.state == .running(fraction: nil))
        list.progress(id, fraction: 0.5)
        list.progress(id, fraction: .nan)
        #expect(list.items(for: owner).first?.state == .running(fraction: 0.5))
        list.progress(id, fraction: .infinity)
        #expect(list.items(for: owner).first?.state == .running(fraction: 1))
    }

    @Test func backupLeavesOutDownloads() async throws {
        #expect(BackupPolicy.excludedTables == ["historyVisit", "downloadRecord"])
        let world = try makeWorld()
        let list = makeList(world)
        let id = list.begin(owner: world.owner, filename: "a.txt", sourceHost: nil)
        list.finish(id, at: URL(fileURLWithPath: "/private/tmp/a.txt"))
        let folder = world.file.deletingLastPathComponent().appendingPathComponent("Backups", isDirectory: true)
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let backups = DatabaseBackups(database: world.database, folder: folder, now: { now })
        let url = try await backups.backUpNow().get()
        var configuration = Configuration()
        configuration.readonly = true
        let copy = try DatabaseQueue(path: url.path, configuration: configuration)
        defer { try? copy.close() }
        let (rows, profiles) = try await copy.read { db in (try DownloadRecord.fetchCount(db), try Profile.fetchCount(db)) }
        #expect(rows == 0)
        #expect(profiles == 1)
        #expect(try recordCount(world) == 1, "the live database keeps its row")
    }

    @Test func retentionChoicesUseSafarisLabels() {
        #expect(DownloadListRetention.allCases.map(\.title) == ["After one day", "When Stave quits", "Upon successful download", "Manually"])
        #expect(DownloadListRetention.settingTitle == "Remove download list items")
        #expect(SettingKeys.downloadListRetention.defaultValue == .day)
        #expect(SettingsCopy.labels(in: .general).contains(DownloadListRetention.settingTitle))
    }

    @Test func deletingAProfileTakesItsRowsWithIt() throws {
        let world = try makeWorld()
        let list = makeList(world)
        let kept = list.begin(owner: world.owner, filename: "a.txt", sourceHost: nil)
        list.finish(kept, at: URL(fileURLWithPath: "/private/tmp/a.txt"))
        let second = try world.store.createProfile(name: "Second")
        let doomed = list.begin(owner: .profile(second.id), filename: "b.txt", sourceHost: nil)
        list.finish(doomed, at: URL(fileURLWithPath: "/private/tmp/b.txt"))
        #expect(try recordCount(world) == 2)
        _ = try world.store.deleteProfile(second.id)
        #expect(try recordCount(world) == 1)
    }
}
