import Foundation
import GRDB

/// Sibling ordering shared by every store file: one child type, one renumber, one crowded-index loop and the lookups several writers repeat.
extension OrganizationStore {
    /// A folder or a slot, which share one ordering space under a pinned parent.
    enum Child {
        case folder(Folder), slot(Slot)
        var sortIndex: Double {
            switch self {
            case .folder(let folder): folder.sortIndex
            case .slot(let slot): slot.sortIndex
            }
        }
    }

    /// Rewrites the children's indices to 0, 1, 2… in their current order (folders and slots alike) and returns them as written.
    @discardableResult
    func renumber(_ children: [Child], in db: Database) throws -> [Child] {
        let stamp = now()
        return try children.enumerated().map { position, child in
            switch child {
            case .folder(var folder):
                folder.sortIndex = Double(position)
                folder.modifiedAt = stamp
                try folder.update(db)
                return .folder(folder)
            case .slot(var slot):
                slot.sortIndex = Double(position)
                slot.modifiedAt = stamp
                try slot.update(db)
                return .slot(slot)
            }
        }
    }

    /// Proposes an index among the siblings; a crowded result (R10) renumbers them 0, 1, 2… and proposes again on the fresh list.
    func uncrowdedIndex(
        siblings: () throws -> [Child], propose: ([Child]) throws -> Double, in db: Database
    ) throws -> Double {
        var list = try siblings()
        var index = try propose(list)
        if isCrowded(index, among: list.map(\.sortIndex)) {
            try renumber(list, in: db)
            list = try siblings()
            index = try propose(list)
        }
        return index
    }

    /// The profile's Essentials slots in stored order.
    func essentialSlots(profileID: UUID, in db: Database) throws -> [Slot] {
        try Slot
            .filter(Column("profileID") == profileID && Column("section") == SlotSection.essential.rawValue)
            .order(Column("sortIndex"), Column("rowid"))
            .fetchAll(db)
    }

    /// The folder, which must belong to the workspace; otherwise `.notFound`.
    func requireFolder(_ id: UUID, inWorkspace workspaceID: UUID, in db: Database) throws -> Folder {
        guard let folder = try Folder.fetchOne(db, key: id), folder.workspaceID == workspaceID else { throw StoreError.notFound }
        return folder
    }
}

extension OrganizationStore.Child {
    var slot: Slot? { if case .slot(let slot) = self { slot } else { nil } }
}
