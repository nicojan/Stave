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

    /// Edits a container's name and colour. A blank name (once trimmed) throws `.blankName`. The colour is checked with the workspace editor's
    /// palette and its `allowingColorHex` rule, so editing only the name never refuses a colour the container already has (an imported
    /// one), while any other colour outside the palette throws `.invalidColour`. There is no second container palette.
    @discardableResult
    public func updateContainer(_ id: UUID, name: String, colorHex: String) throws -> Container {
        guard !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw StoreError.blankName }
        return try database.writer.write { db in
            guard var container = try Container.fetchOne(db, key: id) else { throw StoreError.notFound }
            guard let draft = WorkspaceEditorRules.validate(name: name, icon: "", colorHex: colorHex, allowingColorHex: container.colorHex) else {
                throw StoreError.invalidColour
            }
            container.name = draft.name
            container.colorHex = draft.colorHex
            container.modifiedAt = now()
            try container.update(db)
            return container
        }
    }

    /// How many open tabs (any section) and archived tabs use the container; deletion is refused while either is above zero.
    public func containerUsage(_ id: UUID) throws -> (open: Int, archived: Int) {
        try database.writer.read { db in
            guard try Container.fetchOne(db, key: id) != nil else { throw StoreError.notFound }
            return (
                open: try Tab.filter(Column("containerID") == id).fetchCount(db),
                archived: try ArchivedTab.filter(Column("containerID") == id).fetchCount(db)
            )
        }
    }

    /// What deleting the profile removes, for the question that asks first: its workspaces, open tabs, archived tabs and history visits.
    public func profileSummary(_ id: UUID) throws -> ProfileSummary {
        try database.writer.read { db in
            guard try Profile.fetchOne(db, key: id) != nil else { throw StoreError.notFound }
            let tabs = try Int.fetchOne(
                db, sql: "SELECT COUNT(*) FROM tab JOIN slot ON slot.id = tab.slotID WHERE slot.profileID = ?", arguments: [id]
            ) ?? 0
            return ProfileSummary(
                workspaces: try Workspace.filter(Column("profileID") == id).fetchCount(db),
                tabs: tabs,
                archived: try ArchivedTab.filter(Column("profileID") == id).fetchCount(db),
                history: try HistoryVisit.filter(Column("profileID") == id).fetchCount(db)
            )
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
            try Self.recordPendingStores([container.dataStoreID], in: db, at: now())
            return container.dataStoreID
        }
    }

    /// The persistent website data stores of a profile: its own first, then its containers' (name, creation order), whether or not a
    /// window has opened them. Clear History's "Also remove cookies and website data" empties exactly these; another profile's stores and a
    /// private session's (which has no row) are never listed.
    public func websiteDataStoreIDs(profileID: UUID) throws -> [UUID] {
        try database.writer.read { db in
            guard let profile = try Profile.fetchOne(db, key: profileID) else { throw StoreError.notFound }
            return [profile.dataStoreID] + (try Self.containerStoreIDs(profileID: profileID, in: db))
        }
    }

    private static func containerStoreIDs(profileID: UUID, in db: Database) throws -> [UUID] {
        try Container
            .filter(Column("profileID") == profileID)
            .order(Column("name"), Column("rowid"))
            .fetchAll(db)
            .map(\.dataStoreID)
    }

    // MARK: - Profile deletion

    /// Deletes the profile and, by cascade, its workspaces, slots, tabs, folders, containers, archive and window states.
    /// Nothing is archived: this is the confirmed-deletion exception. Returns the profile's own `dataStoreID` first,
    /// then its containers' (name, creation order) for the web layer to remove. The last profile cannot be deleted.
    public func deleteProfile(_ id: UUID) throws -> [UUID] {
        try database.writer.write { db in
            guard let profile = try Profile.fetchOne(db, key: id) else { throw StoreError.notFound }
            guard try Profile.fetchCount(db) > 1 else { throw StoreError.lastProfile }
            let containerStores = try Self.containerStoreIDs(profileID: id, in: db)
            _ = try profile.delete(db)
            try Self.recordPendingStores([profile.dataStoreID] + containerStores, in: db, at: now())
            // A link from another app must never be aimed at a profile that is gone.
            try resetExternalLinkTarget(in: db) { target in
                if case .workspace(let profileID, _) = target { return profileID == id }
                return false
            }
            return [profile.dataStoreID] + containerStores
        }
    }

    // MARK: - Pending store removals

    /// The website data stores of deleted profiles and containers that still wait to be removed from disk, oldest first.
    public func pendingStoreRemovals() throws -> [UUID] {
        try setting(SettingKeys.pendingStoreRemovals)
    }

    /// Stores whose removal WebKit reported as done and that wait for the next launch to confirm it (R2-H1), oldest first.
    public func storesToVerify() throws -> [UUID] {
        try setting(SettingKeys.storeRemovalsToVerify)
    }

    /// Moves stores whose removal succeeded from pending to "to verify" in one transaction: a success WebKit reports is not yet an end state
    /// (a late cookie flush can recreate files), so the ID is forgotten only by `storesVerified`. Others stay pending. Called after each
    /// removal succeeds, never before.
    public func storesRemoved(_ ids: [UUID]) throws {
        guard !ids.isEmpty else { return }
        let gone = Set(ids)
        let stamp = now()
        try database.writer.write { db in
            let kept = try Self.storedIDs(SettingKeys.pendingStoreRemovals, in: db).filter { !gone.contains($0) }
            try Self.upsert(db, key: SettingKeys.pendingStoreRemovals.name, text: try Self.encoded(kept), at: stamp)
            try Self.upsert(db, key: SettingKeys.storeRemovalsToVerify.name, text: try Self.encoded(try Self.merged(SettingKeys.storeRemovalsToVerify, adding: ids, in: db)), at: stamp)
        }
    }

    /// The launch check's outcome, in one transaction. Only IDs on the "to verify" list are looked at: `clear` are forgotten (the listing no
    /// longer has them), `again` go back to pending to be removed once more. IDs not on the list are ignored.
    public func storesVerified(clear: [UUID], again: [UUID]) throws {
        let stamp = now()
        try database.writer.write { db in
            let recorded = try Self.storedIDs(SettingKeys.storeRemovalsToVerify, in: db)
            let decided = Set(clear + again)
            let kept = recorded.filter { !decided.contains($0) }
            try Self.upsert(db, key: SettingKeys.storeRemovalsToVerify.name, text: try Self.encoded(kept), at: stamp)
            let requeue = again.filter(recorded.contains)
            guard !requeue.isEmpty else { return }
            try Self.upsert(db, key: SettingKeys.pendingStoreRemovals.name, text: try Self.encoded(try Self.merged(SettingKeys.pendingStoreRemovals, adding: requeue, in: db)), at: stamp)
        }
    }

    /// A stored ID list. Text that can't be decoded is never overwritten: it is copied to `<key>.unreadable` (kept if a copy is already
    /// there) and logged, and the list starts again from empty (R1-L3).
    private static func storedIDs(_ key: SettingKey<[UUID]>, in db: Database) throws -> [UUID] {
        guard let text = try String.fetchOne(db, sql: "SELECT value FROM setting WHERE key = ?", arguments: [key.name]) else { return [] }
        if let ids = try? JSONDecoder().decode([UUID].self, from: Data(text.utf8)) { return ids }
        NSLog("Stave: the list \(key.name) can't be read; keeping it as \(key.name).unreadable")
        try db.execute(
            sql: "INSERT INTO setting (key, value, modifiedAt) VALUES (?, ?, ?) ON CONFLICT(key) DO NOTHING",
            arguments: ["\(key.name).unreadable", text, Date()]
        )
        return []
    }

    private static func merged(_ key: SettingKey<[UUID]>, adding ids: [UUID], in db: Database) throws -> [UUID] {
        let existing = try storedIDs(key, in: db)
        return existing + ids.filter { !existing.contains($0) }
    }

    /// Adds the IDs to the pending list inside the caller's transaction, so the rows and the promise to remove their stores land together.
    private static func recordPendingStores(_ ids: [UUID], in db: Database, at stamp: Date) throws {
        try upsert(db, key: SettingKeys.pendingStoreRemovals.name, text: try encoded(try merged(SettingKeys.pendingStoreRemovals, adding: ids, in: db)), at: stamp)
    }

    /// Sets `externalLinkTarget` back to `.lastUsed` when its stored value satisfies `names`. Runs inside the caller's transaction, so the
    /// deletion and the reset land together.
    func resetExternalLinkTarget(in db: Database, where names: (ExternalLinkTarget) -> Bool) throws {
        let key = SettingKeys.externalLinkTarget
        guard let text = try String.fetchOne(db, sql: "SELECT value FROM setting WHERE key = ?", arguments: [key.name]),
              let target = try? JSONDecoder().decode(ExternalLinkTarget.self, from: Data(text.utf8)), names(target) else { return }
        try Self.upsert(db, key: key.name, text: try Self.encoded(ExternalLinkTarget.lastUsed), at: now())
    }
}
