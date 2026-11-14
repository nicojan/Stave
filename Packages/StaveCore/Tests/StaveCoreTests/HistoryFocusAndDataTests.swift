import Foundation
import GRDB
import Testing
@testable import StaveCore

/// Records each website-data removal the model asks for, and fails when told to.
@MainActor
private final class FakeWebsiteDataRemover: WebsiteDataRemoving {
    struct Call: Equatable {
        var storeIDs: [UUID]
        var since: Date
    }

    struct Failure: Error {}

    var calls: [Call] = []
    var fails = false

    func removeWebsiteData(storeIDs: [UUID], since: Date) async throws {
        calls.append(Call(storeIDs: storeIDs, since: since))
        if fails { throw Failure() }
    }
}

/// The History view's focus rules (⌘Y focuses its search field; closing it gives the page the keyboard back), Clear History's
/// "Also remove cookies and website data" (question 16, answered 2026-11-14), and launch maintenance surviving a failed history trim.
@MainActor
struct HistoryFocusAndDataTests {
    private struct World {
        let store: OrganizationStore
        let database: StaveDatabase
        let clock: TestClock
        let profile: Profile
        let home: Workspace
    }

    private func makeWorld() throws -> World {
        let clock = TestClock()
        let (store, database, _) = try makeTempStore(now: clock.now)
        let profile = try store.ensureDefaultProfile()
        let home = try #require(try store.workspaces(profileID: profile.id).first)
        return World(store: store, database: database, clock: clock, profile: profile, home: home)
    }

    private func makeModel(_ world: World, selected: UUID? = nil) throws -> BrowserWindowModel {
        try BrowserWindowModel(
            store: world.store, revision: StoreRevision(), livePages: LivePageRegistry(),
            state: WindowState(profileID: world.profile.id, workspaceID: world.home.id, selectedTabID: selected, frame: "", sortIndex: 0)
        )
    }

    private func visitCount(_ world: World) throws -> Int {
        try world.database.writer.read { db in try HistoryVisit.fetchCount(db) }
    }

    // MARK: - Focus

    /// ⌘Y asks for the search field every time it shows the view, whatever held the keyboard before (the sidebar list after ⌘L, Escape).
    @Test func showingHistoryAsksForTheSearchField() throws {
        let world = try makeWorld()
        let model = try makeModel(world)
        #expect(model.focusRequest == nil)
        model.toggleHistory()
        let first = try #require(model.focusRequest)
        #expect(first.target == .historySearch)
        model.toggleHistory()
        model.toggleHistory()
        let second = try #require(model.focusRequest)
        #expect(second.target == .historySearch)
        #expect(second != first) // a fresh request each time, so a repeat is honoured again
        model.showHistory() // already showing: nothing new to honour
        #expect(model.focusRequest == second)
    }

    /// Every way the view closes asks for the page (Safari puts the keyboard back in the page); an action that leaves it showing does not,
    /// and hiding a view that isn't showing asks for nothing.
    @Test func closingHistoryAsksForThePage() throws {
        let world = try makeWorld()
        let first = try world.store.openTab(url: "https://example.com/1", title: "1", workspaceID: world.home.id, origin: .commandBar, containerID: nil, edge: .bottom)
        let second = try world.store.openTab(url: "https://example.com/2", title: "2", workspaceID: world.home.id, origin: .commandBar, containerID: nil, edge: .bottom)
        let work = try world.store.createWorkspace(profileID: world.profile.id, name: "Work", icon: "briefcase", colorHex: "#FFFFFF")
        let other = try world.store.createProfile(name: "Other")
        let model = try makeModel(world, selected: first.id)
        model.reload() // picks up the new profile

        var seen: [WindowFocusRequest] = []
        func expectPageRequest(_ comment: Comment, _ close: () -> Void) {
            model.showHistory()
            close()
            #expect(!model.isShowingHistory, comment)
            let request = model.focusRequest
            #expect(request?.target == .page, comment)
            if let request {
                #expect(!seen.contains(request), comment)
                seen.append(request)
            }
        }

        expectPageRequest("⌘Y again") { model.toggleHistory() }
        expectPageRequest("the selected tab") { model.select(first.id) }
        expectPageRequest("another tab") { model.select(second.id) }
        expectPageRequest("a workspace") { model.switchWorkspace(to: work.id) }
        expectPageRequest("⌘T's new tab") { _ = model.openTab(url: "") }
        expectPageRequest("a command-bar result") { _ = model.perform(.open(url: "https://example.net/"), mode: .currentTab, target: nil) }
        expectPageRequest("a visit") {
            model.openVisit(HistoryVisit(profileID: world.profile.id, url: "https://example.org/v", title: "V", visitedAt: world.clock.date))
        }
        expectPageRequest("a profile") { model.switchProfile(to: other.id) }

        // An action keeps the view, and its search-field request stands.
        model.showHistory()
        let shown = model.focusRequest
        _ = model.perform(.action(.toggleCompactMode), mode: .newTab, target: nil)
        #expect(model.isShowingHistory)
        #expect(model.focusRequest == shown)

        // Nothing showing: nothing to give back.
        model.hideHistory()
        let afterHide = model.focusRequest
        model.hideHistory()
        model.select(first.id)
        #expect(model.focusRequest == afterHide)
    }

    /// A click on a sidebar row: on the tab already selected (where the list's selection doesn't change, so its change handler never runs)
    /// it still closes the History view and gives the page the keyboard, as any tab does; a folder row keeps the view.
    @Test func clickingTheSelectedRowLeavesHistory() throws {
        let world = try makeWorld()
        let tab = try world.store.openTab(url: "https://example.com/1", title: "1", workspaceID: world.home.id, origin: .commandBar, containerID: nil, edge: .bottom)
        let folder = try world.store.createFolder(workspaceID: world.home.id, parentFolderID: nil, title: "F")
        let model = try makeModel(world, selected: tab.id)
        model.sidebarHighlight = .tab(tab.id)

        model.showHistory()
        model.clickSidebarRow(.folder(folder.id))
        #expect(model.isShowingHistory) // a folder is not a page to return to
        #expect(model.focusRequest?.target == .historySearch)

        model.clickSidebarRow(.tab(tab.id))
        #expect(!model.isShowingHistory)
        #expect(model.focusRequest?.target == .page)
        #expect(model.selectedTabID == tab.id)

        // Without the view, a click on the selected row changes nothing.
        let settled = model.focusRequest
        model.clickSidebarRow(.tab(tab.id))
        #expect(model.focusRequest == settled)
        #expect(model.selectedTabID == tab.id)
    }

    // MARK: - Clear History and website data

    /// Review Focus 4: with the box ticked, every persistent store of the profile (its own, and each container's, whether a window has
    /// opened it or not) gets the removal from the range's start, and the archive and tabs are untouched; unticked, no store is asked.
    @Test func clearHistoryWebsiteDataKeepsArchiveAndTabs() async throws {
        let world = try makeWorld()
        let shop = try world.store.createContainer(profileID: world.profile.id, name: "Shop", colorHex: "#00FF00")
        let bank = try world.store.createContainer(profileID: world.profile.id, name: "Bank", colorHex: "#FF0000")
        let open = try world.store.openTab(url: "https://example.com/open", title: "Open", workspaceID: world.home.id, origin: .commandBar, containerID: shop.id, edge: .bottom)
        let closing = try world.store.openTab(url: "https://example.com/closed", title: "Closed", workspaceID: world.home.id, origin: .commandBar, containerID: nil, edge: .bottom)
        _ = try world.store.closeTab(closing.id)
        let pinned = try world.store.openTab(url: "https://example.com/pinned", title: "Pinned", workspaceID: world.home.id, origin: .commandBar, containerID: nil, edge: .bottom)
        try world.store.pinTab(pinned.id, folderID: nil)
        let now = world.clock.date

        let model = try makeModel(world, selected: open.id)
        let remover = FakeWebsiteDataRemover()
        model.websiteData = remover
        let sidebarBefore = try world.store.sidebarSnapshot(workspaceID: world.home.id)
        let archiveBefore = try world.store.archivedTabs(profileID: world.profile.id)
        #expect(archiveBefore.map(\.title) == ["Closed"]) // the control: there is an archive to lose

        func expectUntouched(_ comment: Comment) throws {
            #expect(try world.store.archivedTabs(profileID: world.profile.id) == archiveBefore, comment)
            #expect(try world.store.sidebarSnapshot(workspaceID: world.home.id) == sidebarBefore, comment)
            #expect(try world.store.tabExists(open.id), comment)
            #expect(try world.store.tabExists(pinned.id), comment)
            #expect(model.selectedTabID == open.id, comment)
        }

        let ranges: [(HistoryClearRange, Date)] = [
            (.lastHour, now.addingTimeInterval(-3600)),
            (.today, Calendar.current.startOfDay(for: now)),
            (.all, .distantPast),
        ]
        for (range, since) in ranges {
            try world.store.recordVisit(profileID: world.profile.id, url: "https://example.com/open", title: "Open", at: now)
            remover.calls = []
            await model.clearHistory(range, alsoWebsiteData: true, now: now, calendar: .current)
            let comment = Comment(rawValue: "\(range)")
            #expect(remover.calls == [.init(storeIDs: [world.profile.dataStoreID, bank.dataStoreID, shop.dataStoreID], since: since)], comment)
            #expect(try visitCount(world) == 0, comment)
            #expect(model.lastError == nil, comment)
            try expectUntouched(comment)
        }

        try world.store.recordVisit(profileID: world.profile.id, url: "https://example.com/open", title: "Open", at: now)
        remover.calls = []
        await model.clearHistory(.all, alsoWebsiteData: false, now: now)
        #expect(remover.calls.isEmpty)
        #expect(try visitCount(world) == 0)
        try expectUntouched("unticked")
    }


    @Test func clearHistoryLabels() {
        #expect(HistoryText.clearWebsiteDataCheckbox == "Also remove cookies and website data")
        #expect(HistoryText.clearWebsiteDataByDefault)
        #expect(!HistoryText.clearPromptMessage.contains("cookies stay"))
        #expect(HistoryText.clearPromptMessage.contains("cookies and other website data"))
        #expect(HistoryText.clearPromptMessage.contains("Your tabs, pinned tabs, archive and downloaded files stay."))
        #expect(!HistoryText.websiteDataNotRemoved.isEmpty)
    }

    /// The stores Clear History empties: the profile's own first, then each of its containers' (opened by a window or not), never another
    /// profile's. Private sessions have no row, so they are never listed.
    @Test func websiteDataStoresOfAProfile() throws {
        let world = try makeWorld()
        let work = try world.store.createContainer(profileID: world.profile.id, name: "Work", colorHex: "#FF0000")
        let bank = try world.store.createContainer(profileID: world.profile.id, name: "Bank", colorHex: "#00FF00")
        let other = try world.store.createProfile(name: "Other")
        let otherContainer = try world.store.createContainer(profileID: other.id, name: "Shop", colorHex: "#0000FF")

        let ids = try world.store.websiteDataStoreIDs(profileID: world.profile.id)
        #expect(ids == [world.profile.dataStoreID, bank.dataStoreID, work.dataStoreID])
        #expect(!ids.contains(other.dataStoreID))
        #expect(!ids.contains(otherContainer.dataStoreID))
        #expect(try world.store.websiteDataStoreIDs(profileID: other.id) == [other.dataStoreID, otherContainer.dataStoreID])
        #expect(throws: StoreError.notFound) { try world.store.websiteDataStoreIDs(profileID: UUID()) }
    }

    @Test func clearHistoryAlsoRemovesTheProfilesWebsiteData() async throws {
        let world = try makeWorld()
        let container = try world.store.createContainer(profileID: world.profile.id, name: "Work", colorHex: "#FF0000")
        let other = try world.store.createProfile(name: "Other")
        let tab = try world.store.openTab(url: "https://example.com/", title: "Tab", workspaceID: world.home.id, origin: .commandBar, containerID: nil, edge: .bottom)
        try world.store.recordVisit(profileID: world.profile.id, url: "https://example.com/", title: "A", at: world.clock.date)
        let model = try makeModel(world, selected: tab.id)
        let remover = FakeWebsiteDataRemover()
        model.websiteData = remover

        let now = world.clock.date
        await model.clearHistory(.lastHour, alsoWebsiteData: true, now: now)
        #expect(remover.calls == [.init(storeIDs: [world.profile.dataStoreID, container.dataStoreID], since: now.addingTimeInterval(-3600))])
        #expect(!(remover.calls.first?.storeIDs.contains(other.dataStoreID) ?? true))
        #expect(try visitCount(world) == 0)
        #expect(model.lastError == nil)
        #expect(model.selectedTab?.id == tab.id) // tabs stay

        await model.clearHistory(.all, alsoWebsiteData: true, now: now)
        #expect(remover.calls.last?.since == .distantPast)
    }

    @Test func clearHistoryWithoutTheBoxKeepsWebsiteData() async throws {
        let world = try makeWorld()
        try world.store.recordVisit(profileID: world.profile.id, url: "https://example.com/", title: "A", at: world.clock.date)
        let model = try makeModel(world)
        let remover = FakeWebsiteDataRemover()
        model.websiteData = remover
        await model.clearHistory(.all, alsoWebsiteData: false)
        #expect(remover.calls.isEmpty)
        #expect(try visitCount(world) == 0)
        #expect(model.lastError == nil)
    }

    /// A removal that fails is shown, never fatal and never silent; the history is cleared all the same.
    @Test func websiteDataFailureIsReported() async throws {
        let world = try makeWorld()
        try world.store.recordVisit(profileID: world.profile.id, url: "https://example.com/", title: "A", at: world.clock.date)
        let model = try makeModel(world)
        let remover = FakeWebsiteDataRemover()
        remover.fails = true
        model.websiteData = remover
        await model.clearHistory(.all, alsoWebsiteData: true)
        #expect(remover.calls.count == 1)
        #expect(model.lastError == HistoryText.websiteDataNotRemoved)
        #expect(try visitCount(world) == 0)

        // No remover to ask is a failure too, not a quiet skip.
        let bare = try makeModel(world)
        await bare.clearHistory(.all, alsoWebsiteData: true)
        #expect(bare.lastError == HistoryText.websiteDataNotRemoved)
    }

    // MARK: - Launch maintenance

    /// A history trim that fails is logged and launch goes on (reviewer Medium on Task 6): history is never worth refusing to start for.
    @Test func failedHistoryTrimDoesNotStopLaunch() throws {
        let world = try makeWorld()
        try world.database.writer.write { db in try db.drop(table: "historyVisit") }
        #expect(throws: (any Error).self) { try world.store.trimHistoryBySetting() } // the control: the trim itself does fail
        try world.store.launchMaintenance()
    }
}
