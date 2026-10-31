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

    @Test func resetRestoresPinnedIcon() throws {
        let (store, _, _, _, ws) = try fixture()
        let tab = try open(store, "https://a.com", in: ws)
        try store.updateNavigation(tabID: tab.id, url: "https://a.com", title: "A", faviconURL: "https://a.com/icon.png", interactionState: nil)
        try store.pinTab(tab.id, folderID: nil)
        try store.updateNavigation(tabID: tab.id, url: "https://b.com", title: "B", faviconURL: "https://b.com/icon.png", interactionState: nil)
        try store.resetPinnedTab(tab.id)
        guard case .tab(let reset) = try #require(store.pinnedItems(workspaceID: ws.id).first) else { Issue.record("not a tab"); return }
        #expect(reset.pinnedFaviconURL == "https://a.com/icon.png")
        #expect(reset.faviconURL == "https://a.com/icon.png")
    }

    @Test func pinnedIconFollowsPinnedPage() throws {
        let (store, _, _, profile, ws) = try fixture()
        let essential = try open(store, "https://e.com", in: ws)
        try store.updateNavigation(tabID: essential.id, url: "https://e.com", title: "E", faviconURL: "https://e.com/i.png", interactionState: nil)
        try store.makeEssential(essential.id)
        #expect(try store.essentials(profileID: profile.id).first?.pinnedFaviconURL == "https://e.com/i.png")

        let moved = try open(store, "https://m.com", in: ws)
        try store.updateNavigation(tabID: moved.id, url: "https://m.com", title: "M", faviconURL: "https://m.com/i.png", interactionState: nil)
        try store.moveTab(moved.id, toWorkspace: ws.id, section: .pinned, folderID: nil, after: nil)
        guard case .tab(let pinned) = try #require(store.pinnedItems(workspaceID: ws.id).first) else { Issue.record("not a tab"); return }
        #expect(pinned.pinnedFaviconURL == "https://m.com/i.png")

        try store.moveTab(moved.id, toWorkspace: ws.id, section: .regular, folderID: nil, after: nil)
        try store.moveTab(essential.id, toWorkspace: ws.id, section: .pinned, folderID: nil, after: nil)
        try store.unpinTab(essential.id)
        let regular = try store.regularTabs(workspaceID: ws.id)
        #expect(regular.count == 2)
        #expect(regular.allSatisfy { $0.pinnedFaviconURL == nil && $0.pinnedURL == nil })
    }

    @Test func removingDriftedPinnedOrEssentialArchivesPinnedPage() throws {
        let (store, _, _, profile, ws) = try fixture()
        let pinned = try open(store, "https://p.com", in: ws)
        let essential = try open(store, "https://e.com", in: ws)
        try store.updateNavigation(tabID: pinned.id, url: "https://p.com", title: "P", faviconURL: "https://p.com/i.png", interactionState: nil)
        try store.updateNavigation(tabID: essential.id, url: "https://e.com", title: "E", faviconURL: "https://e.com/i.png", interactionState: nil)
        try store.pinTab(pinned.id, folderID: nil)
        try store.makeEssential(essential.id)
        try store.updateNavigation(tabID: pinned.id, url: "https://p.com/drift", title: "PD", faviconURL: nil, interactionState: nil)
        try store.updateNavigation(tabID: essential.id, url: "https://e.com/drift", title: "ED", faviconURL: nil, interactionState: nil)
        try store.removePinnedTab(pinned.id)
        try store.removeEssential(essential.id)
        let archived = try store.archivedTabs(profileID: profile.id)
        let pinnedRow = try #require(archived.first { $0.url == "https://p.com/drift" })
        let essentialRow = try #require(archived.first { $0.url == "https://e.com/drift" })
        #expect((pinnedRow.pinnedURL, pinnedRow.pinnedTitle, pinnedRow.pinnedFaviconURL) == ("https://p.com", "P", "https://p.com/i.png"))
        #expect((essentialRow.pinnedURL, essentialRow.pinnedTitle, essentialRow.pinnedFaviconURL) == ("https://e.com", "E", "https://e.com/i.png"))
        // Restore yields a regular tab at the top, at the drifted page, and archives the pinned page it can no longer hold.
        let restored = try store.restoreArchivedTab(pinnedRow.id, workspaceID: ws.id)
        #expect(restored.url == "https://p.com/drift" && restored.pinnedURL == nil)
        #expect(try store.regularTabs(workspaceID: ws.id).first?.id == restored.id)
        let after = try store.archivedTabs(profileID: profile.id)
        let rescued = try #require(after.first { $0.url == "https://p.com" })
        #expect((rescued.title, rescued.faviconURL, rescued.pinnedURL) == ("P", "https://p.com/i.png", nil))
        #expect(rescued.workspaceID == ws.id && rescued.containerID == pinnedRow.containerID)
        #expect(after.first { $0.id == pinnedRow.id } == nil)
    }

    @Test func restoringADriftedEssentialArchivesItsPinnedPage() throws {
        let (store, _, _, profile, ws) = try fixture()
        let essential = try open(store, "https://e.com", in: ws)
        try store.updateNavigation(tabID: essential.id, url: "https://e.com", title: "E", faviconURL: nil, interactionState: nil)
        try store.makeEssential(essential.id)
        try store.updateNavigation(tabID: essential.id, url: "https://e.com/drift", title: "ED", faviconURL: nil, interactionState: nil)
        try store.removeEssential(essential.id)
        let row = try #require(try store.archivedTabs(profileID: profile.id).first { $0.url == "https://e.com/drift" })
        _ = try store.restoreArchivedTab(row.id, workspaceID: ws.id)
        let after = try store.archivedTabs(profileID: profile.id)
        #expect(after.map(\.url) == ["https://e.com"])
        #expect(after.first?.title == "E")
    }

    @Test func restoringANonDriftedPinnedRowArchivesNothing() throws {
        let (store, _, _, profile, ws) = try fixture()
        let pinned = try open(store, "https://p.com", in: ws)
        try store.updateNavigation(tabID: pinned.id, url: "https://p.com", title: "P", faviconURL: nil, interactionState: nil)
        try store.pinTab(pinned.id, folderID: nil)
        try store.removePinnedTab(pinned.id)
        let row = try #require(try store.archivedTabs(profileID: profile.id).first)
        #expect(row.pinnedURL == nil || row.pinnedURL == row.url)
        _ = try store.restoreArchivedTab(row.id, workspaceID: ws.id)
        #expect(try store.archivedTabs(profileID: profile.id).isEmpty)
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
        let pinnedAfterClose = try store.pinnedItems(workspaceID: ws.id)
        #expect(tabIDs(pinnedAfterClose) == [tab.id])
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

    /// In-folder indices (0, 1, 2) collide with the root tab X (1), so plain ON DELETE SET NULL would give [t1, X, t2, t3].
    @Test func deleteFolderKeepsTabs() throws {
        let (store, _, _, profile, ws) = try fixture()
        let folder = try store.createFolder(workspaceID: ws.id, parentFolderID: nil, title: "F") // root 0
        let x = try open(store, "https://x.com", in: ws)
        try store.pinTab(x.id, folderID: nil) // root 1
        var inside: [UUID] = []
        for name in ["t1", "t2", "t3"] {
            let tab = try open(store, "https://\(name).com", in: ws)
            try store.pinTab(tab.id, folderID: folder.id) // 0, 1, 2
            inside.append(tab.id)
        }
        try store.deleteFolder(folder.id)
        let pinnedAfterDelete = try store.pinnedItems(workspaceID: ws.id)
        #expect(tabIDs(pinnedAfterDelete) == inside + [x.id])
        #expect(try store.archivedTabs(profileID: profile.id).isEmpty)
    }

    /// Top holds [loose1 0, Sub 1, loose2 2] while root tab X sits at 1; SET NULL alone would not keep Sub between the loose tabs.
    @Test func deleteTopFolderMovesSubfolderToRootWithItsTabs() throws {
        let (store, _, _, _, ws) = try fixture()
        let top = try store.createFolder(workspaceID: ws.id, parentFolderID: nil, title: "Top") // root 0
        let x = try open(store, "https://x.com", in: ws)
        try store.pinTab(x.id, folderID: nil) // root 1
        let loose1 = try open(store, "https://loose1.com", in: ws)
        try store.pinTab(loose1.id, folderID: top.id) // 0
        let sub = try store.createFolder(workspaceID: ws.id, parentFolderID: top.id, title: "Sub") // 1
        let loose2 = try open(store, "https://loose2.com", in: ws)
        try store.pinTab(loose2.id, folderID: top.id) // 2
        let inSub = try open(store, "https://insub.com", in: ws)
        try store.pinTab(inSub.id, folderID: sub.id)
        try store.deleteFolder(top.id)
        let items = try store.pinnedItems(workspaceID: ws.id)
        #expect(items.count == 4)
        #expect(tabIDs([items[0]]) == [loose1.id])
        guard case .folder(let movedSub, let children) = items[1] else { Issue.record("expected sub-folder second"); return }
        #expect(movedSub.id == sub.id && movedSub.parentFolderID == nil)
        #expect(tabIDs(children) == [inSub.id])
        #expect(tabIDs([items[2], items[3]]) == [loose2.id, x.id])
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
