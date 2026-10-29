import Foundation
import GRDB

/// The one door to the organization model: profiles, workspaces, and (in later tasks) tabs, folders, containers and sessions.
/// Every mutating method is a single write transaction that stamps `modifiedAt` from the injected clock.
public final class OrganizationStore: Sendable {
    static let defaultProfileName = "Personal"
    static let homeWorkspaceName = "Home"
    static let homeWorkspaceIcon = "house"
    static let homeWorkspaceColorHex = "#8E8E93"

    let database: StaveDatabase
    let now: @Sendable () -> Date

    /// `now` is brought to stored precision, so a record a method returns equals the same record read back (R24).
    public init(database: StaveDatabase, now: @escaping @Sendable () -> Date = Date.init) {
        self.database = database
        self.now = { Self.storedPrecision(now()) }
    }

    /// Rounds to whole milliseconds (GRDB stores "ss.SSS"), then takes the value GRDB decodes for it: decoding goes through
    /// `DateComponents`, so a rounded date alone can read back a few hundred nanoseconds off and compare unequal.
    static func storedPrecision(_ date: Date) -> Date {
        let rounded = Date(timeIntervalSince1970: (date.timeIntervalSince1970 * 1000).rounded() / 1000)
        return Date.fromDatabaseValue(rounded.databaseValue) ?? rounded
    }

    private var writer: any DatabaseWriter { database.writer }

    // MARK: - Profiles

    /// Creates the profile together with its "Home" workspace.
    @discardableResult
    public func createProfile(name: String) throws -> Profile {
        try writer.write { db in try insertProfile(name: name, in: db) }
    }

    public func profiles() throws -> [Profile] {
        try writer.read { db in
            try Profile.order(Column("sortIndex"), Column("name")).fetchAll(db)
        }
    }

    /// Returns the first profile, creating "Personal" only when none exist.
    @discardableResult
    public func ensureDefaultProfile() throws -> Profile {
        try writer.write { db in try ensureDefaultProfile(in: db) }
    }

    func ensureDefaultProfile(in db: Database) throws -> Profile {
        if let existing = try Profile.order(Column("sortIndex")).fetchOne(db) { return existing }
        return try insertProfile(name: Self.defaultProfileName, in: db)
    }

    // MARK: - Workspaces

    @discardableResult
    public func createWorkspace(profileID: UUID, name: String, icon: String, colorHex: String) throws -> Workspace {
        try writer.write { db in
            guard try Profile.fetchOne(db, key: profileID) != nil else { throw StoreError.notFound }
            return try insertWorkspace(profileID: profileID, name: name, icon: icon, colorHex: colorHex, in: db)
        }
    }

    public func renameWorkspace(_ id: UUID, to name: String) throws {
        try writer.write { db in
            guard let workspace = try Workspace.fetchOne(db, key: id) else { throw StoreError.notFound }
            var renamed = workspace
            renamed.name = name
            renamed.modifiedAt = now()
            try renamed.update(db)
        }
    }

    public func workspaces(profileID: UUID) throws -> [Workspace] {
        try writer.read { db in try workspaces(profileID: profileID, in: db) }
    }

    func workspaces(profileID: UUID, in db: Database) throws -> [Workspace] {
        try Workspace
            .filter(Column("profileID") == profileID)
            .order(Column("sortIndex"), Column("name"))
            .fetchAll(db)
    }

    /// Archives every tab in the workspace (any section) and then deletes it, all in one transaction.
    /// The last workspace of a profile cannot be deleted.
    public func deleteWorkspace(_ id: UUID) throws {
        try writer.write { db in
            guard let workspace = try Workspace.fetchOne(db, key: id) else { throw StoreError.notFound }
            let siblings = try Workspace.filter(Column("profileID") == workspace.profileID).fetchCount(db)
            guard siblings > 1 else { throw StoreError.lastWorkspace }

            let stamp = now()
            let slots = try Slot.filter(Column("workspaceID") == id).fetchAll(db)
            let slotsByID = Dictionary(uniqueKeysWithValues: slots.map { ($0.id, $0) })
            let tabs = try Tab.filter(slots.map(\.id).contains(Column("slotID"))).order(Column("lastActiveAt")).fetchAll(db)
            for tab in tabs {
                guard let slot = slotsByID[tab.slotID] else { continue }
                try makeArchivedTab(slot: slot, tab: tab, closedAt: stamp).insert(db)
            }
            _ = try workspace.delete(db)
        }
    }

    // MARK: - Shared transaction helpers

    private func insertProfile(name: String, in db: Database) throws -> Profile {
        let stamp = now()
        let maxIndex = try Double.fetchOne(db, Profile.select(max(Column("sortIndex"))))
        let profile = Profile(name: name, sortIndex: (maxIndex ?? -1) + 1, modifiedAt: stamp)
        try profile.insert(db)
        _ = try insertWorkspace(
            profileID: profile.id, name: Self.homeWorkspaceName,
            icon: Self.homeWorkspaceIcon, colorHex: Self.homeWorkspaceColorHex, in: db
        )
        return profile
    }

    private func insertWorkspace(profileID: UUID, name: String, icon: String, colorHex: String, in db: Database) throws -> Workspace {
        let maxIndex = try Double.fetchOne(
            db, Workspace.filter(Column("profileID") == profileID).select(max(Column("sortIndex")))
        )
        let workspace = Workspace(
            profileID: profileID, name: name, icon: icon, colorHex: colorHex,
            sortIndex: (maxIndex ?? -1) + 1, modifiedAt: now()
        )
        try workspace.insert(db)
        return workspace
    }
}
