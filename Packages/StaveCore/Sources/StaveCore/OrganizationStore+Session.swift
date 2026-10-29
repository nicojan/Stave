import Foundation
import GRDB

/// Everything the sidebar renders for one workspace, read in a single consistent transaction.
public struct SidebarSnapshot: Sendable, Equatable {
    public var profile: Profile
    public var workspace: Workspace
    public var essentials: [Tab]
    public var pinned: [PinnedItem]
    public var regular: [Tab]

    public init(profile: Profile, workspace: Workspace, essentials: [Tab], pinned: [PinnedItem], regular: [Tab]) {
        self.profile = profile; self.workspace = workspace
        self.essentials = essentials; self.pinned = pinned; self.regular = regular
    }
}

extension OrganizationStore {
    /// The `frame` of the window `restoredWindows` synthesises when none were saved: empty means "let the app choose".
    static let defaultWindowFrame = ""

    // MARK: - Snapshot

    /// Essentials, pinned tree and regular tabs of the workspace, in stored order, from one `writer.read`. Unknown workspace throws `.notFound`.
    public func sidebarSnapshot(workspaceID: UUID) throws -> SidebarSnapshot {
        try database.writer.read { db in
            guard let workspace = try Workspace.fetchOne(db, key: workspaceID),
                  let profile = try Profile.fetchOne(db, key: workspace.profileID) else { throw StoreError.notFound }
            return SidebarSnapshot(
                profile: profile, workspace: workspace,
                essentials: try essentials(profileID: profile.id, in: db),
                pinned: try pinnedItems(workspaceID: workspace.id, in: db),
                regular: try regularTabs(workspaceID: workspace.id, in: db)
            )
        }
    }

    // MARK: - Windows

    /// Replaces every saved window with `windows`, in the given order, in one transaction; stamps `modifiedAt` from the injected clock.
    /// Private windows must never be passed in: the caller filters them out, because a private window leaves nothing on disk.
    public func saveWindows(_ windows: [WindowState]) throws {
        try database.writer.write { db in
            let stamp = now()
            _ = try WindowState.deleteAll(db)
            for window in windows {
                var stamped = window
                stamped.modifiedAt = stamp
                try stamped.insert(db)
            }
        }
    }

    /// The saved windows in `sortIndex` order, corrected for anything that changed since they were saved. Corrections are returned, not persisted:
    /// the app calls `saveWindows` on quit. A window whose profile is gone is dropped; one whose workspace is gone falls back to its profile's
    /// first workspace; a `selectedTabID` that no longer exists, or is not in the window's workspace or its profile's Essentials, is cleared.
    /// With no windows left, creates the default profile if the store has none (one transaction) and returns one window on its first workspace.
    public func restoredWindows() throws -> [WindowState] {
        try database.writer.write { db in
            let saved = try WindowState.order(Column("sortIndex"), Column("rowid")).fetchAll(db)
            let corrected = try saved.compactMap { try correctedWindow($0, in: db) }
            if !corrected.isEmpty { return corrected }
            return [try defaultWindow(in: db)]
        }
    }

    // MARK: - Helpers

    private func correctedWindow(_ window: WindowState, in db: Database) throws -> WindowState? {
        guard try Profile.fetchOne(db, key: window.profileID) != nil else { return nil }
        var result = window
        let workspaceExists = try Workspace.fetchOne(db, key: window.workspaceID)
            .map { $0.profileID == window.profileID } ?? false
        if !workspaceExists {
            guard let first = try workspaces(profileID: window.profileID, in: db).first else { return nil }
            result.workspaceID = first.id
            result.selectedTabID = nil
        }
        if let tabID = result.selectedTabID, !(try isSelectable(tabID, workspaceID: result.workspaceID, profileID: result.profileID, in: db)) {
            result.selectedTabID = nil
        }
        return result
    }

    /// True when the tab exists and sits in the workspace (regular or pinned) or in the profile's Essentials.
    private func isSelectable(_ tabID: UUID, workspaceID: UUID, profileID: UUID, in db: Database) throws -> Bool {
        guard let tab = try Tab.fetchOne(db, key: tabID), let slot = try Slot.fetchOne(db, key: tab.slotID) else { return false }
        switch slot.section {
        case .essential: return slot.profileID == profileID
        case .pinned, .regular: return slot.workspaceID == workspaceID
        }
    }

    private func defaultWindow(in db: Database) throws -> WindowState {
        let profile = try ensureDefaultProfile(in: db)
        guard let workspace = try workspaces(profileID: profile.id, in: db).first else { throw StoreError.notFound }
        return WindowState(
            profileID: profile.id, workspaceID: workspace.id, selectedTabID: nil,
            frame: Self.defaultWindowFrame, sortIndex: 0, modifiedAt: now()
        )
    }
}
