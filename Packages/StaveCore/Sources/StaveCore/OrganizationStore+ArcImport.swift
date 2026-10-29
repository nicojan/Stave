import Foundation
import GRDB

extension OrganizationStore {
    /// Writes an Arc import plan in one transaction: any failure leaves the store untouched. Existing data is only appended after.
    public func importArc(_ plan: ArcImportPlan) throws -> ArcImportReport {
        try database.writer.write { db in
            var counts = ArcImportReport.Counts()
            // First, so a first-run default is created before any imported profile and keeps its place at the top.
            let defaultProfile = plan.profiles.contains { $0.target == .existingDefault }
                ? try ensureDefaultProfile(in: db) : nil
            for planned in plan.profiles {
                let profile: Profile
                switch planned.target {
                case .existingDefault:
                    guard let defaultProfile else { continue }
                    profile = defaultProfile
                case .new(let name):
                    profile = try insertProfile(name: name, withHomeWorkspace: planned.workspaces.isEmpty, in: db)
                    counts.profiles += 1
                }
                for workspace in planned.workspaces {
                    try writeWorkspace(workspace, profileID: profile.id, counts: &counts, in: db)
                }
                try writeEssentials(planned.essentials, profileID: profile.id, counts: &counts, in: db)
            }
            return ArcImportReport(imported: counts, flattened: plan.flattened, skipped: plan.skipped)
        }
    }

    private func writeWorkspace(
        _ planned: PlannedWorkspace, profileID: UUID, counts: inout ArcImportReport.Counts, in db: Database
    ) throws {
        let workspace = try insertWorkspace(
            profileID: profileID, name: planned.name, icon: planned.icon, colorHex: planned.colorHex, in: db
        )
        counts.workspaces += 1
        try writePinned(planned.pinned, workspace: workspace, parent: nil, counts: &counts, in: db)
        for (index, tab) in planned.regular.enumerated() {
            let slot = Slot(
                profileID: profileID, workspaceID: workspace.id, section: .regular,
                sortIndex: Double(index), modifiedAt: now()
            )
            try insertTab(tab, slot: slot, pinned: false, in: db)
            counts.regularTabs += 1
        }
    }

    /// `parent` is nil at the root; a folder whose parent is itself nested throws `.folderTooDeep`.
    private func writePinned(
        _ items: [PlannedPinned], workspace: Workspace, parent: Folder?,
        counts: inout ArcImportReport.Counts, in db: Database
    ) throws {
        for (index, item) in items.enumerated() {
            switch item {
            case .tab(let tab):
                let slot = Slot(
                    profileID: workspace.profileID, workspaceID: workspace.id, section: .pinned,
                    folderID: parent?.id, sortIndex: Double(index), modifiedAt: now()
                )
                try insertTab(tab, slot: slot, pinned: true, in: db)
                counts.pinnedTabs += 1
            case .folder(let title, let children):
                if let parent, parent.parentFolderID != nil { throw StoreError.folderTooDeep }
                let folder = Folder(
                    workspaceID: workspace.id, parentFolderID: parent?.id, title: title,
                    sortIndex: Double(index), modifiedAt: now()
                )
                try folder.insert(db)
                counts.folders += 1
                try writePinned(children, workspace: workspace, parent: folder, counts: &counts, in: db)
            }
        }
    }

    private func writeEssentials(
        _ tabs: [PlannedTab], profileID: UUID, counts: inout ArcImportReport.Counts, in db: Database
    ) throws {
        guard !tabs.isEmpty else { return }
        let current = try Double.fetchOne(
            db,
            Slot.filter(Column("profileID") == profileID && Column("section") == SlotSection.essential.rawValue)
                .select(max(Column("sortIndex")))
        )
        var next = (current ?? -1) + 1
        for tab in tabs {
            let slot = Slot(profileID: profileID, workspaceID: nil, section: .essential, sortIndex: next, modifiedAt: now())
            try insertTab(tab, slot: slot, pinned: true, in: db)
            counts.essentials += 1
            next += 1
        }
    }

    private func insertTab(_ tab: PlannedTab, slot: Slot, pinned: Bool, in db: Database) throws {
        try slot.insert(db)
        let stamp = now()
        try Tab(
            slotID: slot.id,
            pinnedURL: pinned ? tab.url : nil, pinnedTitle: pinned ? tab.title : nil,
            url: tab.url, title: tab.title, lastActiveAt: stamp, modifiedAt: stamp
        ).insert(db)
    }
}
