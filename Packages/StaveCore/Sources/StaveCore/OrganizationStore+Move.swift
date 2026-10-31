import Foundation
import GRDB

/// What a move goes after: a tab, or (only in the pinned section, where folders share the ordering space) a folder.
public enum MoveAnchor: Sendable, Equatable { case tab(UUID), folder(UUID) }

extension OrganizationStore {
    /// Moves a tab to a new place, directly after `anchor` in the target sibling list (nil = first).
    /// A `.folder` anchor is valid only in `.pinned`; an anchor that is not in the target list throws `.notFound`.
    /// `workspaceID` is nil exactly for `.essential`; `folderID` is allowed only with `.pinned`.
    /// Changing section applies the pin/unpin side effects (pinned page set or cleared). One transaction; every refusal changes nothing.
    public func moveTab(
        _ id: UUID, toWorkspace workspaceID: UUID?, section: SlotSection, folderID: UUID?, after anchor: MoveAnchor?
    ) throws {
        try database.writer.write { db in
            var (tab, slot) = try fetchPair(id, in: db)
            try validateMoveTarget(slot: slot, workspaceID: workspaceID, section: section, folderID: folderID, in: db)

            let index = try moveIndex(
                excluding: slot.id, workspaceID: workspaceID, profileID: slot.profileID,
                section: section, folderID: folderID, after: anchor, in: db
            )
            let stamp = now()
            let pinnedPage = section == .regular
                ? (url: String?.none, title: String?.none, favicon: String?.none)
                : (url: tab.pinnedURL ?? tab.url, title: tab.pinnedTitle ?? tab.title,
                   favicon: tab.pinnedURL == nil ? tab.faviconURL : tab.pinnedFaviconURL)
            slot.workspaceID = workspaceID
            slot.section = section
            slot.folderID = folderID
            slot.sortIndex = index
            slot.modifiedAt = stamp
            try slot.update(db)
            if tab.pinnedURL != pinnedPage.url || tab.pinnedTitle != pinnedPage.title || tab.pinnedFaviconURL != pinnedPage.favicon {
                tab.pinnedURL = pinnedPage.url
                tab.pinnedTitle = pinnedPage.title
                tab.pinnedFaviconURL = pinnedPage.favicon
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
            _ = try requireFolder(folderID, inWorkspace: workspaceID, in: db) // folder of another workspace is not found
        }
    }

    /// The new sort index: the midpoint after the anchor among the target siblings (without the moving slot).
    /// A crowded result (R10) renumbers the siblings 0, 1, 2… first and is computed again.
    private func moveIndex(
        excluding movingSlotID: UUID, workspaceID: UUID?, profileID: UUID, section: SlotSection,
        folderID: UUID?, after anchor: MoveAnchor?, in db: Database
    ) throws -> Double {
        try uncrowdedIndex(
            siblings: {
                try targetSiblings(workspaceID: workspaceID, profileID: profileID, section: section, folderID: folderID, in: db)
                    .filter { if case .slot(let slot) = $0 { slot.id != movingSlotID } else { true } }
            },
            propose: { try indexAfter(anchor, in: $0, in: db) },
            in: db
        )
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
            return try essentialSlots(profileID: profileID, in: db).map(Child.slot)
        }
    }

    /// The index directly after the anchor among `list` (nil = before the first). An anchor outside the list is `.notFound`.
    func indexAfter(_ anchor: MoveAnchor?, in list: [Child], in db: Database) throws -> Double {
        guard let anchor else { return (list.first?.sortIndex ?? 1) - 1 }
        let position: Int?
        switch anchor {
        case .tab(let tabID):
            let slotID = try Tab.fetchOne(db, key: tabID)?.slotID
            position = list.firstIndex { $0.slot?.id == slotID && slotID != nil }
        case .folder(let folderID):
            position = list.firstIndex { if case .folder(let folder) = $0 { folder.id == folderID } else { false } }
        }
        guard let position else { throw StoreError.notFound }
        let previous = list[position].sortIndex
        guard position + 1 < list.count else { return previous + 1 }
        return (previous + list[position + 1].sortIndex) / 2
    }
}
