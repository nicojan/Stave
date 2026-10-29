import Foundation
import GRDB

extension OrganizationStore {
    /// Moves a tab to a new place, directly after `previousTabID` in the target sibling list (nil = first).
    /// `workspaceID` is nil exactly for `.essential`; `folderID` is allowed only with `.pinned`.
    /// Changing section applies the pin/unpin side effects (pinned page set or cleared). One transaction; every refusal changes nothing.
    public func moveTab(
        _ id: UUID, toWorkspace workspaceID: UUID?, section: SlotSection, folderID: UUID?, after previousTabID: UUID?
    ) throws {
        try database.writer.write { db in
            var (tab, slot) = try fetchPair(id, in: db)
            try validateMoveTarget(slot: slot, workspaceID: workspaceID, section: section, folderID: folderID, in: db)

            let index = try moveIndex(
                excluding: slot.id, workspaceID: workspaceID, profileID: slot.profileID,
                section: section, folderID: folderID, after: previousTabID, in: db
            )
            let stamp = now()
            let pinnedPage = section == .regular
                ? (url: String?.none, title: String?.none)
                : (url: tab.pinnedURL ?? tab.url, title: tab.pinnedTitle ?? tab.title)
            slot.workspaceID = workspaceID
            slot.section = section
            slot.folderID = folderID
            slot.sortIndex = index
            slot.modifiedAt = stamp
            try slot.update(db)
            if tab.pinnedURL != pinnedPage.url || tab.pinnedTitle != pinnedPage.title {
                tab.pinnedURL = pinnedPage.url
                tab.pinnedTitle = pinnedPage.title
                tab.modifiedAt = stamp
                try tab.update(db)
            }
        }
    }

    // MARK: - Helpers

    /// R16: `.essential` iff no workspace and no folder; a folder only with `.pinned`, and of the target workspace.
    private func validateMoveTarget(
        slot: Slot, workspaceID: UUID?, section: SlotSection, folderID: UUID?, in db: Database
    ) throws {
        guard (section == .essential) == (workspaceID == nil) else { throw StoreError.notFound } // essential <=> no workspace
        guard folderID == nil || section == .pinned else { throw StoreError.notFound } // folder only with the pinned section
        guard let workspaceID else { return }
        guard let workspace = try Workspace.fetchOne(db, key: workspaceID) else { throw StoreError.notFound }
        guard workspace.profileID == slot.profileID else { throw StoreError.crossProfileMove }
        if let folderID {
            guard let folder = try Folder.fetchOne(db, key: folderID),
                  folder.workspaceID == workspaceID else { throw StoreError.notFound } // folder of another workspace
        }
    }

    /// The new sort index: the midpoint after `previousTabID` among the target siblings (without the moving slot).
    /// A crowded result (R10) renumbers the siblings 0, 1, 2… first and is computed again.
    private func moveIndex(
        excluding movingSlotID: UUID, workspaceID: UUID?, profileID: UUID, section: SlotSection,
        folderID: UUID?, after previousTabID: UUID?, in db: Database
    ) throws -> Double {
        func siblings() throws -> [Child] {
            try targetSiblings(workspaceID: workspaceID, profileID: profileID, section: section, folderID: folderID, in: db)
                .filter { if case .slot(let slot) = $0 { slot.id != movingSlotID } else { true } }
        }
        func index(in list: [Child]) throws -> Double {
            try midpoint(in: list, after: previousTabID, in: db)
        }
        var list = try siblings()
        var result = try index(in: list)
        if isCrowded(result, among: list.map(\.sortIndex)) {
            try renumberSiblings(list, in: db)
            list = try siblings()
            result = try index(in: list)
        }
        return result
    }

    private func targetSiblings(
        workspaceID: UUID?, profileID: UUID, section: SlotSection, folderID: UUID?, in db: Database
    ) throws -> [Child] {
        switch section {
        case .regular:
            guard let workspaceID else { throw StoreError.notFound }
            return try regularSlots(workspaceID: workspaceID, in: db).map(Child.slot)
        case .pinned:
            guard let workspaceID else { throw StoreError.notFound }
            return try pinnedChildren(workspaceID: workspaceID, parentID: folderID, in: db)
        case .essential:
            return try Slot
                .filter(Column("profileID") == profileID && Column("section") == SlotSection.essential.rawValue)
                .order(Column("sortIndex"), Column("rowid"))
                .fetchAll(db).map(Child.slot)
        }
    }

    private func midpoint(in list: [Child], after previousTabID: UUID?, in db: Database) throws -> Double {
        guard let previousTabID else { return (list.first?.sortIndex ?? 1) - 1 }
        guard let tab = try Tab.fetchOne(db, key: previousTabID),
              let position = list.firstIndex(where: { if case .slot(let slot) = $0 { slot.id == tab.slotID } else { false } })
        else { throw StoreError.notFound } // previous tab is not in the target list
        let previous = list[position].sortIndex
        guard position + 1 < list.count else { return previous + 1 }
        return (previous + list[position + 1].sortIndex) / 2
    }

    /// Rewrites the siblings' indices to 0, 1, 2… in their current order (folders and slots alike).
    private func renumberSiblings(_ siblings: [Child], in db: Database) throws {
        let stamp = now()
        for (position, sibling) in siblings.enumerated() {
            switch sibling {
            case .folder(var folder):
                folder.sortIndex = Double(position)
                folder.modifiedAt = stamp
                try folder.update(db)
            case .slot(var slot):
                slot.sortIndex = Double(position)
                slot.modifiedAt = stamp
                try slot.update(db)
            }
        }
    }
}
