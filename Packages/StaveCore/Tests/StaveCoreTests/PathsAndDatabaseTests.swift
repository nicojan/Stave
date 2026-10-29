import Foundation
import GRDB
import Testing
@testable import StaveCore

struct PathsAndDatabaseTests {
    private let base = URL(fileURLWithPath: "/tmp/base", isDirectory: true)

    @Test func dataDirectoryForRelease() {
        let url = StavePaths.dataDirectory(bundleIdentifier: "com.nicojan.Stave", applicationSupport: base)
        #expect(url == base.appendingPathComponent("Stave", isDirectory: true))
    }

    @Test func dataDirectoryForDebug() {
        let url = StavePaths.dataDirectory(bundleIdentifier: "com.nicojan.Stave.debug", applicationSupport: base)
        #expect(url == base.appendingPathComponent("Stave-debug", isDirectory: true))
    }

    @Test func openCreatesSchema() throws {
        let (database, _) = try makeTempDatabase()
        let tables = try database.writer.read { db in
            try String.fetchAll(db, sql: "SELECT name FROM sqlite_master WHERE type = 'table'")
        }
        for name in ["profile", "workspace", "folder", "slot", "tab", "container", "archivedTab", "windowState"] {
            #expect(tables.contains(name), "missing table \(name)")
        }
        #expect(database.schemaVersion == 1)
    }

    @Test func reopenKeepsData() throws {
        let (database, file) = try makeTempDatabase()
        let profile = Profile(name: "Personal", sortIndex: 1)
        try database.writer.write { db in try profile.insert(db) }
        try database.close()

        let reopened = try StaveDatabase.open(at: file)
        let fetched = try reopened.writer.read { db in try Profile.fetchOne(db, key: profile.id) }
        #expect(fetched?.name == "Personal")
    }

    @Test func foreignKeysFollowRulingR2() throws {
        let (database, _) = try makeTempDatabase()
        let profile = Profile(name: "P", sortIndex: 1)
        let workspace = Workspace(profileID: profile.id, name: "W", icon: "star", colorHex: "#fff", sortIndex: 1)
        let folder = Folder(workspaceID: workspace.id, title: "F", sortIndex: 1)
        let slot = Slot(profileID: profile.id, workspaceID: workspace.id, section: .regular, folderID: folder.id, sortIndex: 1)
        let tab = Tab(slotID: slot.id, url: "https://example.com", title: "x")
        let archived = ArchivedTab(profileID: profile.id, workspaceID: workspace.id, url: "https://a.example", title: "a")
        try database.writer.write { db in
            try profile.insert(db); try workspace.insert(db); try folder.insert(db)
            try slot.insert(db); try tab.insert(db); try archived.insert(db)
            // Deleting a folder moves its slots to the root, never deletes them.
            try folder.delete(db)
            #expect(try Slot.fetchOne(db, key: slot.id)?.folderID == nil)
            // Deleting a workspace cascades slots and tabs, but archivedTab has no FK.
            try workspace.delete(db)
            #expect(try Slot.fetchCount(db) == 0)
            #expect(try Tab.fetchCount(db) == 0)
            #expect(try ArchivedTab.fetchCount(db) == 1)
            // Deleting the profile cascades archived tabs.
            try profile.delete(db)
            #expect(try ArchivedTab.fetchCount(db) == 0)
        }
    }

    @Test func containerInUseCannotBeDeleted() throws {
        let (database, _) = try makeTempDatabase()
        let profile = Profile(name: "P", sortIndex: 1)
        let container = Container(profileID: profile.id, name: "C", colorHex: "#000")
        let slot = Slot(profileID: profile.id, workspaceID: nil, section: .essential, sortIndex: 1)
        let tab = Tab(slotID: slot.id, containerID: container.id, url: "https://e.example", title: "e")
        try database.writer.write { db in
            try profile.insert(db); try container.insert(db); try slot.insert(db); try tab.insert(db)
        }
        #expect(throws: DatabaseError.self) {
            try database.writer.write { db in _ = try container.delete(db) }
        }
    }

    @Test func newerSchemaIsRefused() throws {
        let (database, file) = try makeTempDatabase()
        try database.close()

        var migrator = DatabaseMigrator()
        migrator.registerMigration("v1") { _ in }
        migrator.registerMigration("v999") { db in try db.execute(sql: "CREATE TABLE future (id INTEGER)") }
        let queue = try DatabaseQueue(path: file.path)
        try migrator.migrate(queue)
        try queue.close()

        let before = try FileManager.default.attributesOfItem(atPath: file.path)
        #expect(throws: StoreError.newerSchema) { try StaveDatabase.open(at: file) }
        let after = try FileManager.default.attributesOfItem(atPath: file.path)

        #expect(before[.size] as? Int == after[.size] as? Int)
        #expect(before[.modificationDate] as? Date == after[.modificationDate] as? Date)
    }
}
