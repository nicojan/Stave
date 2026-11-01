import Foundation
import GRDB

extension OrganizationStore {
    // MARK: - Site settings

    public func siteDecision(profileID: UUID, host: String, key: SiteSettingKey) throws -> SiteDecision? {
        try database.writer.read { db in
            try SiteSetting
                .filter(Column("profileID") == profileID && Column("host") == host && Column("key") == key.rawValue)
                .fetchOne(db)?.decision
        }
    }

    /// Nil removes the row. A saved setting is not user data, so removing one needs no archive.
    public func setSiteDecision(profileID: UUID, host: String, key: SiteSettingKey, _ decision: SiteDecision?) throws {
        let stamp = now()
        try database.writer.write { db in
            let existing = try SiteSetting
                .filter(Column("profileID") == profileID && Column("host") == host && Column("key") == key.rawValue)
                .fetchOne(db)
            guard let decision else {
                _ = try existing?.delete(db)
                return
            }
            guard try Profile.fetchOne(db, key: profileID) != nil else { throw StoreError.notFound }
            var row = existing ?? SiteSetting(profileID: profileID, host: host, key: key, decision: decision, modifiedAt: stamp)
            row.decision = decision
            row.modifiedAt = stamp
            try row.save(db)
        }
    }

    // MARK: - Tab state

    /// Update-only: a write for a closed tab throws `.notFound` and never re-creates it. Touches nothing but the state and `modifiedAt`.
    public func updateInteractionState(tabID: UUID, _ state: Data?) throws {
        let stamp = now()
        try database.writer.write { db in
            guard var tab = try Tab.fetchOne(db, key: tabID) else { throw StoreError.notFound }
            tab.interactionState = state
            tab.modifiedAt = stamp
            try tab.update(db)
        }
    }

    /// The container's data store when the tab has a container, else its profile's (an Essential's profile comes from its slot).
    public func dataStoreID(forTab id: UUID) throws -> UUID {
        try database.writer.read { db in
            guard let tab = try Tab.fetchOne(db, key: id) else { throw StoreError.notFound }
            if let containerID = tab.containerID {
                guard let container = try Container.fetchOne(db, key: containerID) else { throw StoreError.notFound }
                return container.dataStoreID
            }
            guard let slot = try Slot.fetchOne(db, key: tab.slotID),
                  let profile = try Profile.fetchOne(db, key: slot.profileID) else { throw StoreError.notFound }
            return profile.dataStoreID
        }
    }

    /// The profile the tab belongs to (through its slot).
    public func profileID(forTab id: UUID) throws -> UUID {
        try database.writer.read { db in
            guard let tab = try Tab.fetchOne(db, key: id), let slot = try Slot.fetchOne(db, key: tab.slotID) else { throw StoreError.notFound }
            return slot.profileID
        }
    }
}
