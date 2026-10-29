import Foundation
import GRDB

/// The single SQLite store (WAL) behind every Stave record.
public final class StaveDatabase: Sendable {
    public static let schemaVersion = 1
    public var schemaVersion: Int { Self.schemaVersion }

    private let pool: DatabasePool
    public var writer: any DatabaseWriter { pool }

    private init(pool: DatabasePool) { self.pool = pool }

    /// Creates the folder, opens the file in WAL mode and runs migrations.
    /// A file carrying migrations this build does not know is refused before anything is written.
    public static func open(at fileURL: URL) throws -> StaveDatabase {
        let fileManager = FileManager.default
        let folder = fileURL.deletingLastPathComponent()
        if fileManager.fileExists(atPath: fileURL.path) {
            try refuseIfNewer(fileURL)
        } else {
            try fileManager.createDirectory(at: folder, withIntermediateDirectories: true)
        }

        var configuration = Configuration()
        configuration.foreignKeysEnabled = true
        let pool = try DatabasePool(path: fileURL.path, configuration: configuration)
        try makeMigrator().migrate(pool)
        return StaveDatabase(pool: pool)
    }

    public func close() throws { try pool.close() }

    // MARK: - Newer-schema guard

    /// Opening a `DatabasePool` can write (journal-mode switch, WAL setup), so the check uses a separate
    /// read-only connection that never touches the main file.
    private static func refuseIfNewer(_ fileURL: URL) throws {
        var readOnly = Configuration()
        readOnly.readonly = true
        let queue = try DatabaseQueue(path: fileURL.path, configuration: readOnly)
        defer { try? queue.close() }
        let known = Set(makeMigrator().migrations)
        let applied = try queue.read { db in
            try makeMigrator().appliedIdentifiers(db)
        }
        if !Set(applied).isSubset(of: known) { throw StoreError.newerSchema }
    }

    // MARK: - Migrations

    static func makeMigrator() -> DatabaseMigrator {
        var migrator = DatabaseMigrator()
        migrator.registerMigration("v1", migrate: createSchemaV1)
        return migrator
    }

    private static func createSchemaV1(_ db: Database) throws {
        try db.create(table: "profile") { t in
            t.primaryKey("id", .blob)
            t.column("name", .text).notNull()
            t.column("dataStoreID", .blob).notNull()
            t.column("sortIndex", .double).notNull()
            t.column("modifiedAt", .datetime).notNull()
        }
        try db.create(table: "workspace") { t in
            t.primaryKey("id", .blob)
            t.column("profileID", .blob).notNull().references("profile", onDelete: .cascade)
            t.column("name", .text).notNull()
            t.column("icon", .text).notNull()
            t.column("colorHex", .text).notNull()
            t.column("sortIndex", .double).notNull()
            t.column("modifiedAt", .datetime).notNull()
        }
        try db.create(table: "folder") { t in
            t.primaryKey("id", .blob)
            t.column("workspaceID", .blob).notNull().references("workspace", onDelete: .cascade)
            t.column("parentFolderID", .blob).references("folder", onDelete: .setNull)
            t.column("title", .text).notNull()
            t.column("sortIndex", .double).notNull()
            t.column("isOpen", .boolean).notNull()
            t.column("modifiedAt", .datetime).notNull()
        }
        try db.create(table: "slot") { t in
            t.primaryKey("id", .blob)
            t.column("profileID", .blob).notNull().references("profile", onDelete: .cascade)
            t.column("workspaceID", .blob).references("workspace", onDelete: .cascade)
            t.column("section", .text).notNull()
            t.column("kind", .text).notNull()
            t.column("folderID", .blob).references("folder", onDelete: .setNull)
            t.column("sortIndex", .double).notNull()
            t.column("modifiedAt", .datetime).notNull()
        }
        try db.create(table: "container") { t in
            t.primaryKey("id", .blob)
            t.column("profileID", .blob).notNull().references("profile", onDelete: .cascade)
            t.column("name", .text).notNull()
            t.column("colorHex", .text).notNull()
            t.column("dataStoreID", .blob).notNull()
            t.column("modifiedAt", .datetime).notNull()
        }
        try db.create(table: "tab") { t in
            t.primaryKey("id", .blob)
            t.column("slotID", .blob).notNull().references("slot", onDelete: .cascade)
            // Default NO ACTION: a container in use cannot be deleted (see Task 8).
            t.column("containerID", .blob).references("container")
            t.column("pinnedURL", .text)
            t.column("pinnedTitle", .text)
            t.column("pinnedFaviconURL", .text)
            t.column("url", .text).notNull()
            t.column("title", .text).notNull()
            t.column("faviconURL", .text)
            t.column("interactionState", .blob)
            t.column("lastActiveAt", .datetime).notNull()
            t.column("modifiedAt", .datetime).notNull()
        }
        // workspaceID and containerID are plain columns on purpose: archived rows must outlive both.
        try db.create(table: "archivedTab") { t in
            t.primaryKey("id", .blob)
            t.column("profileID", .blob).notNull().references("profile", onDelete: .cascade)
            t.column("workspaceID", .blob)
            t.column("pinnedURL", .text)
            t.column("pinnedTitle", .text)
            t.column("pinnedFaviconURL", .text)
            t.column("url", .text).notNull()
            t.column("title", .text).notNull()
            t.column("faviconURL", .text)
            t.column("interactionState", .blob)
            t.column("containerID", .blob)
            t.column("closedAt", .datetime).notNull()
            t.column("modifiedAt", .datetime).notNull()
        }
        try db.create(table: "windowState") { t in
            t.primaryKey("id", .blob)
            t.column("profileID", .blob).notNull().references("profile", onDelete: .cascade)
            t.column("workspaceID", .blob).notNull()
            t.column("selectedTabID", .blob)
            t.column("frame", .text).notNull()
            t.column("sortIndex", .double).notNull()
            t.column("modifiedAt", .datetime).notNull()
        }
        try db.create(index: "slot_on_workspaceID", on: "slot", columns: ["workspaceID"])
        try db.create(index: "tab_on_slotID", on: "tab", columns: ["slotID"])
        try db.create(index: "archivedTab_on_closedAt", on: "archivedTab", columns: ["closedAt"])
    }
}
