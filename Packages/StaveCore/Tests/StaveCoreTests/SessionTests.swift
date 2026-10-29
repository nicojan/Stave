import Foundation
import GRDB
import Testing
@testable import StaveCore

struct SessionTests {
    private func fixture() throws -> (OrganizationStore, TestClock, Profile, Workspace) {
        let clock = TestClock()
        let (store, _, _) = try makeTempStore(now: clock.now)
        let profile = try store.createProfile(name: "P")
        let workspace = try #require(try store.workspaces(profileID: profile.id).first)
        return (store, clock, profile, workspace)
    }

    private func open(_ store: OrganizationStore, _ url: String, in workspace: Workspace) throws -> Tab {
        try store.openTab(url: url, title: url, workspaceID: workspace.id, origin: .commandBar, containerID: nil, edge: .bottom)
    }

    private func window(_ profile: Profile, _ workspace: Workspace, selected: UUID? = nil, frame: String = "0 0 800 600", index: Double = 0) -> WindowState {
        WindowState(profileID: profile.id, workspaceID: workspace.id, selectedTabID: selected, frame: frame, sortIndex: index)
    }

    // MARK: - Snapshot

    @Test func snapshotOrdersEverything() throws {
        let (store, _, profile, ws) = try fixture()
        let e1 = try open(store, "https://e1.com", in: ws)
        let e2 = try open(store, "https://e2.com", in: ws)
        try store.makeEssential(e1.id)
        try store.makeEssential(e2.id)
        let p1 = try open(store, "https://p1.com", in: ws)
        let p2 = try open(store, "https://p2.com", in: ws)
        try store.pinTab(p1.id, folderID: nil)
        let folder = try store.createFolder(workspaceID: ws.id, parentFolderID: nil, title: "F")
        try store.pinTab(p2.id, folderID: folder.id)
        let r1 = try open(store, "https://r1.com", in: ws)
        let r2 = try open(store, "https://r2.com", in: ws)
        let r3 = try open(store, "https://r3.com", in: ws)

        let snapshot = try store.sidebarSnapshot(workspaceID: ws.id)
        #expect(snapshot.profile.id == profile.id)
        #expect(snapshot.workspace.id == ws.id)
        #expect(snapshot.essentials.map(\.id) == [e1.id, e2.id])
        #expect(snapshot.regular.map(\.id) == [r1.id, r2.id, r3.id])
        #expect(snapshot.pinned.count == 2)
        guard case .tab(let first) = snapshot.pinned[0] else { Issue.record("first pinned item is not a tab"); return }
        #expect(first.id == p1.id)
        guard case .folder(let f, let children) = snapshot.pinned[1] else { Issue.record("second pinned item is not a folder"); return }
        #expect(f.id == folder.id)
        #expect(children.count == 1)
        guard case .tab(let child) = children[0] else { Issue.record("folder child is not a tab"); return }
        #expect(child.id == p2.id)
    }

    /// A split slot holds two tabs (R22). Every read path must survive it and show the slot once, by its first tab (rowid).
    @Test func splitSlotsReadAsOneEntry() throws {
        let clock = TestClock()
        let (store, database, _) = try makeTempStore(now: clock.now)
        let profile = try store.createProfile(name: "P")
        let ws = try #require(try store.workspaces(profileID: profile.id).first)
        let stamp = clock.date
        var firsts: [SlotSection: UUID] = [:]
        try database.writer.write { db in
            for (index, (section, workspaceID)) in [(SlotSection.regular, Optional(ws.id)), (.pinned, ws.id), (.essential, nil)].enumerated() {
                let slot = Slot(profileID: profile.id, workspaceID: workspaceID, section: section, kind: .split, sortIndex: Double(index), modifiedAt: stamp)
                try slot.insert(db)
                let first = Tab(slotID: slot.id, url: "https://\(section.rawValue)-1.example", title: "1", lastActiveAt: stamp, modifiedAt: stamp)
                try first.insert(db)
                try Tab(slotID: slot.id, url: "https://\(section.rawValue)-2.example", title: "2", lastActiveAt: stamp, modifiedAt: stamp).insert(db)
                firsts[section] = first.id
            }
        }
        #expect(try store.regularTabs(workspaceID: ws.id).map(\.id) == [firsts[.regular]])
        #expect(try store.essentials(profileID: profile.id).map(\.id) == [firsts[.essential]])
        let pinned = try store.pinnedItems(workspaceID: ws.id)
        let firstPinned = try #require(try database.writer.read { db in try Tab.fetchOne(db, key: firsts[.pinned]) })
        #expect(pinned == [.tab(firstPinned)])
        let snapshot = try store.sidebarSnapshot(workspaceID: ws.id)
        #expect(snapshot.regular.map(\.id) == [firsts[.regular]])
        #expect(snapshot.essentials.map(\.id) == [firsts[.essential]])
        #expect(snapshot.pinned == pinned)
        // Opening next to a split slot still places the new tab.
        let opened = try store.openTab(url: "https://new.example", title: "n", workspaceID: ws.id, origin: .commandBar, containerID: nil, edge: .bottom)
        #expect(try store.regularTabs(workspaceID: ws.id).map(\.id) == [firsts[.regular], opened.id])
    }

    @Test func snapshotUnknownWorkspaceThrows() throws {
        let (store, _, _, _) = try fixture()
        #expect(throws: StoreError.notFound) { try store.sidebarSnapshot(workspaceID: UUID()) }
    }

    // MARK: - Save and restore

    @Test func windowsRoundTrip() throws {
        let (store, _, profile, ws) = try fixture()
        let a = window(profile, ws, frame: "10 10 800 600", index: 0)
        let b = window(profile, ws, frame: "50 60 900 700", index: 1)
        try store.saveWindows([a, b])
        let restored = try store.restoredWindows()
        #expect(restored.map(\.id) == [a.id, b.id])
        #expect(restored.map(\.frame) == ["10 10 800 600", "50 60 900 700"])
        #expect(restored.map(\.workspaceID) == [ws.id, ws.id])
        #expect(restored.map(\.sortIndex) == [0, 1])
    }

    @Test func saveReplacesAllAndStampsModifiedAt() throws {
        let (store, clock, profile, ws) = try fixture()
        try store.saveWindows([window(profile, ws), window(profile, ws, index: 1)])
        clock.advance(by: 100)
        let only = window(profile, ws, frame: "x")
        try store.saveWindows([only])
        let restored = try store.restoredWindows()
        #expect(restored.map(\.id) == [only.id])
        #expect(restored[0].modifiedAt == clock.date)
    }

    @Test func restoreOrdersBySortIndex() throws {
        let (store, _, profile, ws) = try fixture()
        let late = window(profile, ws, index: 5)
        let early = window(profile, ws, index: 2)
        try store.saveWindows([late, early])
        #expect(try store.restoredWindows().map(\.id) == [early.id, late.id])
    }

    @Test func deletedWorkspaceFallsBack() throws {
        let (store, _, profile, home) = try fixture()
        let other = try store.createWorkspace(profileID: profile.id, name: "B", icon: "star", colorHex: "#000000")
        let tab = try open(store, "https://b.com", in: other)
        try store.saveWindows([window(profile, other, selected: tab.id)])
        try store.deleteWorkspace(other.id)
        let restored = try #require(try store.restoredWindows().first)
        #expect(restored.workspaceID == home.id)
        #expect(restored.selectedTabID == nil)
        #expect(restored.profileID == profile.id)
    }

    @Test func deletedWorkspaceFallbackKeepsSelectedEssential() throws {
        let (store, _, profile, home) = try fixture()
        let other = try store.createWorkspace(profileID: profile.id, name: "B", icon: "star", colorHex: "#000000")
        let essential = try open(store, "https://e.com", in: other)
        try store.makeEssential(essential.id)
        _ = try open(store, "https://b.com", in: other)
        try store.saveWindows([window(profile, other, selected: essential.id)])
        try store.deleteWorkspace(other.id)
        let restored = try #require(try store.restoredWindows().first)
        #expect(restored.workspaceID == home.id)
        #expect(restored.selectedTabID == essential.id)
    }

    /// A window whose workspace belongs to another profile falls back; that workspace's tab (or Essential) is not kept.
    @Test func foreignWorkspaceFallbackClearsItsTab() throws {
        let (store, _, profile, home) = try fixture()
        let second = try store.createProfile(name: "Q")
        let foreign = try #require(try store.workspaces(profileID: second.id).first)
        let foreignTab = try open(store, "https://q.com", in: foreign)
        let foreignEssential = try open(store, "https://qe.com", in: foreign)
        try store.makeEssential(foreignEssential.id)
        try store.saveWindows([
            WindowState(profileID: profile.id, workspaceID: foreign.id, selectedTabID: foreignTab.id, frame: "", sortIndex: 0),
            WindowState(profileID: profile.id, workspaceID: foreign.id, selectedTabID: foreignEssential.id, frame: "", sortIndex: 1),
        ])
        let restored = try store.restoredWindows()
        #expect(restored.map(\.workspaceID) == [home.id, home.id])
        #expect(restored.map(\.selectedTabID) == [nil, nil])
    }

    @Test func windowOfDeletedProfileIsDropped() throws {
        let (store, _, profile, ws) = try fixture()
        let second = try store.createProfile(name: "Q")
        let secondWS = try #require(try store.workspaces(profileID: second.id).first)
        try store.saveWindows([window(profile, ws, index: 0), window(second, secondWS, index: 1)])
        try store.deleteProfile(second.id)
        let restored = try store.restoredWindows()
        #expect(restored.count == 1)
        #expect(restored[0].profileID == profile.id)
    }

    @Test func noWindowsGivesDefault() throws {
        let (store, _, _) = try makeTempStore()
        let restored = try store.restoredWindows()
        #expect(restored.count == 1)
        let profile = try #require(try store.profiles().first)
        #expect(profile.name == "Personal")
        let workspace = try #require(try store.workspaces(profileID: profile.id).first)
        #expect(workspace.name == "Home")
        #expect(restored[0].profileID == profile.id)
        #expect(restored[0].workspaceID == workspace.id)
        #expect(restored[0].selectedTabID == nil)
        #expect(restored[0].sortIndex == 0)
        #expect(try store.profiles().count == 1)
    }

    @Test func noWindowsWithExistingProfileUsesItsFirstWorkspace() throws {
        let (store, _, profile, ws) = try fixture()
        let restored = try store.restoredWindows()
        #expect(restored.count == 1)
        #expect(restored[0].profileID == profile.id)
        #expect(restored[0].workspaceID == ws.id)
        #expect(try store.profiles().count == 1)
    }

    @Test func restoreDoesNotPersistCorrections() throws {
        let (store, _, profile, ws) = try fixture()
        let tab = try open(store, "https://a.com", in: ws)
        let saved = window(profile, ws, selected: tab.id)
        try store.saveWindows([saved])
        _ = try store.closeTab(tab.id)
        #expect(try store.restoredWindows().first?.selectedTabID == nil)
        let rows = try store.database.writer.read { db in try WindowState.fetchAll(db) }
        #expect(rows.first?.selectedTabID == tab.id)
    }

    // MARK: - selectedTabID validation

    @Test func selectedTabIsKept() throws {
        let (store, _, profile, ws) = try fixture()
        let regular = try open(store, "https://r.com", in: ws)
        let pinned = try open(store, "https://p.com", in: ws)
        try store.pinTab(pinned.id, folderID: nil)
        try store.saveWindows([window(profile, ws, selected: regular.id, index: 0), window(profile, ws, selected: pinned.id, index: 1)])
        #expect(try store.restoredWindows().map(\.selectedTabID) == [regular.id, pinned.id])
    }

    @Test func closedSelectedTabRestoresNil() throws {
        let (store, _, profile, ws) = try fixture()
        let tab = try open(store, "https://a.com", in: ws)
        try store.saveWindows([window(profile, ws, selected: tab.id)])
        _ = try store.closeTab(tab.id)
        let restored = try #require(try store.restoredWindows().first)
        #expect(restored.workspaceID == ws.id)
        #expect(restored.selectedTabID == nil)
    }

    @Test func selectedTabMovedToAnotherWorkspaceRestoresNil() throws {
        let (store, _, profile, ws) = try fixture()
        let other = try store.createWorkspace(profileID: profile.id, name: "B", icon: "star", colorHex: "#000000")
        let tab = try open(store, "https://a.com", in: ws)
        try store.saveWindows([window(profile, ws, selected: tab.id)])
        try store.moveTab(tab.id, toWorkspace: other.id, section: .regular, folderID: nil, after: nil)
        #expect(try store.restoredWindows().first?.selectedTabID == nil)
    }

    @Test func selectedEssentialIsKept() throws {
        let (store, _, profile, ws) = try fixture()
        let other = try store.createWorkspace(profileID: profile.id, name: "B", icon: "star", colorHex: "#000000")
        let tab = try open(store, "https://a.com", in: ws)
        try store.makeEssential(tab.id)
        try store.saveWindows([window(profile, other, selected: tab.id)])
        #expect(try store.restoredWindows().first?.selectedTabID == tab.id)
    }
}
