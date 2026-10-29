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
                guard let folder = try Folder.fetchOne(db, key: folderID),
                      folder.workspaceID == workspaceID else { throw StoreError.notFound }
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
            let siblings = try Slot
                .filter(Column("profileID") == slot.profileID && Column("section") == SlotSection.essential.rawValue)
                .fetchAll(db)
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
        let slots = try Slot
            .filter(Column("profileID") == profileID && Column("section") == SlotSection.essential.rawValue)
            .order(Column("sortIndex"), Column("rowid"))
            .fetchAll(db)
        let bySlot = try tabsBySlot(slots, in: db)
        return slots.compactMap { bySlot[$0.id] }
    }

    // MARK: - Folders

    /// Folders nest at most one level: a parent that is itself nested throws `.folderTooDeep`.
    @discardableResult
    public func createFolder(workspaceID: UUID, parentFolderID: UUID?, title: String) throws -> Folder {
        try database.writer.write { db in
            guard try Workspace.fetchOne(db, key: workspaceID) != nil else { throw StoreError.notFound }
            if let parentFolderID {
                guard let parent = try Folder.fetchOne(db, key: parentFolderID),
                      parent.workspaceID == workspaceID else { throw StoreError.notFound }
                guard parent.parentFolderID == nil else { throw StoreError.folderTooDeep }
            }
            let folder = Folder(
                workspaceID: workspaceID, parentFolderID: parentFolderID, title: title,
                sortIndex: try nextPinnedIndex(workspaceID: workspaceID, parentID: parentFolderID, in: db),
                modifiedAt: now()
            )
            try folder.insert(db)
            return folder
        }
    }

    /// Deletes the folder but keeps its contents: child tabs and sub-folders move to the folder's parent (root for a
    /// top-level folder), in their existing order, starting at the deleted folder's position. Nothing is archived.
    public func deleteFolder(_ id: UUID) throws {
        try database.writer.write { db in
            guard let folder = try Folder.fetchOne(db, key: id) else { throw StoreError.notFound }
            let children = try pinnedChildren(workspaceID: folder.workspaceID, parentID: id, in: db)
            let siblings = try pinnedChildren(workspaceID: folder.workspaceID, parentID: folder.parentFolderID, in: db)
            let next = siblings.map(\.sortIndex).filter { $0 > folder.sortIndex }.min()
            let gap = (next ?? folder.sortIndex + Double(children.count)) - folder.sortIndex
            let stamp = now()
            for (position, child) in children.enumerated() {
                let index = folder.sortIndex + gap * Double(position) / Double(children.count)
                switch child {
                case .folder(var sub):
                    sub.parentFolderID = folder.parentFolderID
                    sub.sortIndex = index
                    sub.modifiedAt = stamp
                    try sub.update(db)
                case .slot(var slot):
                    slot.folderID = folder.parentFolderID
                    slot.sortIndex = index
                    slot.modifiedAt = stamp
                    try slot.update(db)
                }
            }
            _ = try folder.delete(db)
        }
    }

    /// The workspace's pinned tree: root folders and root tabs interleaved by sort index, folders carrying their children.
    public func pinnedItems(workspaceID: UUID) throws -> [PinnedItem] {
        try database.writer.read { db in try pinnedItems(workspaceID: workspaceID, in: db) }
    }

    func pinnedItems(workspaceID: UUID, in db: Database) throws -> [PinnedItem] {
        try pinnedTree(workspaceID: workspaceID, parentID: nil, in: db)
    }

    // MARK: - Helpers

    enum Child {
        case folder(Folder), slot(Slot)
        var sortIndex: Double {
            switch self {
            case .folder(let folder): folder.sortIndex
            case .slot(let slot): slot.sortIndex
            }
        }
    }

    func fetchPair(_ id: UUID, in db: Database) throws -> (Tab, Slot) {
        guard let tab = try Tab.fetchOne(db, key: id),
              let slot = try Slot.fetchOne(db, key: tab.slotID) else { throw StoreError.notFound }
        return (tab, slot)
    }

    func tabsBySlot(_ slots: [Slot], in db: Database) throws -> [UUID: Tab] {
        let tabs = try Tab.filter(slots.map(\.id).contains(Column("slotID"))).fetchAll(db)
        return Dictionary(uniqueKeysWithValues: tabs.map { ($0.slotID, $0) })
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

    private func nextPinnedIndex(workspaceID: UUID, parentID: UUID?, in db: Database) throws -> Double {
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
