import Foundation
import GRDB

extension OrganizationStore {
    // MARK: - Containers

    /// Creates a named container with a fresh `dataStoreID` (distinct from its `id`).
    @discardableResult
    public func createContainer(profileID: UUID, name: String, colorHex: String) throws -> Container {
        try database.writer.write { db in
            guard try Profile.fetchOne(db, key: profileID) != nil else { throw StoreError.notFound }
            let container = Container(profileID: profileID, name: name, colorHex: colorHex, modifiedAt: now())
            try container.insert(db)
            return container
        }
    }

    /// Ordered by name, then by creation (`rowid`) so equal names stay stable.
    public func containers(profileID: UUID) throws -> [Container] {
        try database.writer.read { db in
            try Container
                .filter(Column("profileID") == profileID)
                .order(Column("name"), Column("rowid"))
                .fetchAll(db)
        }
    }

    /// Refused with `.containerInUse` while any open tab (any section) or archived tab references the container,
    /// so restoring an archived tab can never land in the wrong data store. Returns the `dataStoreID` the caller must remove.
    public func deleteContainer(_ id: UUID) throws -> UUID {
        try database.writer.write { db in
            guard let container = try Container.fetchOne(db, key: id) else { throw StoreError.notFound }
            let openTabs = try Tab.filter(Column("containerID") == id).fetchCount(db)
            let archivedTabs = try ArchivedTab.filter(Column("containerID") == id).fetchCount(db)
            guard openTabs == 0, archivedTabs == 0 else { throw StoreError.containerInUse }
            _ = try container.delete(db)
            return container.dataStoreID
        }
    }

    // MARK: - Profile deletion

    /// Deletes the profile and, by cascade, its workspaces, slots, tabs, folders, containers, archive and window states.
    /// Nothing is archived: this is the confirmed-deletion exception. Returns the profile's own `dataStoreID` first,
    /// then its containers' (name, creation order) for the web layer to remove. The last profile cannot be deleted.
    public func deleteProfile(_ id: UUID) throws -> [UUID] {
        try database.writer.write { db in
            guard let profile = try Profile.fetchOne(db, key: id) else { throw StoreError.notFound }
            guard try Profile.fetchCount(db) > 1 else { throw StoreError.lastProfile }
            let containerStores = try Container
                .filter(Column("profileID") == id)
                .order(Column("name"), Column("rowid"))
                .fetchAll(db)
                .map(\.dataStoreID)
            _ = try profile.delete(db)
            return [profile.dataStoreID] + containerStores
        }
    }
}
