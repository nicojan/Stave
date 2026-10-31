import Foundation
import GRDB
import Testing
@testable import StaveCore

struct FolderAndWorkspaceEditTests {
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

    private func rootIDs(_ store: OrganizationStore, _ workspace: Workspace) throws -> [UUID] {
        try store.pinnedItems(workspaceID: workspace.id).map {
            switch $0 {
            case .tab(let tab): tab.id
            case .folder(let folder, _): folder.id
            }
        }
    }

    private func folders(_ store: OrganizationStore, _ workspace: Workspace, count: Int) throws -> [Folder] {
        try (0..<count).map { try store.createFolder(workspaceID: workspace.id, parentFolderID: nil, title: "F\($0)") }
    }

    // MARK: - Anchors on tabs

    @Test func tabAfterFolderAnchor() throws {
        let (store, _, _, _, ws) = try fixture()
        let t1 = try open(store, "https://example.com/1", in: ws)
        let t2 = try open(store, "https://example.com/2", in: ws)
        try store.pinTab(t1.id, folderID: nil)
        let f = try store.createFolder(workspaceID: ws.id, parentFolderID: nil, title: "F") // root: t1, F
        try store.moveTab(t1.id, toWorkspace: ws.id, section: .pinned, folderID: nil, after: .folder(f.id)) // F, t1
        try store.moveTab(t2.id, toWorkspace: ws.id, section: .pinned, folderID: nil, after: .folder(f.id))
        #expect(try rootIDs(store, ws) == [f.id, t2.id, t1.id])
    }

    @Test func folderAnchorRefusedOutsidePinned() throws {
        let (store, database, _, _, ws) = try fixture()
        let a = try open(store, "https://example.com/a", in: ws)
        let f = try store.createFolder(workspaceID: ws.id, parentFolderID: nil, title: "F")
        let before = try database.writer.read { db in try Slot.fetchAll(db) }
        #expect(throws: StoreError.notFound) {
            try store.moveTab(a.id, toWorkspace: ws.id, section: .regular, folderID: nil, after: .folder(f.id))
        }
        #expect(try database.writer.read { db in try Slot.fetchAll(db) } == before)
    }

    // MARK: - Folder moves

    @Test func moveFolderReorders() throws {
        let (store, _, _, _, ws) = try fixture()
        let all = try folders(store, ws, count: 3)
        try store.moveFolder(all[2].id, toParent: nil, after: .folder(all[0].id))
        #expect(try rootIDs(store, ws) == [all[0].id, all[2].id, all[1].id])
    }

    @Test func moveFolderToFirstAndAfterTab() throws {
        let (store, _, _, _, ws) = try fixture()
        let tab = try open(store, "https://example.com/t", in: ws)
        try store.pinTab(tab.id, folderID: nil)
        let all = try folders(store, ws, count: 2) // root: tab, F0, F1
        try store.moveFolder(all[1].id, toParent: nil, after: nil)
        #expect(try rootIDs(store, ws) == [all[1].id, tab.id, all[0].id])
        try store.moveFolder(all[1].id, toParent: nil, after: .tab(tab.id))
        #expect(try rootIDs(store, ws) == [tab.id, all[1].id, all[0].id])
    }

    @Test func moveFolderIntoFolder() throws {
        let (store, _, _, _, ws) = try fixture()
        let all = try folders(store, ws, count: 2)
        let tab = try open(store, "https://example.com/t", in: ws)
        try store.pinTab(tab.id, folderID: all[1].id)
        try store.moveFolder(all[1].id, toParent: all[0].id, after: nil)
        let items = try store.pinnedItems(workspaceID: ws.id)
        guard items.count == 1, case .folder(let outer, let children) = items[0], outer.id == all[0].id,
              children.count == 1, case .folder(let inner, let innerChildren) = children[0] else {
            Issue.record("expected A containing B"); return
        }
        #expect(inner.id == all[1].id)
        #expect(inner.parentFolderID == all[0].id)
        #expect(innerChildren.count == 1)
    }

    @Test func moveFolderOutToRoot() throws {
        let (store, _, _, _, ws) = try fixture()
        let a = try store.createFolder(workspaceID: ws.id, parentFolderID: nil, title: "A")
        let a1 = try store.createFolder(workspaceID: ws.id, parentFolderID: a.id, title: "A1")
        try store.moveFolder(a1.id, toParent: nil, after: .folder(a.id))
        #expect(try rootIDs(store, ws) == [a.id, a1.id])
    }

    @Test func moveFolderTooDeep() throws {
        let (store, database, _, _, ws) = try fixture()
        let a = try store.createFolder(workspaceID: ws.id, parentFolderID: nil, title: "A")
        let a1 = try store.createFolder(workspaceID: ws.id, parentFolderID: a.id, title: "A1")
        let b = try store.createFolder(workspaceID: ws.id, parentFolderID: nil, title: "B")
        let before = try database.writer.read { db in try Folder.fetchAll(db) }
        #expect(throws: StoreError.folderTooDeep) { try store.moveFolder(b.id, toParent: a1.id, after: nil) }
        #expect(throws: StoreError.folderTooDeep) { try store.moveFolder(a.id, toParent: b.id, after: nil) }
        #expect(throws: StoreError.folderTooDeep) { try store.moveFolder(a.id, toParent: a.id, after: nil) }
        #expect(try database.writer.read { db in try Folder.fetchAll(db) } == before)
    }

    @Test func moveChildlessFolderIntoItselfRefused() throws {
        let (store, database, _, _, ws) = try fixture()
        let a = try store.createFolder(workspaceID: ws.id, parentFolderID: nil, title: "A")
        let b = try store.createFolder(workspaceID: ws.id, parentFolderID: nil, title: "B") // no sub-folders
        let before = try database.writer.read { db in try Folder.fetchAll(db) }
        #expect(throws: StoreError.folderTooDeep) { try store.moveFolder(b.id, toParent: b.id, after: nil) }
        #expect(try database.writer.read { db in try Folder.fetchAll(db) } == before)
        #expect(try rootIDs(store, ws) == [a.id, b.id])
    }

    @Test func moveFolderOtherWorkspaceRefused() throws {
        let (store, database, _, profile, ws) = try fixture()
        let other = try store.createWorkspace(profileID: profile.id, name: "O", icon: "star", colorHex: "#000000")
        let mine = try store.createFolder(workspaceID: ws.id, parentFolderID: nil, title: "Mine")
        let theirs = try store.createFolder(workspaceID: other.id, parentFolderID: nil, title: "Theirs")
        let theirsToo = try store.createFolder(workspaceID: other.id, parentFolderID: nil, title: "Theirs2")
        let before = try database.writer.read { db in try Folder.fetchAll(db) }
        #expect(throws: StoreError.notFound) { try store.moveFolder(mine.id, toParent: theirs.id, after: nil) }
        #expect(throws: StoreError.notFound) { try store.moveFolder(mine.id, toParent: nil, after: .folder(theirsToo.id)) }
        #expect(throws: StoreError.notFound) { try store.moveFolder(UUID(), toParent: nil, after: nil) }
        #expect(throws: StoreError.notFound) { try store.moveFolder(mine.id, toParent: nil, after: .folder(mine.id)) }
        #expect(try database.writer.read { db in try Folder.fetchAll(db) } == before)
    }

    @Test func moveFolderSurvivesCrowdedIndices() throws {
        let (store, _, _, _, ws) = try fixture()
        let all = try folders(store, ws, count: 3)
        for _ in 0..<60 { // repeatedly halve the gap right after F0
            try store.moveFolder(all[2].id, toParent: nil, after: .folder(all[0].id))
            try store.moveFolder(all[1].id, toParent: nil, after: .folder(all[0].id))
        }
        #expect(try rootIDs(store, ws) == [all[0].id, all[1].id, all[2].id])
    }

    // MARK: - Folder edits

    @Test func folderOpenAndRename() throws {
        let (store, _, clock, _, ws) = try fixture()
        let f = try store.createFolder(workspaceID: ws.id, parentFolderID: nil, title: "Old")
        clock.advance(by: 10)
        try store.setFolderOpen(f.id, false)
        guard case .folder(let closed, _) = try #require(try store.pinnedItems(workspaceID: ws.id).first) else {
            Issue.record("expected a folder"); return
        }
        #expect(closed.isOpen == false)
        #expect(closed.modifiedAt == clock.date)
        clock.advance(by: 10)
        try store.renameFolder(f.id, to: "New")
        guard case .folder(let renamed, _) = try #require(try store.pinnedItems(workspaceID: ws.id).first) else {
            Issue.record("expected a folder"); return
        }
        #expect(renamed.title == "New")
        #expect(renamed.isOpen == false)
        #expect(renamed.modifiedAt == clock.date)
        #expect(throws: StoreError.notFound) { try store.setFolderOpen(UUID(), true) }
        #expect(throws: StoreError.notFound) { try store.renameFolder(UUID(), to: "x") }
    }

    // MARK: - Workspaces

    @Test func updateWorkspaceAppearance() throws {
        let (store, _, clock, profile, ws) = try fixture()
        clock.advance(by: 10)
        try store.updateWorkspace(ws.id, name: "Work", icon: "💼", colorHex: "#3478F6")
        let read = try #require(try store.workspaces(profileID: profile.id).first)
        #expect(read.name == "Work")
        #expect(read.icon == "💼")
        #expect(read.colorHex == "#3478F6")
        #expect(read.modifiedAt == clock.date)
        #expect(throws: StoreError.notFound) { try store.updateWorkspace(UUID(), name: "x", icon: "y", colorHex: "#000000") }
    }

    @Test func moveWorkspaceReorders() throws {
        let (store, _, _, profile, a) = try fixture()
        let b = try store.createWorkspace(profileID: profile.id, name: "B", icon: "star", colorHex: "#000000")
        let c = try store.createWorkspace(profileID: profile.id, name: "C", icon: "star", colorHex: "#000000")
        try store.moveWorkspace(c.id, after: nil)
        #expect(try store.workspaces(profileID: profile.id).map(\.id) == [c.id, a.id, b.id])
        try store.moveWorkspace(c.id, after: b.id)
        #expect(try store.workspaces(profileID: profile.id).map(\.id) == [a.id, b.id, c.id])
        try store.moveWorkspace(a.id, after: b.id)
        #expect(try store.workspaces(profileID: profile.id).map(\.id) == [b.id, a.id, c.id])
    }

    @Test func moveWorkspaceRefusals() throws {
        let (store, _, _, profile, a) = try fixture()
        let b = try store.createWorkspace(profileID: profile.id, name: "B", icon: "star", colorHex: "#000000")
        let stranger = try store.createProfile(name: "Q")
        let foreign = try #require(try store.workspaces(profileID: stranger.id).first)
        #expect(throws: StoreError.crossProfileMove) { try store.moveWorkspace(a.id, after: foreign.id) }
        #expect(throws: StoreError.notFound) { try store.moveWorkspace(a.id, after: UUID()) }
        #expect(throws: StoreError.notFound) { try store.moveWorkspace(UUID(), after: nil) }
        #expect(throws: StoreError.notFound) { try store.moveWorkspace(a.id, after: a.id) }
        #expect(try store.workspaces(profileID: profile.id).map(\.id) == [a.id, b.id])
        #expect(try store.workspaces(profileID: stranger.id).map(\.id) == [foreign.id])
    }

    @Test func moveWorkspaceSurvivesCrowdedIndices() throws {
        let (store, _, _, profile, a) = try fixture()
        let b = try store.createWorkspace(profileID: profile.id, name: "B", icon: "star", colorHex: "#000000")
        let c = try store.createWorkspace(profileID: profile.id, name: "C", icon: "star", colorHex: "#000000")
        for _ in 0..<60 {
            try store.moveWorkspace(c.id, after: a.id)
            try store.moveWorkspace(b.id, after: a.id)
        }
        #expect(try store.workspaces(profileID: profile.id).map(\.id) == [a.id, b.id, c.id])
    }
}
