import Foundation
import GRDB

extension OrganizationStore {
    /// Every tab of the profile (Essentials, pinned, regular) with its workspace name, most recently active first; archived tabs newest first
    /// up to `archiveLimit`; the profile's workspaces in order. `actions` is empty: the window adds them.
    public func commandCandidates(profileID: UUID, archiveLimit: Int = 200) throws -> CommandCandidates {
        try database.writer.read { db in
            let workspaces = try workspaces(profileID: profileID, in: db)
            let names = Dictionary(uniqueKeysWithValues: workspaces.map { ($0.id, $0.name) })
            let slots = try Slot.filter(Column("profileID") == profileID).fetchAll(db)
            let slotsByID = Dictionary(uniqueKeysWithValues: slots.map { ($0.id, $0) })
            let tabs = try Tab
                .filter(sql: "slotID IN (SELECT id FROM slot WHERE profileID = ?)", arguments: [profileID])
                .order(Column("lastActiveAt").desc, Column("rowid").desc)
                .fetchAll(db)
            let commandTabs = tabs.compactMap { tab -> CommandTab? in
                guard let slot = slotsByID[tab.slotID] else { return nil }
                return CommandTab(tab: tab, section: slot.section, workspaceID: slot.workspaceID, workspaceName: slot.workspaceID.flatMap { names[$0] })
            }
            let archived = try ArchivedTab
                .filter(Column("profileID") == profileID)
                .order(Column("closedAt").desc, Column("rowid").desc)
                .limit(max(archiveLimit, 0))
                .fetchAll(db)
            return CommandCandidates(tabs: commandTabs, archived: archived, workspaces: workspaces, actions: [])
        }
    }
}
