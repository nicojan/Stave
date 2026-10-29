import Foundation
@testable import StaveCore

/// A fresh database file in its own temp folder. The caller may delete the folder's parent when done.
func makeTempDatabase() throws -> (StaveDatabase, URL) {
    let folder = FileManager.default.temporaryDirectory
        .appendingPathComponent("StaveTests-\(UUID().uuidString)", isDirectory: true)
    let file = folder.appendingPathComponent(StavePaths.databaseFileName)
    let database = try StaveDatabase.open(at: file)
    return (database, file)
}

/// A controllable clock for stores under test. Lock-protected so it can be captured by a `@Sendable` closure.
final class TestClock: @unchecked Sendable {
    private let lock = NSLock()
    private var current: Date

    init(start: Date = Date(timeIntervalSince1970: 1_700_000_000)) { current = start }

    var date: Date {
        lock.lock(); defer { lock.unlock() }
        return current
    }

    func advance(by seconds: TimeInterval) {
        lock.lock(); defer { lock.unlock() }
        current = current.addingTimeInterval(seconds)
    }

    /// The closure to hand to `OrganizationStore(database:now:)`.
    var now: @Sendable () -> Date { { [self] in date } }
}

/// A store on a fresh database file. The clock defaults to the real one.
func makeTempStore(now: @escaping @Sendable () -> Date = Date.init) throws -> (OrganizationStore, StaveDatabase, URL) {
    let (database, file) = try makeTempDatabase()
    return (OrganizationStore(database: database, now: now), database, file)
}
