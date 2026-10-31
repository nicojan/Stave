import Foundation
import GRDB

/// A node of a workspace's pinned tree: a tab, or a folder with its children in order.
public enum PinnedItem: Sendable, Equatable {
    case tab(Tab)
    case folder(Folder, children: [PinnedItem])
}

extension OrganizationStore {
    // MARK: - Pinning

    /// Pins a regular tab (or re-files a pinned one) at the end of `folderID`, or of the workspace root when nil.
    /// Sets `pinnedURL`/`pinnedTitle`/`pinnedFaviconURL` from the current page unless already pinned.
    public func pinTab(_ id: UUID, folderID: UUID?) throws {
        try database.writer.write { db in
            var (tab, slot) = try fetchPair(id, in: db)
            guard slot.section != .essential, let workspaceID = slot.workspaceID else { throw StoreError.notFound }
            if let folderID {
                _ = try requireFolder(folderID, inWorkspace: workspaceID, in: db)
            }
            let stamp = now()
            slot.section = .pinned
            slot.folderID = folderID
            slot.sortIndex = try nextPinnedIndex(workspaceID: workspaceID, parentID: folderID, in: db)
            slot.modifiedAt = stamp
            try slot.update(db)
            tab.pinnedFaviconURL = tab.pinnedURL == nil ? tab.faviconURL : tab.pinnedFaviconURL
            tab.pinnedURL = tab.pinnedURL ?? tab.url
            tab.pinnedTitle = tab.pinnedTitle ?? tab.title
            tab.modifiedAt = stamp
            try tab.update(db)
        }
    }

    /// Turns a pinned tab back into a regular tab at the top of its workspace; clears the pinned page.
    public func unpinTab(_ id: UUID) throws {
        try database.writer.write { db in
            var (tab, slot) = try fetchPair(id, in: db)
            guard slot.section == .pinned, let workspaceID = slot.workspaceID,
                  let workspace = try Workspace.fetchOne(db, key: workspaceID) else { throw StoreError.notPinned }
            let stamp = now()
            slot.section = .regular
            slot.folderID = nil
            slot.sortIndex = try regularIndex(workspaceID: workspace.id, origin: .commandBar, edge: .top, in: db)
            slot.modifiedAt = stamp
            try slot.update(db)
            tab.pinnedURL = nil
            tab.pinnedTitle = nil
            tab.pinnedFaviconURL = nil
            tab.modifiedAt = stamp
            try tab.update(db)
        }
    }

    /// Sends a pinned tab or Essential back to its pinned page and icon, and drops its saved interaction state.
    public func resetPinnedTab(_ id: UUID) throws {
        try database.writer.write { db in
            var (tab, slot) = try fetchPair(id, in: db)
            guard slot.section != .regular, let pinnedURL = tab.pinnedURL else { throw StoreError.notPinned }
            tab.url = pinnedURL
            tab.title = tab.pinnedTitle ?? tab.title
            tab.faviconURL = tab.pinnedFaviconURL
            tab.interactionState = nil
            tab.modifiedAt = now()
            try tab.update(db)
        }
    }

    /// Archives the pinned tab, then deletes it.
    public func removePinnedTab(_ id: UUID) throws {
        try removeAndArchive(id, from: .pinned)
    }

    public func isDrifted(_ tab: Tab) -> Bool {
        tab.pinnedURL != nil && tab.url != tab.pinnedURL
    }

    // MARK: - Essentials

    /// Moves a pinned or regular tab into the profile's Essentials, last. It keeps its id and state.
    public func makeEssential(_ id: UUID) throws {
        try database.writer.write { db in
            var (tab, slot) = try fetchPair(id, in: db)
            guard slot.section != .essential else { return }
            let siblings = try essentialSlots(profileID: slot.profileID, in: db)
            let stamp = now()
            slot.section = .essential
            slot.workspaceID = nil
            slot.folderID = nil
            slot.sortIndex = (siblings.map(\.sortIndex).max() ?? -1) + 1
            slot.modifiedAt = stamp
            try slot.update(db)
            tab.pinnedFaviconURL = tab.pinnedURL == nil ? tab.faviconURL : tab.pinnedFaviconURL
            tab.pinnedURL = tab.pinnedURL ?? tab.url
            tab.pinnedTitle = tab.pinnedTitle ?? tab.title
            tab.modifiedAt = stamp
            try tab.update(db)
        }
    }

    /// Archives the Essential, then deletes it.
    public func removeEssential(_ id: UUID) throws {
        try removeAndArchive(id, from: .essential)
    }

    public func essentials(profileID: UUID) throws -> [Tab] {
        try database.writer.read { db in try essentials(profileID: profileID, in: db) }
    }

    func essentials(profileID: UUID, in db: Database) throws -> [Tab] {
        let slots = try essentialSlots(profileID: profileID, in: db)
        let bySlot = try tabsBySlot(slots, in: db)
        return slots.compactMap { bySlot[$0.id] }
    }

    /// The workspace's pinned tree: root folders and root tabs interleaved by sort index, folders carrying their children.
    public func pinnedItems(workspaceID: UUID) throws -> [PinnedItem] {
        try database.writer.read { db in try pinnedItems(workspaceID: workspaceID, in: db) }
    }

    func pinnedItems(workspaceID: UUID, in db: Database) throws -> [PinnedItem] {
        try pinnedTree(workspaceID: workspaceID, parentID: nil, in: db)
    }

    // MARK: - Helpers

    func fetchPair(_ id: UUID, in db: Database) throws -> (Tab, Slot) {
        guard let tab = try Tab.fetchOne(db, key: id),
              let slot = try Slot.fetchOne(db, key: tab.slotID) else { throw StoreError.notFound }
        return (tab, slot)
    }

    /// One tab per slot, shared by every read path. A split slot holds several tabs, so the first by `rowid` stands for it.
    func tabsBySlot(_ slots: [Slot], in db: Database) throws -> [UUID: Tab] {
        let tabs = try Tab.filter(slots.map(\.id).contains(Column("slotID"))).order(Column("rowid")).fetchAll(db)
        return Dictionary(tabs.map { ($0.slotID, $0) }, uniquingKeysWith: { first, _ in first })
    }

    /// Folders and pinned slots directly under `parentID` (nil = root), in one ordering space.
    func pinnedChildren(workspaceID: UUID, parentID: UUID?, in db: Database) throws -> [Child] {
        let folders = try Folder
            .filter(Column("workspaceID") == workspaceID && Column("parentFolderID") == parentID)
            .order(Column("sortIndex"), Column("rowid")).fetchAll(db)
        let slots = try Slot
            .filter(Column("workspaceID") == workspaceID && Column("section") == SlotSection.pinned.rawValue
                && Column("folderID") == parentID)
            .order(Column("sortIndex"), Column("rowid")).fetchAll(db)
        let merged = folders.map(Child.folder) + slots.map(Child.slot)
        return merged.enumerated()
            .sorted { ($0.element.sortIndex, $0.offset) < ($1.element.sortIndex, $1.offset) }
            .map(\.element)
    }

    func nextPinnedIndex(workspaceID: UUID, parentID: UUID?, in db: Database) throws -> Double {
        (try pinnedChildren(workspaceID: workspaceID, parentID: parentID, in: db).map(\.sortIndex).max() ?? -1) + 1
    }

    private func pinnedTree(workspaceID: UUID, parentID: UUID?, in db: Database) throws -> [PinnedItem] {
        let children = try pinnedChildren(workspaceID: workspaceID, parentID: parentID, in: db)
        let slots = children.compactMap { child -> Slot? in
            if case .slot(let slot) = child { slot } else { nil }
        }
        let bySlot = try tabsBySlot(slots, in: db)
        return try children.compactMap { child in
            switch child {
            case .slot(let slot):
                return bySlot[slot.id].map(PinnedItem.tab)
            case .folder(let folder):
                return .folder(folder, children: try pinnedTree(workspaceID: workspaceID, parentID: folder.id, in: db))
            }
        }
    }

    private func removeAndArchive(_ id: UUID, from section: SlotSection) throws {
        try database.writer.write { db in
            let (tab, slot) = try fetchPair(id, in: db)
            guard slot.section == section else { throw StoreError.notPinned }
            try makeArchivedTab(slot: slot, tab: tab, closedAt: now()).insert(db)
            _ = try slot.delete(db) // the tab row goes with it (ON DELETE CASCADE)
        }
    }
}
