import Foundation
import Testing
@testable import StaveCore

@MainActor
private final class FakePages: PageLifecycle {
    var closed: [UUID] = []
    var unloaded: [UUID] = []
    var deselected: [UUID] = []
    func tabClosed(_ id: UUID) { closed.append(id) }
    func tabUnloaded(_ id: UUID) { unloaded.append(id) }
    func tabDeselected(_ id: UUID) { deselected.append(id) }
    var navigated: [UUID] = []
    func tabNavigated(_ id: UUID) { navigated.append(id) }
}

@MainActor
struct PageLifecycleTests {
    @MainActor private struct World {
        let store: OrganizationStore
        let revision = StoreRevision()
        let livePages = LivePageRegistry()
        let profile: Profile
        let home: Workspace

        func window(selected: UUID? = nil) throws -> BrowserWindowModel {
            try BrowserWindowModel(
                store: store, revision: revision, livePages: livePages,
                state: WindowState(profileID: profile.id, workspaceID: home.id, selectedTabID: selected, frame: "", sortIndex: 0)
            )
        }

        func tab(_ name: String) throws -> Tab {
            try store.openTab(url: "https://example.com/\(name)", title: name, workspaceID: home.id, origin: .commandBar, containerID: nil, edge: .bottom)
        }
    }

    private func makeWorld() throws -> World {
        let clock = TestClock()
        let (store, _, _) = try makeTempStore(now: clock.now)
        let profile = try store.ensureDefaultProfile()
        let home = try #require(try store.workspaces(profileID: profile.id).first)
        return World(store: store, profile: profile, home: home)
    }

    @Test func closingRegularTabReportsClosed() throws {
        let world = try makeWorld()
        let tab = try world.tab("a")
        let window = try world.window()
        let pages = FakePages()
        window.pages = pages
        window.close(tab.id)
        #expect(pages.closed == [tab.id])
        #expect(pages.unloaded.isEmpty)
    }

    @Test func closingSelectedEssentialHandsPageToWaiter() throws {
        let world = try makeWorld()
        let essential = try world.tab("e")
        try world.store.makeEssential(essential.id)
        let w1 = try world.window(selected: essential.id)
        let w2 = try world.window(selected: essential.id)
        let pages = FakePages()
        w1.pages = pages
        #expect(world.livePages.owner(of: essential.id) == w1.windowID)
        w1.close(essential.id)
        #expect(world.livePages.owner(of: essential.id) == w2.windowID)
        #expect(pages.unloaded.isEmpty)
        #expect(pages.closed.isEmpty)
    }

    @Test func closingUnwatchedPinnedUnloads() throws {
        let world = try makeWorld()
        let tab = try world.tab("p")
        try world.store.pinTab(tab.id, folderID: nil)
        let window = try world.window()
        let pages = FakePages()
        window.pages = pages
        window.close(tab.id)
        #expect(pages.unloaded == [tab.id])
        #expect(pages.closed.isEmpty)
    }

    @Test func removingPinnedAndEssentialReportsClosed() throws {
        let world = try makeWorld()
        let pinned = try world.tab("p")
        let essential = try world.tab("e")
        try world.store.pinTab(pinned.id, folderID: nil)
        try world.store.makeEssential(essential.id)
        let window = try world.window()
        let pages = FakePages()
        window.pages = pages
        window.removePinned(pinned.id)
        window.removeEssential(essential.id)
        #expect(pages.closed == [pinned.id, essential.id])
    }

    @Test func deletingWorkspaceReportsEachArchivedTab() throws {
        let world = try makeWorld()
        let other = try world.store.createWorkspace(profileID: world.profile.id, name: "Two", icon: "", colorHex: "#FFFFFF")
        let a = try world.store.openTab(url: "https://example.com/a", title: "a", workspaceID: other.id, origin: .commandBar, containerID: nil, edge: .bottom)
        let b = try world.store.openTab(url: "https://example.org/b", title: "b", workspaceID: other.id, origin: .commandBar, containerID: nil, edge: .bottom)
        try world.store.pinTab(b.id, folderID: nil)
        let window = try world.window()
        let pages = FakePages()
        window.pages = pages
        window.deleteWorkspace(other.id)
        #expect(Set(pages.closed) == [a.id, b.id])
        #expect(pages.closed.count == 2)
    }

    @Test func selectionChangeReportsDeselected() throws {
        let world = try makeWorld()
        let first = try world.tab("a")
        let second = try world.tab("b")
        let window = try world.window(selected: first.id)
        let pages = FakePages()
        window.pages = pages
        window.select(second.id)
        #expect(pages.deselected == [first.id])
        window.select(nil)
        #expect(pages.deselected == [first.id, second.id])
    }

    @Test func linkedTabOpensBelowOpenerAndSelects() throws {
        let world = try makeWorld()
        let opener = try world.tab("opener")
        _ = try world.tab("other")
        let window = try world.window(selected: opener.id)
        let child = try #require(window.openLinkedTab(url: "https://example.net/child", opener: opener.id, select: true))
        let ids = window.rows.compactMap { row -> UUID? in if case .tab(let id) = row.id { id } else { nil } }
        let openerIndex = try #require(ids.firstIndex(of: opener.id))
        #expect(ids[openerIndex + 1] == child)
        #expect(window.selectedTabID == child)

        let quiet = try #require(window.openLinkedTab(url: "https://example.net/quiet", opener: opener.id, select: false))
        #expect(window.selectedTabID == child)
        #expect(window.rows.contains { $0.id == .tab(quiet) })

        window.close(opener.id)
        #expect(window.openLinkedTab(url: "https://example.net/x", opener: opener.id, select: true) == nil)
    }

    @Test func pageMenuState() {
        let none = PageMenuState.from(status: nil, sheetOpen: false)
        #expect(none == PageMenuState(canGoBack: false, canGoForward: false, canReload: false, canStop: false, blockingOn: nil))
        let loading = PageMenuState.from(status: PageStatusSummary(isLoading: true, canGoBack: true, canGoForward: false, hasPage: true, blockingOn: true), sheetOpen: false)
        #expect(loading.canStop)
        #expect(loading.canGoBack)
        #expect(loading.blockingOn == true)
        let sheet = PageMenuState.from(status: PageStatusSummary(isLoading: true, canGoBack: true, canGoForward: true, hasPage: true, blockingOn: false), sheetOpen: true)
        #expect(sheet == none)
        let idle = PageMenuState.from(status: PageStatusSummary(hasPage: true), sheetOpen: false)
        #expect(idle.canReload && !idle.canStop)
        let empty = PageMenuState.from(status: PageStatusSummary(isLoading: true, canGoBack: true, hasPage: false), sheetOpen: false)
        #expect(empty == none)
    }

    @Test func movingSelectedTabAwayReportsDeselectedOnly() throws {
        let world = try makeWorld()
        let other = try world.store.createWorkspace(profileID: world.profile.id, name: "Two", icon: "", colorHex: "#FFFFFF")
        let tab = try world.tab("a")
        let window = try world.window(selected: tab.id)
        let pages = FakePages()
        window.pages = pages
        window.apply(.tab(tab.id, workspaceID: other.id, section: .regular, folderID: nil, after: nil))
        #expect(window.selectedTabID == nil)
        #expect(pages.closed.isEmpty)
        #expect(pages.unloaded.isEmpty)
        #expect(pages.deselected == [tab.id])
    }

    @Test func typedAddressGoesToLivePageWithoutStoreWrite() throws {
        let world = try makeWorld()
        let tab = try world.tab("a")
        let window = try world.window(selected: tab.id)
        var loads: [(UUID, String)] = []
        window.loadTyped = { id, url in loads.append((id, url)); return true }
        _ = window.perform(.open(url: "https://example.org/typed"), mode: .currentTab, target: tab.id)
        #expect(loads.map(\.0) == [tab.id])
        #expect(loads.map(\.1) == ["https://example.org/typed"])
        // The page's commit writes the address, not the command bar.
        #expect(window.selectedTab?.url == "https://example.com/a")
    }

    @Test func typedAddressWithoutLivePageIsStored() throws {
        let world = try makeWorld()
        let tab = try world.tab("a")
        let window = try world.window(selected: tab.id)
        window.loadTyped = { _, _ in false }
        _ = window.perform(.open(url: "https://example.org/typed"), mode: .currentTab, target: tab.id)
        #expect(window.selectedTab?.url == "https://example.org/typed")
    }

    @Test func typedNewTabIsStoredSelectedAndHandedToPage() throws {
        let world = try makeWorld()
        let window = try world.window()
        var loads: [(UUID, String)] = []
        window.loadTyped = { id, url in loads.append((id, url)); return true }
        _ = window.perform(.open(url: "https://example.net/"), mode: .newTab)
        let selected = try #require(window.selectedTab)
        #expect(selected.url == "https://example.net/")
        #expect(loads.map(\.0) == [selected.id])
        #expect(loads.map(\.1) == ["https://example.net/"])
    }

    @Test func linkedTabKeepsOpenersContainerAndStore() throws {
        let world = try makeWorld()
        let container = try world.store.createContainer(profileID: world.profile.id, name: "C", colorHex: "#000000")
        let opener = try world.store.openTab(url: "https://example.com/a", title: "a", workspaceID: world.home.id, origin: .commandBar, containerID: container.id, edge: .bottom)
        let plain = try world.tab("b")
        let window = try world.window(selected: opener.id)
        let linked = try #require(window.openLinkedTab(url: "https://example.org/", opener: opener.id, select: false))
        let fromPlain = try #require(window.openLinkedTab(url: "https://example.net/", opener: plain.id, select: false))
        let stored = try #require(try world.store.regularTabs(workspaceID: world.home.id).first { $0.id == linked })
        #expect(stored.containerID == container.id)
        #expect(try world.store.dataStoreID(forTab: linked) == container.dataStoreID)
        #expect(try world.store.dataStoreID(forTab: fromPlain) == world.profile.dataStoreID)
    }

    @Test func backToPinnedPageTellsTheLivePage() throws {
        let world = try makeWorld()
        let tab = try world.tab("pinned")
        try world.store.pinTab(tab.id, folderID: nil)
        try world.store.updateNavigation(tabID: tab.id, url: "https://example.com/drifted", title: "d", faviconURL: nil, interactionState: Data([1]))
        let window = try world.window(selected: tab.id)
        let pages = FakePages()
        window.pages = pages
        window.resetPinned(tab.id)
        #expect(pages.navigated == [tab.id])
        #expect(window.selectedTab?.url == "https://example.com/pinned")
        #expect(window.selectedTab?.interactionState == nil)
        // A regular tab can't be reset: nothing changes, nothing is reported.
        let regular = try world.tab("regular")
        window.resetPinned(regular.id)
        #expect(pages.navigated == [tab.id])
    }

    @Test func deleteWorkspaceWithPinnedInFolder() throws {
        let world = try makeWorld()
        let other = try world.store.createWorkspace(profileID: world.profile.id, name: "Two", icon: "", colorHex: "#FFFFFF")
        let folder = try world.store.createFolder(workspaceID: other.id, parentFolderID: nil, title: "Folder")
        let inFolder = try world.store.openTab(url: "https://example.org/in-folder", title: "In folder", workspaceID: other.id, origin: .commandBar, containerID: nil, edge: .bottom)
        try world.store.pinTab(inFolder.id, folderID: folder.id)
        let window = try world.window()
        let pages = FakePages()
        window.pages = pages
        window.deleteWorkspace(other.id)
        #expect(pages.closed == [inFolder.id])
        let archived = try world.store.archivedTabs(profileID: world.profile.id)
        #expect(archived.map(\.url) == ["https://example.org/in-folder"])
        #expect(archived.map(\.pinnedURL) == ["https://example.org/in-folder"])
        #expect(try world.store.workspaces(profileID: world.profile.id).map(\.id) == [world.home.id])
    }

    private struct ReadFailure: Error {}

    /// The store's own read throws (here the container table is gone behind the window's back): the failure shows, and the window keeps
    /// the last snapshot and selection rather than showing a half-read sidebar.
    @Test func reloadReportsAReadFailure() throws {
        let (store, database, _) = try makeTempStore(now: TestClock().now)
        let profile = try store.ensureDefaultProfile()
        let home = try #require(try store.workspaces(profileID: profile.id).first)
        let world = World(store: store, profile: profile, home: home)
        let tab = try world.tab("a")
        let window = try world.window(selected: tab.id)
        let pages = FakePages()
        window.pages = pages
        let before = window.snapshot
        let rowsBefore = window.rows
        _ = try world.tab("b") // a change the failed read must not half-show
        try database.writer.write { db in try db.execute(sql: "ALTER TABLE container RENAME TO containerGone") }
        window.reload()
        #expect(window.lastError == StoreErrorText.fallback)
        #expect(window.snapshot == before)
        #expect(window.rows == rowsBefore)
        #expect(window.selectedTabID == tab.id)
        #expect(pages.deselected.isEmpty)
        #expect(pages.closed.isEmpty)
    }

    /// The sidebar read succeeds and the selected tab is gone from it, but asking whether it still exists fails: the failure shows, and
    /// the selection clears without a deselect (the tab may be gone, so nothing tells its page it is merely hidden).
    @Test func reloadReportsATabExistsFailure() throws {
        let world = try makeWorld()
        let other = try world.store.createWorkspace(profileID: world.profile.id, name: "Two", icon: "", colorHex: "#FFFFFF")
        let tab = try world.tab("a")
        let window = try world.window(selected: tab.id)
        let pages = FakePages()
        window.pages = pages
        window.readTabExists = { _ in throw ReadFailure() }
        try world.store.moveTab(tab.id, toWorkspace: other.id, section: .regular, folderID: nil, after: nil) // behind the window's back
        window.reload()
        #expect(window.selectedTabID == nil)
        #expect(window.lastError == StoreErrorText.fallback)
        #expect(pages.deselected.isEmpty)
        #expect(pages.closed.isEmpty)
    }

    /// The control for the test above: with the existence check working, a tab moved away is reported deselected and no error shows.
    @Test func reloadReportsTheDeselectOfATabMovedAway() throws {
        let world = try makeWorld()
        let other = try world.store.createWorkspace(profileID: world.profile.id, name: "Two", icon: "", colorHex: "#FFFFFF")
        let tab = try world.tab("a")
        let window = try world.window(selected: tab.id)
        let pages = FakePages()
        window.pages = pages
        try world.store.moveTab(tab.id, toWorkspace: other.id, section: .regular, folderID: nil, after: nil)
        window.reload()
        #expect(window.selectedTabID == nil)
        #expect(window.lastError == nil)
        #expect(pages.deselected == [tab.id])
    }

    /// Without the list of tabs to archive, their pages would never hear `tabClosed`: the delete stops before it starts.
    @Test func deleteWorkspaceReadFailureDeletesNothing() throws {
        let world = try makeWorld()
        let other = try world.store.createWorkspace(profileID: world.profile.id, name: "Two", icon: "", colorHex: "#FFFFFF")
        let tab = try world.store.openTab(url: "https://example.org/a", title: "a", workspaceID: other.id, origin: .commandBar, containerID: nil, edge: .bottom)
        let window = try BrowserWindowModel(
            store: world.store, revision: world.revision, livePages: world.livePages,
            state: WindowState(profileID: world.profile.id, workspaceID: other.id, selectedTabID: tab.id, frame: "", sortIndex: 0)
        )
        let pages = FakePages()
        window.pages = pages
        window.readWorkspaceTabIDs = { _ in throw ReadFailure() }
        window.deleteWorkspace(other.id)
        #expect(window.lastError == StoreErrorText.fallback)
        #expect(try world.store.workspaces(profileID: world.profile.id).map(\.id) == [world.home.id, other.id])
        #expect(window.snapshot.workspace.id == other.id)
        #expect(window.selectedTabID == tab.id)
        #expect(try world.store.archivedTabs(profileID: world.profile.id).isEmpty)
        #expect(pages.closed.isEmpty)
        #expect(pages.deselected.isEmpty)
    }
}
