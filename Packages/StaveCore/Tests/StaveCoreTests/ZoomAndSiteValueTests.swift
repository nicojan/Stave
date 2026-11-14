import Foundation
import GRDB
import Testing
@testable import StaveCore

/// Zoom per site (decision 12) and the `siteValue` table it is stored in (migration v6).
struct ZoomAndSiteValueTests {
    // MARK: Zoom levels

    @Test func zoomStepsThroughSafariLevels() {
        #expect(ZoomLevels.levels == [0.5, 0.75, 0.85, 1.0, 1.15, 1.25, 1.5, 1.75, 2.0, 2.5, 3.0])
        #expect(ZoomLevels.next(after: 1.0) == 1.15)
        #expect(ZoomLevels.next(after: 1.15) == 1.25)
        #expect(ZoomLevels.next(after: 3.0) == 3.0)
        #expect(ZoomLevels.previous(before: 1.0) == 0.85)
        #expect(ZoomLevels.previous(before: 0.5) == 0.5)
        // A level between two steps (set some other way) moves to the nearest step in that direction.
        #expect(ZoomLevels.next(after: 1.1) == 1.15)
        #expect(ZoomLevels.previous(before: 1.1) == 1.0)
        #expect(ZoomLevels.isDefault(1.0))
        #expect(!ZoomLevels.isDefault(1.15))
    }

    /// A stored zoom is our own row, but a value outside Safari's range (or not a number) never reaches the page as is.
    @Test func storedZoomIsClampedToTheLevels() {
        #expect(ZoomLevels.sanitized(1.5) == 1.5)
        #expect(ZoomLevels.sanitized(40) == 3.0)
        #expect(ZoomLevels.sanitized(0.01) == 0.5)
        #expect(ZoomLevels.sanitized(-2) == 0.5)
        #expect(ZoomLevels.sanitized(.nan) == 1.0)
        #expect(ZoomLevels.sanitized(.infinity) == 1.0)
        #expect(ZoomLevels.sanitized(nil) == 1.0)
    }

    /// Only a level other than 100 % is stored; 100 % means no row.
    @Test func defaultZoomRemovesTheRow() throws {
        let (store, database, _) = try makeTempStore()
        let profile = try store.createProfile(name: "P")
        try store.setSiteValue(profileID: profile.id, host: "example.com", key: .zoom, ZoomLevels.storedValue(1.5))
        #expect(try store.siteValue(profileID: profile.id, host: "example.com", key: .zoom, as: Double.self) == 1.5)
        try store.setSiteValue(profileID: profile.id, host: "example.com", key: .zoom, ZoomLevels.storedValue(1.0))
        #expect(try store.siteValue(profileID: profile.id, host: "example.com", key: .zoom, as: Double.self) == nil)
        #expect(try database.writer.read { db in try SiteValue.fetchCount(db) } == 0)
    }

    @Test func zoomStoredPerHostAndProfile() throws {
        let (store, _, _) = try makeTempStore()
        let p = try store.createProfile(name: "P")
        let q = try store.createProfile(name: "Q")
        try store.setSiteValue(profileID: p.id, host: "example.com", key: .zoom, 1.25)
        try store.setSiteValue(profileID: q.id, host: "example.com", key: .zoom, 0.75)
        try store.setSiteValue(profileID: p.id, host: "example.org", key: .zoom, 2.0)
        #expect(try store.siteValue(profileID: p.id, host: "example.com", key: .zoom, as: Double.self) == 1.25)
        #expect(try store.siteValue(profileID: q.id, host: "example.com", key: .zoom, as: Double.self) == 0.75)
        #expect(try store.siteValue(profileID: p.id, host: "example.org", key: .zoom, as: Double.self) == 2.0)
        #expect(try store.siteValue(profileID: q.id, host: "example.org", key: .zoom, as: Double.self) == nil)
        // Another key on the same host is its own row.
        #expect(try store.siteValue(profileID: p.id, host: "example.com", key: .userAgent, as: String.self) == nil)
        // Writing again replaces the value in place.
        try store.setSiteValue(profileID: p.id, host: "example.com", key: .zoom, 1.5)
        #expect(try store.siteValue(profileID: p.id, host: "example.com", key: .zoom, as: Double.self) == 1.5)
    }

    @Test func siteValuesFollowProfileDeletionAndMissingProfile() throws {
        let (store, database, _) = try makeTempStore()
        let p = try store.createProfile(name: "P")
        try store.setSiteValue(profileID: p.id, host: "example.net", key: .zoom, 1.5)
        try database.writer.write { db in _ = try Profile.deleteOne(db, key: p.id) }
        #expect(try database.writer.read { db in try SiteValue.fetchCount(db) } == 0)
        #expect(throws: StoreError.notFound) {
            try store.setSiteValue(profileID: UUID(), host: "example.net", key: .zoom, 1.5)
        }
        // Removing a value that isn't there is no error, even for an unknown profile.
        try store.setSiteValue(profileID: UUID(), host: "example.net", key: .zoom, Double?.none)
    }

    /// A row whose value doesn't decode as asked is reported, never returned as something else.
    @Test func undecodableValueThrows() throws {
        let (store, _, _) = try makeTempStore()
        let p = try store.createProfile(name: "P")
        try store.setSiteValue(profileID: p.id, host: "example.com", key: .userAgent, "chrome")
        #expect(throws: (any Error).self) {
            try store.siteValue(profileID: p.id, host: "example.com", key: .userAgent, as: Double.self)
        }
    }

    // MARK: Schema

    @Test func siteValueIndexIsUnique() throws {
        let (store, database, _) = try makeTempStore()
        let p = try store.createProfile(name: "P")
        let first = SiteValue(profileID: p.id, host: "example.com", key: .zoom, value: "1.5")
        let second = SiteValue(profileID: p.id, host: "example.com", key: .zoom, value: "2.0")
        try database.writer.write { db in try first.insert(db) }
        do {
            try database.writer.write { db in try second.insert(db) }
            Issue.record("a second row for the same profile, host and key was inserted")
        } catch let error as DatabaseError {
            #expect(error.extendedResultCode == .SQLITE_CONSTRAINT_UNIQUE)
        }
        // The same host and key in another profile is allowed.
        let q = try store.createProfile(name: "Q")
        try database.writer.write { db in try SiteValue(profileID: q.id, host: "example.com", key: .zoom, value: "2.0").insert(db) }
    }

    /// A database at v5 (Task 6) gains the empty `siteValue` table at v6 and keeps its rows.
    @Test func migrationAddsSiteValue() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("StaveTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let file = folder.appendingPathComponent(StavePaths.databaseFileName)
        let queue = try DatabaseQueue(path: file.path)
        try StaveDatabase.makeMigrator().migrate(queue, upTo: "v5")
        let profile = Profile(name: "Before", sortIndex: 1)
        try queue.write { db in try profile.insert(db) }
        let before = try queue.read { db in try db.tableExists("siteValue") }
        #expect(!before)
        try queue.close()

        let database = try StaveDatabase.open(at: file)
        let (columns, rows, profiles) = try database.writer.read { db in
            (try db.columns(in: "siteValue").map(\.name), try SiteValue.fetchCount(db), try Profile.fetchCount(db))
        }
        #expect(Set(columns) == ["id", "profileID", "host", "key", "value", "modifiedAt"])
        #expect(rows == 0)
        #expect(profiles == 1)
        let applied = try database.writer.read { db in try StaveDatabase.makeMigrator().appliedIdentifiers(db) }
        #expect(applied.contains("v6"))
        try database.close()
        try? FileManager.default.removeItem(at: folder)
    }
}
