import Foundation
import GRDB

/// What closing a tab did. `.archived` carries the new `ArchivedTab`'s id; `.unloaded` means a pinned or essential tab was only unloaded.
public enum CloseResult: Sendable, Equatable { case archived(UUID), unloaded }

extension OrganizationStore {
    static let secondsPerDay: TimeInterval = 86_400
    /// Below this gap between neighbouring sort indices the workspace's regular slots are renumbered.
    static let minimumIndexGap = 1e-9

    // MARK: - Opening

    /// Creates the slot and the tab in one transaction, placed by `TabPlacement`.
    public func openTab(
        url: String, title: String, workspaceID: UUID, origin: NewTabOrigin,
        containerID: UUID?, edge: NewTabEdge
    ) throws -> Tab {
        try database.writer.write { db in
            guard let workspace = try Workspace.fetchOne(db, key: workspaceID) else { throw StoreError.notFound }
            if let containerID {
                guard let container = try Container.fetchOne(db, key: containerID) else { throw StoreError.notFound }
                guard container.profileID == workspace.profileID else { throw StoreError.crossProfileMove }
            }
            return try insertRegularTab(
                url: url, title: title, workspace: workspace, origin: origin,
                containerID: containerID, edge: edge, faviconURL: nil, interactionState: nil, in: db
            )
        }
    }

    // MARK: - Updating

    /// Update-only: a write for a closed tab throws `.notFound` and never re-creates it.
    public func updateNavigation(tabID: UUID, url: String, title: String, faviconURL: String?, interactionState: Data?) throws {
        try database.writer.write { db in
            guard var tab = try Tab.fetchOne(db, key: tabID) else { throw StoreError.notFound }
            tab.url = url
            tab.title = title
            tab.faviconURL = faviconURL
            tab.interactionState = interactionState
            tab.modifiedAt = now()
            try tab.update(db)
        }
    }

    public func markActive(tabID: UUID) throws {
        try database.writer.write { db in
            guard var tab = try Tab.fetchOne(db, key: tabID) else { throw StoreError.notFound }
            let stamp = now()
            tab.lastActiveAt = stamp
            tab.modifiedAt = stamp
            try tab.update(db)
        }
    }

    // MARK: - Closing and the archive

    /// Regular tabs are archived and their slot deleted in one transaction. Pinned and essential tabs are left untouched (`.unloaded`).
    public func closeTab(_ id: UUID) throws -> CloseResult {
        try database.writer.write { db in
            guard let tab = try Tab.fetchOne(db, key: id),
                  let slot = try Slot.fetchOne(db, key: tab.slotID) else { throw StoreError.notFound }
            guard slot.section == .regular else { return .unloaded }
            let archived = makeArchivedTab(slot: slot, tab: tab, closedAt: now())
            try archived.insert(db)
            _ = try slot.delete(db) // the tab row goes with it (ON DELETE CASCADE)
            return .archived(archived.id)
        }
    }

    /// Newest first by `closedAt`; rows archived together share a `closedAt`, so ties break on `rowid` descending (later-inserted first).
    public func archivedTabs(profileID: UUID) throws -> [ArchivedTab] {
        try database.writer.read { db in
            try ArchivedTab
                .filter(Column("profileID") == profileID)
                .order(Column("closedAt").desc, Column("rowid").desc)
                .fetchAll(db)
        }
    }

    /// Moves the archived tab back into the workspace at the top (the `.commandBar` rule), keeping its container and interaction state.
    public func restoreArchivedTab(_ id: UUID, workspaceID: UUID) throws -> Tab {
        try database.writer.write { db in
            guard let archived = try ArchivedTab.fetchOne(db, key: id),
                  let workspace = try Workspace.fetchOne(db, key: workspaceID) else { throw StoreError.notFound }
            guard archived.profileID == workspace.profileID else { throw StoreError.crossProfileMove }
            // A container that no longer exists is left to Task 8 (R12); one that exists must be this profile's.
            if let containerID = archived.containerID,
               let container = try Container.fetchOne(db, key: containerID),
               container.profileID != workspace.profileID { throw StoreError.crossProfileMove }
            let tab = try insertRegularTab(
                url: archived.url, title: archived.title, workspace: workspace, origin: .commandBar,
                containerID: archived.containerID, edge: .top,
                faviconURL: archived.faviconURL, interactionState: archived.interactionState, in: db
            )
            _ = try archived.delete(db)
            return tab
        }
    }

    /// Removes archive rows closed before `now()` minus `days` days. Returns the number removed.
    @discardableResult
    public func trimArchive(olderThan days: Int = 30) throws -> Int {
        let cutoff = now().addingTimeInterval(-Double(days) * Self.secondsPerDay)
        return try database.writer.write { db in
            try ArchivedTab.filter(Column("closedAt") < cutoff).deleteAll(db)
        }
    }

    // MARK: - Reading

    public func regularTabs(workspaceID: UUID) throws -> [Tab] {
        try database.writer.read { db in
            let slots = try regularSlots(workspaceID: workspaceID, in: db)
            let tabs = try Tab.filter(slots.map(\.id).contains(Column("slotID"))).fetchAll(db)
            let bySlot = Dictionary(uniqueKeysWithValues: tabs.map { ($0.slotID, $0) })
            return slots.compactMap { bySlot[$0.id] }
        }
    }

    /// The title, or the URL's host when the title is empty, or the URL itself.
    public func displayTitle(for tab: Tab) -> String {
        guard tab.title.isEmpty else { return tab.title }
        if let host = URL(string: tab.url)?.host, !host.isEmpty { return host }
        return tab.url
    }

    // MARK: - Helpers

    /// The archive row for a closing tab (shared by `closeTab`, `removePinnedTab` and `removeEssential`). Not inserted.
    func makeArchivedTab(slot: Slot, tab: Tab, closedAt: Date) -> ArchivedTab {
        ArchivedTab(
            profileID: slot.profileID, workspaceID: slot.workspaceID,
            url: tab.url, title: tab.title, faviconURL: tab.faviconURL,
            interactionState: tab.interactionState, containerID: tab.containerID,
            closedAt: closedAt, modifiedAt: closedAt
        )
    }

    /// The sort index for a new regular slot in the workspace by `origin` and `edge`, renumbering first if crowded (R10).
    func regularIndex(workspaceID: UUID, origin: NewTabOrigin, edge: NewTabEdge, in db: Database) throws -> Double {
        var slots = try regularSlots(workspaceID: workspaceID, in: db)
        var index = try placementIndex(slots: slots, origin: origin, edge: edge, in: db)
        if isCrowded(index, among: slots.map(\.sortIndex)) {
            slots = try renumber(slots, in: db)
            index = try placementIndex(slots: slots, origin: origin, edge: edge, in: db)
        }
        return index
    }

    private func regularSlots(workspaceID: UUID, in db: Database) throws -> [Slot] {
        try Slot
            .filter(Column("workspaceID") == workspaceID && Column("section") == SlotSection.regular.rawValue)
            .order(Column("sortIndex"), Column("rowid"))
            .fetchAll(db)
    }

    private func insertRegularTab(
        url: String, title: String, workspace: Workspace, origin: NewTabOrigin,
        containerID: UUID?, edge: NewTabEdge, faviconURL: String?, interactionState: Data?, in db: Database
    ) throws -> Tab {
        let index = try regularIndex(workspaceID: workspace.id, origin: origin, edge: edge, in: db)
        let stamp = now()
        let slot = Slot(
            profileID: workspace.profileID, workspaceID: workspace.id, section: .regular,
            kind: .tab, sortIndex: index, modifiedAt: stamp
        )
        try slot.insert(db)
        let tab = Tab(
            slotID: slot.id, containerID: containerID, url: url, title: title,
            faviconURL: faviconURL, interactionState: interactionState, lastActiveAt: stamp, modifiedAt: stamp
        )
        try tab.insert(db)
        return tab
    }

    private func placementIndex(slots: [Slot], origin: NewTabOrigin, edge: NewTabEdge, in db: Database) throws -> Double {
        let tabs = try Tab.filter(slots.map(\.id).contains(Column("slotID"))).fetchAll(db)
        let indexBySlot = Dictionary(uniqueKeysWithValues: slots.map { ($0.id, $0.sortIndex) })
        let indices = Dictionary(uniqueKeysWithValues: tabs.compactMap { tab in
            indexBySlot[tab.slotID].map { (tab.id, $0) }
        })
        return TabPlacement.sortIndex(origin: origin, regularIndices: indices, edge: edge)
    }

    /// True when `index` is not strictly between its neighbours, or is within `minimumIndexGap` of either.
    private func isCrowded(_ index: Double, among existing: [Double]) -> Bool {
        let below = existing.filter { $0 <= index }.max()
        let above = existing.filter { $0 >= index }.min()
        // Equal to a neighbour is a zero gap, so the gap checks below cover it; a collapsed double lands here.
        if let below, index - below < Self.minimumIndexGap { return true }
        if let above, above - index < Self.minimumIndexGap { return true }
        return !index.isFinite
    }

    /// Rewrites the slots' indices to 0, 1, 2… in their current order.
    private func renumber(_ slots: [Slot], in db: Database) throws -> [Slot] {
        let stamp = now()
        return try slots.enumerated().map { position, slot in
            var renumbered = slot
            renumbered.sortIndex = Double(position)
            renumbered.modifiedAt = stamp
            try renumbered.update(db)
            return renumbered
        }
    }
}
