import Foundation
import GRDB
import Testing
@testable import StaveCore

struct MoveTests {
    private func fixture() throws -> (OrganizationStore, StaveDatabase, TestClock, Profile, Workspace) {
        let clock = TestClock()
        let (store, database, _) = try makeTempStore(now: clock.now)
        let profile = try store.createProfile(name: "P")
        let workspace = try #require(try store.workspaces(profileID: profile.id).first)
        return (store, database, clock, profile, workspace)
    }

    private func open(_ store: OrganizationStore, _ url: String, in workspace: Workspace) throws -> Tab {
        try store.openTab(url: url, title: url, workspaceID: workspace.id, origin: .commandBar, containerID: nil, edge: .bottom)
    }

    private func slot(of tab: Tab, in database: StaveDatabase) throws -> Slot {
        try database.writer.read { db in try #require(try Slot.fetchOne(db, key: tab.slotID)) }
    }

    private func tab(_ id: UUID, in database: StaveDatabase) throws -> Tab {
        try database.writer.read { db in try #require(try Tab.fetchOne(db, key: id)) }
    }

    private func rootTabIDs(_ store: OrganizationStore, _ workspace: Workspace) throws -> [UUID] {
        try store.pinnedItems(workspaceID: workspace.id).compactMap { if case .tab(let t) = $0 { t.id } else { nil } }
    }

    // MARK: - Ordering

    @Test func reorderWithinRegular() throws {
        let (store, _, _, _, ws) = try fixture()
        let a = try open(store, "https://a.com", in: ws)
        let b = try open(store, "https://b.com", in: ws)
        let c = try open(store, "https://c.com", in: ws)
        try store.moveTab(c.id, toWorkspace: ws.id, section: .regular, folderID: nil, after: .tab(a.id))
        #expect(try store.regularTabs(workspaceID: ws.id).map(\.id) == [a.id, c.id, b.id])
    }

    @Test func moveToFirstAndToLast() throws {
        let (store, _, _, _, ws) = try fixture()
        let a = try open(store, "https://a.com", in: ws)
        let b = try open(store, "https://b.com", in: ws)
        let c = try open(store, "https://c.com", in: ws)
        try store.moveTab(c.id, toWorkspace: ws.id, section: .regular, folderID: nil, after: nil)
        #expect(try store.regularTabs(workspaceID: ws.id).map(\.id) == [c.id, a.id, b.id])
        try store.moveTab(c.id, toWorkspace: ws.id, section: .regular, folderID: nil, after: .tab(b.id))
        #expect(try store.regularTabs(workspaceID: ws.id).map(\.id) == [a.id, b.id, c.id])
    }

    /// Dropping a tab where it already is must not drift its index: the moving tab is not its own neighbour.
    @Test func dropInPlaceKeepsIndex() throws {
        let (store, database, _, _, ws) = try fixture()
        let a = try open(store, "https://a.com", in: ws)
        let b = try open(store, "https://b.com", in: ws)
        let c = try open(store, "https://c.com", in: ws)
        let before = try [a, b, c].map { try slot(of: $0, in: database).sortIndex }
        try store.moveTab(c.id, toWorkspace: ws.id, section: .regular, folderID: nil, after: .tab(b.id))
        #expect(try [a, b, c].map { try slot(of: $0, in: database).sortIndex } == before)
    }

    @Test func crowdedGapRenumbersAndKeepsOrder() throws {
        let (store, database, _, _, ws) = try fixture()
        let a = try open(store, "https://a.com", in: ws)
        let b = try open(store, "https://b.com", in: ws)
        let c = try open(store, "https://c.com", in: ws)
        // Make a and b nearly touching: any midpoint is within the minimum gap.
        try database.writer.write { db in
            try db.execute(sql: "UPDATE slot SET sortIndex = 1 WHERE id = ?", arguments: [try #require(try Tab.fetchOne(db, key: a.id)).slotID])
            try db.execute(sql: "UPDATE slot SET sortIndex = 1.0000000001 WHERE id = ?", arguments: [try #require(try Tab.fetchOne(db, key: b.id)).slotID])
            try db.execute(sql: "UPDATE slot SET sortIndex = 5 WHERE id = ?", arguments: [try #require(try Tab.fetchOne(db, key: c.id)).slotID])
        }
        try store.moveTab(c.id, toWorkspace: ws.id, section: .regular, folderID: nil, after: .tab(a.id))
        #expect(try store.regularTabs(workspaceID: ws.id).map(\.id) == [a.id, c.id, b.id])
        let indices = try [a, b, c].map { try slot(of: $0, in: database).sortIndex }
        #expect(Set(indices).count == 3)
        #expect(indices == [0, 1, 0.5]) // a, b renumbered to 0, 1; c is their midpoint
    }

    @Test func pinnedRootOrderIncludesFolders() throws {
        let (store, _, _, _, ws) = try fixture()
        let a = try open(store, "https://a.com", in: ws)
        let b = try open(store, "https://b.com", in: ws)
        try store.pinTab(a.id, folderID: nil)
        let folder = try store.createFolder(workspaceID: ws.id, parentFolderID: nil, title: "F") // root: a, F
        try store.moveTab(b.id, toWorkspace: ws.id, section: .pinned, folderID: nil, after: .tab(a.id)) // a, b, F
        let items = try store.pinnedItems(workspaceID: ws.id)
        #expect(items.count == 3)
        guard case .tab(let first) = items[0], case .tab(let second) = items[1], case .folder(let third, _) = items[2] else {
            Issue.record("expected tab, tab, folder"); return
        }
        #expect([first.id, second.id] == [a.id, b.id])
        #expect(third.id == folder.id)
    }

    @Test func essentialsReorder() throws {
        let (store, _, _, profile, ws) = try fixture()
        let a = try open(store, "https://a.com", in: ws)
        let b = try open(store, "https://b.com", in: ws)
        let c = try open(store, "https://c.com", in: ws)
        for tab in [a, b, c] { try store.makeEssential(tab.id) }
        try store.moveTab(c.id, toWorkspace: nil, section: .essential, folderID: nil, after: nil)
        #expect(try store.essentials(profileID: profile.id).map(\.id) == [c.id, a.id, b.id])
    }

    // MARK: - State

    @Test func moveBetweenWorkspacesKeepsState() throws {
        let (store, database, clock, profile, ws) = try fixture()
        let other = try store.createWorkspace(profileID: profile.id, name: "Other", icon: "star", colorHex: "#000000")
        let tab = try open(store, "https://a.com", in: ws)
        try store.updateNavigation(tabID: tab.id, url: "https://a.com/x", title: "X", faviconURL: nil, interactionState: Data([1, 2, 3]))
        clock.advance(by: 100)
        try store.moveTab(tab.id, toWorkspace: other.id, section: .regular, folderID: nil, after: nil)
        let moved = try self.tab(tab.id, in: database)
        #expect(moved.id == tab.id)
        #expect(moved.interactionState == Data([1, 2, 3]))
        #expect(moved.url == "https://a.com/x")
        #expect(moved.containerID == tab.containerID)
        #expect(try store.regularTabs(workspaceID: other.id).map(\.id) == [tab.id])
        #expect(try store.regularTabs(workspaceID: ws.id).isEmpty)
        let slot = try slot(of: moved, in: database)
        #expect(slot.workspaceID == other.id)
        #expect(slot.modifiedAt == clock.date)
        #expect(try store.archivedTabs(profileID: profile.id).isEmpty)
    }

    @Test func crossProfileRefused() throws {
        let (store, database, _, _, ws) = try fixture()
        let otherProfile = try store.createProfile(name: "Q")
        let foreign = try #require(try store.workspaces(profileID: otherProfile.id).first)
        let tab = try open(store, "https://a.com", in: ws)
        let before = try slot(of: tab, in: database)
        #expect(throws: StoreError.crossProfileMove) {
            try store.moveTab(tab.id, toWorkspace: foreign.id, section: .regular, folderID: nil, after: nil)
        }
        #expect(try slot(of: tab, in: database) == before)
        #expect(try store.regularTabs(workspaceID: foreign.id).isEmpty)
    }

    // MARK: - Section side effects

    @Test func regularToPinnedFolderPins() throws {
        let (store, database, clock, _, ws) = try fixture()
        let tab = try open(store, "https://a.com", in: ws)
        let folder = try store.createFolder(workspaceID: ws.id, parentFolderID: nil, title: "F")
        clock.advance(by: 50)
        try store.moveTab(tab.id, toWorkspace: ws.id, section: .pinned, folderID: folder.id, after: nil)
        let moved = try self.tab(tab.id, in: database)
        #expect(moved.pinnedURL == "https://a.com")
        #expect(moved.pinnedTitle == "https://a.com")
        #expect(moved.modifiedAt == clock.date)
        let slot = try slot(of: moved, in: database)
        #expect(slot.section == .pinned && slot.folderID == folder.id && slot.modifiedAt == clock.date)
        #expect(try store.regularTabs(workspaceID: ws.id).isEmpty)
    }

    @Test func pinnedToRegularClearsPinnedPage() throws {
        let (store, database, _, _, ws) = try fixture()
        let a = try open(store, "https://a.com", in: ws)
        let b = try open(store, "https://b.com", in: ws)
        try store.pinTab(b.id, folderID: nil)
        try store.moveTab(b.id, toWorkspace: ws.id, section: .regular, folderID: nil, after: .tab(a.id))
        let moved = try tab(b.id, in: database)
        #expect(moved.pinnedURL == nil && moved.pinnedTitle == nil)
        #expect(try store.regularTabs(workspaceID: ws.id).map(\.id) == [a.id, b.id])
        #expect(try slot(of: moved, in: database).folderID == nil)
    }

    @Test func regularToEssentialSetsPinnedPage() throws {
        let (store, database, _, profile, ws) = try fixture()
        let tab = try open(store, "https://a.com", in: ws)
        try store.moveTab(tab.id, toWorkspace: nil, section: .essential, folderID: nil, after: nil)
        #expect(try store.essentials(profileID: profile.id).map(\.id) == [tab.id])
        let moved = try self.tab(tab.id, in: database)
        #expect(moved.pinnedURL == "https://a.com")
        #expect(try slot(of: moved, in: database).workspaceID == nil)
    }

    @Test func essentialToWorkspaceUnessentials() throws {
        let (store, database, _, profile, ws) = try fixture()
        let a = try open(store, "https://a.com", in: ws)
        let b = try open(store, "https://b.com", in: ws)
        try store.makeEssential(b.id)
        try store.moveTab(b.id, toWorkspace: ws.id, section: .regular, folderID: nil, after: .tab(a.id))
        #expect(try store.essentials(profileID: profile.id).isEmpty)
        #expect(try store.regularTabs(workspaceID: ws.id).map(\.id) == [a.id, b.id])
        let moved = try tab(b.id, in: database)
        #expect(moved.pinnedURL == nil)
        #expect(try slot(of: moved, in: database).section == .regular)
    }

    // MARK: - Validation (every refusal leaves the slot untouched)

    @Test func invalidRequestsThrowNotFoundAndChangeNothing() throws {
        let (store, database, _, profile, ws) = try fixture()
        let a = try open(store, "https://a.com", in: ws)
        let b = try open(store, "https://b.com", in: ws)
        let otherWS = try store.createWorkspace(profileID: profile.id, name: "O", icon: "star", colorHex: "#000000")
        let foreignFolder = try store.createFolder(workspaceID: otherWS.id, parentFolderID: nil, title: "O")
        let folder = try store.createFolder(workspaceID: ws.id, parentFolderID: nil, title: "F")
        let before = try [a, b].map { try slot(of: $0, in: database) }

        func refused(_ body: () throws -> Void) {
            #expect(throws: StoreError.notFound, performing: body)
        }
        refused { try store.moveTab(UUID(), toWorkspace: ws.id, section: .regular, folderID: nil, after: nil) } // unknown tab
        refused { try store.moveTab(a.id, toWorkspace: UUID(), section: .regular, folderID: nil, after: nil) } // unknown workspace
        refused { try store.moveTab(a.id, toWorkspace: ws.id, section: .pinned, folderID: UUID(), after: nil) } // unknown folder
        refused { try store.moveTab(a.id, toWorkspace: ws.id, section: .regular, folderID: nil, after: .tab(UUID())) } // unknown previous
        refused { try store.moveTab(a.id, toWorkspace: ws.id, section: .essential, folderID: nil, after: nil) } // essential needs no workspace
        refused { try store.moveTab(a.id, toWorkspace: nil, section: .regular, folderID: nil, after: nil) } // non-essential needs a workspace
        refused { try store.moveTab(a.id, toWorkspace: nil, section: .essential, folderID: folder.id, after: nil) } // essential has no folder
        refused { try store.moveTab(a.id, toWorkspace: ws.id, section: .regular, folderID: folder.id, after: nil) } // folder only with pinned
        refused { try store.moveTab(a.id, toWorkspace: ws.id, section: .pinned, folderID: foreignFolder.id, after: nil) } // folder of another workspace
        refused { try store.moveTab(a.id, toWorkspace: ws.id, section: .regular, folderID: nil, after: .tab(a.id)) } // after itself
        // previous must be in the target list: b is regular, the target is pinned root.
        refused { try store.moveTab(a.id, toWorkspace: ws.id, section: .pinned, folderID: nil, after: .tab(b.id)) }
        #expect(try [a, b].map { try slot(of: $0, in: database) } == before)
        #expect(try tab(a.id, in: database).pinnedURL == nil)
    }
}
