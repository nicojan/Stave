import Foundation
import GRDB
import Testing
@testable import StaveCore

struct PinnedTests {
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

    private func tabIDs(_ items: [PinnedItem]) -> [UUID] {
        items.compactMap { if case .tab(let tab) = $0 { tab.id } else { nil } }
    }

    @Test func pinThenResetRestoresPinnedPage() throws {
        let (store, _, _, _, ws) = try fixture()
        let tab = try open(store, "https://a.com", in: ws)
        try store.pinTab(tab.id, folderID: nil)
        try store.updateNavigation(tabID: tab.id, url: "https://a.com/deep", title: "Deep", faviconURL: nil, interactionState: Data([9]))
        guard case .tab(let drifted) = try #require(store.pinnedItems(workspaceID: ws.id).first) else { Issue.record("not a tab"); return }
        #expect(store.isDrifted(drifted))
        try store.resetPinnedTab(tab.id)
        guard case .tab(let reset) = try #require(store.pinnedItems(workspaceID: ws.id).first) else { Issue.record("not a tab"); return }
        #expect(reset.url == "https://a.com")
        #expect(reset.title == "https://a.com")
        #expect(reset.interactionState == nil)
        #expect(!store.isDrifted(reset))
    }

    @Test func resetRegularThrowsNotPinned() throws {
        let (store, _, _, _, ws) = try fixture()
        let tab = try open(store, "https://a.com", in: ws)
        #expect(throws: StoreError.notPinned) { try store.resetPinnedTab(tab.id) }
        #expect(throws: StoreError.notFound) { try store.resetPinnedTab(UUID()) }
    }

    @Test func closingPinnedUnloads() throws {
        let (store, _, _, profile, ws) = try fixture()
        let tab = try open(store, "https://a.com", in: ws)
        try store.pinTab(tab.id, folderID: nil)
        #expect(try store.closeTab(tab.id) == .unloaded)
        #expect(tabIDs(try store.pinnedItems(workspaceID: ws.id)) == [tab.id])
        #expect(try store.archivedTabs(profileID: profile.id).isEmpty)
    }

    @Test func closingEssentialUnloads() throws {
        let (store, _, _, profile, ws) = try fixture()
        let tab = try open(store, "https://a.com", in: ws)
        try store.makeEssential(tab.id)
        #expect(try store.closeTab(tab.id) == .unloaded)
        #expect(try store.essentials(profileID: profile.id).map(\.id) == [tab.id])
        #expect(try store.archivedTabs(profileID: profile.id).isEmpty)
    }

    @Test func folderNestsOneLevel() throws {
        let (store, _, _, _, ws) = try fixture()
        let top = try store.createFolder(workspaceID: ws.id, parentFolderID: nil, title: "Top")
        let inner = try store.createFolder(workspaceID: ws.id, parentFolderID: top.id, title: "Inner")
        #expect(inner.parentFolderID == top.id)
        #expect(throws: StoreError.folderTooDeep) {
            try store.createFolder(workspaceID: ws.id, parentFolderID: inner.id, title: "Third")
        }
        #expect(throws: StoreError.notFound) { try store.createFolder(workspaceID: ws.id, parentFolderID: UUID(), title: "x") }
        #expect(throws: StoreError.notFound) { try store.createFolder(workspaceID: UUID(), parentFolderID: nil, title: "x") }
    }

    @Test func deleteFolderKeepsTabs() throws {
        let (store, _, _, profile, ws) = try fixture()
        let before = try open(store, "https://before.com", in: ws)
        try store.pinTab(before.id, folderID: nil)
        let folder = try store.createFolder(workspaceID: ws.id, parentFolderID: nil, title: "F")
        let after = try open(store, "https://after.com", in: ws)
        let t1 = try open(store, "https://t1.com", in: ws)
        let t2 = try open(store, "https://t2.com", in: ws)
        try store.pinTab(t1.id, folderID: folder.id)
        try store.pinTab(t2.id, folderID: folder.id)
        try store.pinTab(after.id, folderID: nil)
        try store.deleteFolder(folder.id)
        #expect(tabIDs(try store.pinnedItems(workspaceID: ws.id)) == [before.id, t1.id, t2.id, after.id])
        #expect(try store.archivedTabs(profileID: profile.id).isEmpty)
    }

    @Test func deleteTopFolderMovesSubfolderToRootWithItsTabs() throws {
        let (store, _, _, _, ws) = try fixture()
        let top = try store.createFolder(workspaceID: ws.id, parentFolderID: nil, title: "Top")
        let sub = try store.createFolder(workspaceID: ws.id, parentFolderID: top.id, title: "Sub")
        let loose = try open(store, "https://loose.com", in: ws)
        let inSub = try open(store, "https://insub.com", in: ws)
        try store.pinTab(loose.id, folderID: top.id)
        try store.pinTab(inSub.id, folderID: sub.id)
        try store.deleteFolder(top.id)
        let items = try store.pinnedItems(workspaceID: ws.id)
        #expect(items.count == 2)
        guard case .folder(let movedSub, let children) = items[0] else { Issue.record("expected sub-folder first"); return }
        #expect(movedSub.id == sub.id && movedSub.parentFolderID == nil)
        #expect(tabIDs(children) == [inSub.id])
        #expect(tabIDs([items[1]]) == [loose.id])
    }

    @Test func deleteNestedFolderMovesTabsToParentFolder() throws {
        let (store, _, _, _, ws) = try fixture()
        let top = try store.createFolder(workspaceID: ws.id, parentFolderID: nil, title: "Top")
        let inner = try store.createFolder(workspaceID: ws.id, parentFolderID: top.id, title: "Inner")
        let a = try open(store, "https://a.com", in: ws)
        try store.pinTab(a.id, folderID: inner.id)
        try store.deleteFolder(inner.id)
        guard case .folder(_, let children) = try #require(store.pinnedItems(workspaceID: ws.id).first) else { Issue.record("no folder"); return }
        #expect(tabIDs(children) == [a.id])
    }

    @Test func essentialsAreProfileWide() throws {
        let (store, _, _, profile, ws) = try fixture()
        let other = try store.createWorkspace(profileID: profile.id, name: "Other", icon: "star", colorHex: "#000000")
        let tab = try open(store, "https://a.com", in: ws)
        let second = try open(store, "https://b.com", in: ws)
        try store.makeEssential(tab.id)
        try store.pinTab(second.id, folderID: nil)
        try store.makeEssential(second.id)
        #expect(try store.essentials(profileID: profile.id).map(\.id) == [tab.id, second.id])
        for workspace in [ws, other] {
            #expect(try store.pinnedItems(workspaceID: workspace.id).isEmpty)
            #expect(try store.regularTabs(workspaceID: workspace.id).isEmpty)
        }
        let essential = try #require(try store.essentials(profileID: profile.id).first)
        #expect(essential.pinnedURL == "https://a.com")
    }

    @Test func removePinnedArchives() throws {
        let (store, database, _, profile, ws) = try fixture()
        let tab = try open(store, "https://a.com", in: ws)
        try store.pinTab(tab.id, folderID: nil)
        try store.removePinnedTab(tab.id)
        let archived = try #require(try store.archivedTabs(profileID: profile.id).first)
        #expect(archived.url == "https://a.com")
        #expect(archived.workspaceID == ws.id)
        #expect(try store.pinnedItems(workspaceID: ws.id).isEmpty)
        #expect(try database.writer.read { db in try Slot.fetchCount(db) } == 0)
        #expect(throws: StoreError.notFound) { try store.removePinnedTab(tab.id) }
    }

    @Test func removeEssentialArchivesWithoutWorkspace() throws {
        let (store, _, _, profile, ws) = try fixture()
        let tab = try open(store, "https://a.com", in: ws)
        try store.makeEssential(tab.id)
        try store.removeEssential(tab.id)
        let archived = try #require(try store.archivedTabs(profileID: profile.id).first)
        #expect(archived.url == "https://a.com")
        #expect(archived.workspaceID == nil)
        #expect(try store.essentials(profileID: profile.id).isEmpty)
    }

    @Test func unpinMovesToRegularTop() throws {
        let (store, _, _, _, ws) = try fixture()
        let a = try open(store, "https://a.com", in: ws)
        let b = try open(store, "https://b.com", in: ws)
        try store.pinTab(b.id, folderID: nil)
        try store.unpinTab(b.id)
        let regular = try store.regularTabs(workspaceID: ws.id)
        #expect(regular.map(\.id) == [b.id, a.id])
        #expect(regular[0].pinnedURL == nil)
        #expect(try store.pinnedItems(workspaceID: ws.id).isEmpty)
        #expect(throws: StoreError.notPinned) { try store.unpinTab(a.id) }
    }

    @Test func newPinnedItemsAppendAfterFoldersAndTabs() throws {
        let (store, _, _, _, ws) = try fixture()
        let a = try open(store, "https://a.com", in: ws)
        let b = try open(store, "https://b.com", in: ws)
        try store.pinTab(a.id, folderID: nil)
        let folder = try store.createFolder(workspaceID: ws.id, parentFolderID: nil, title: "F")
        try store.pinTab(b.id, folderID: nil)
        let items = try store.pinnedItems(workspaceID: ws.id)
        #expect(items.count == 3)
        guard case .folder(let f, _) = items[1] else { Issue.record("folder not second"); return }
        #expect(f.id == folder.id)
        #expect(tabIDs([items[0], items[2]]) == [a.id, b.id])
    }

    @Test func pinIntoForeignOrUnknownFolderThrowsNotFound() throws {
        let (store, _, _, profile, ws) = try fixture()
        let other = try store.createWorkspace(profileID: profile.id, name: "O", icon: "star", colorHex: "#000000")
        let foreign = try store.createFolder(workspaceID: other.id, parentFolderID: nil, title: "F")
        let tab = try open(store, "https://a.com", in: ws)
        #expect(throws: StoreError.notFound) { try store.pinTab(tab.id, folderID: foreign.id) }
        #expect(throws: StoreError.notFound) { try store.pinTab(tab.id, folderID: UUID()) }
        #expect(throws: StoreError.notFound) { try store.pinTab(UUID(), folderID: nil) }
    }
}
