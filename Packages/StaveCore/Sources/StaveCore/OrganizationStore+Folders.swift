import Foundation
import GRDB

extension OrganizationStore {
    /// Folders nest at most one level: a parent that is itself nested throws `.folderTooDeep`.
    @discardableResult
    public func createFolder(workspaceID: UUID, parentFolderID: UUID?, title: String) throws -> Folder {
        try database.writer.write { db in
            guard try Workspace.fetchOne(db, key: workspaceID) != nil else { throw StoreError.notFound }
            if let parentFolderID {
                let parent = try requireFolder(parentFolderID, inWorkspace: workspaceID, in: db)
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

    /// Moves a folder to another parent (nil = root) of the same workspace, directly after `anchor` there (nil = first).
    /// Throws `.folderTooDeep` for a nested target parent, a folder with sub-folders going under a parent, or a folder into itself;
    /// `.notFound` for a parent of another workspace or an anchor that is not among the target's children. Nothing changes on a refusal.
    public func moveFolder(_ id: UUID, toParent parentFolderID: UUID?, after anchor: MoveAnchor?) throws {
        try database.writer.write { db in
            guard var folder = try Folder.fetchOne(db, key: id) else { throw StoreError.notFound }
            if let parentFolderID {
                guard parentFolderID != id else { throw StoreError.folderTooDeep }
                let parent = try requireFolder(parentFolderID, inWorkspace: folder.workspaceID, in: db)
                guard parent.parentFolderID == nil else { throw StoreError.folderTooDeep }
                let hasSubfolders = try Folder.filter(Column("parentFolderID") == id).fetchCount(db) > 0
                guard !hasSubfolders else { throw StoreError.folderTooDeep }
            }
            let workspaceID = folder.workspaceID
            let siblings = {
                try self.pinnedChildren(workspaceID: workspaceID, parentID: parentFolderID, in: db)
                    .filter { if case .folder(let other) = $0 { other.id != id } else { true } }
            }
            folder.sortIndex = try uncrowdedIndex(
                siblings: siblings, propose: { try indexAfter(anchor, in: $0, in: db) }, in: db
            )
            folder.parentFolderID = parentFolderID
            folder.modifiedAt = now()
            try folder.update(db)
        }
    }

    public func setFolderOpen(_ id: UUID, _ isOpen: Bool) throws {
        try editFolder(id) { $0.isOpen = isOpen }
    }

    public func renameFolder(_ id: UUID, to title: String) throws {
        try editFolder(id) { $0.title = title }
    }

    private func editFolder(_ id: UUID, _ change: (inout Folder) -> Void) throws {
        try database.writer.write { db in
            guard var folder = try Folder.fetchOne(db, key: id) else { throw StoreError.notFound }
            change(&folder)
            folder.modifiedAt = now()
            try folder.update(db)
        }
    }
}
