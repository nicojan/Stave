import Foundation
import Testing
@testable import StaveCore

@MainActor
struct CommandBarTests {
    @MainActor private struct World {
        let store: OrganizationStore
        let revision = StoreRevision()
        let livePages = LivePageRegistry()
        let clock: TestClock
        let profile: Profile
        let home: Workspace

        func window(selected: UUID? = nil) throws -> BrowserWindowModel {
            try BrowserWindowModel(
                store: store, revision: revision, livePages: livePages,
                state: WindowState(profileID: profile.id, workspaceID: home.id, selectedTabID: selected, frame: "", sortIndex: 0)
            )
        }

        @discardableResult
        func tab(_ title: String, in workspace: Workspace? = nil) throws -> Tab {
            clock.advance(by: 1)
            return try store.openTab(
                url: "https://example.com/\(title.replacingOccurrences(of: " ", with: "-"))", title: title,
                workspaceID: (workspace ?? home).id, origin: .commandBar, containerID: nil, edge: .bottom
            )
        }
    }

    private func makeWorld() throws -> World {
        let clock = TestClock()
        let (store, _, _) = try makeTempStore(now: clock.now)
        let profile = try store.ensureDefaultProfile()
        let home = try #require(try store.workspaces(profileID: profile.id).first)
        return World(store: store, clock: clock, profile: profile, home: home)
    }

    private func candidates(tabs titles: [String] = [], archived: [String] = [], workspaces: [Workspace] = [], actions: [CommandAction] = []) -> CommandCandidates {
        let slot = UUID()
        return CommandCandidates(
            tabs: titles.map { CommandTab(tab: Tab(slotID: slot, url: "https://example.com/x", title: $0), section: .regular, workspaceID: nil, workspaceName: nil) },
            archived: archived.map { ArchivedTab(profileID: UUID(), url: "https://example.org/y", title: $0) },
            workspaces: workspaces, actions: actions
        )
    }

    private func tabTitles(_ results: [CommandResult]) -> [String] {
        results.compactMap { if case .tab(let t) = $0 { t.tab.title } else { nil } }
    }

    // MARK: - Candidates

    @Test func candidatesCoverTheProfile() throws {
        let world = try makeWorld()
        try SampleOrganization.seed(into: world.store)
        let profile = try #require(try world.store.profiles().first)
        let found = try world.store.commandCandidates(profileID: profile.id)
        let sections = Set(found.tabs.map(\.section))
        #expect(sections == [.essential, .pinned, .regular])
        #expect(Set(found.tabs.compactMap(\.workspaceName)) == ["Home", "Work"])
        #expect(found.tabs.filter { $0.section == .essential }.allSatisfy { $0.workspaceID == nil })
        let dates = found.tabs.map(\.tab.lastActiveAt)
        #expect(dates == dates.sorted(by: >))
        #expect(found.archived.count == 2)
        #expect(found.workspaces.map(\.name) == ["Home", "Work"])
        #expect(found.actions.isEmpty)
    }

    @Test func archiveLimitIsRespected() throws {
        let world = try makeWorld()
        for name in ["a", "b", "c"] { _ = try world.store.closeTab(try world.tab(name).id) }
        let found = try world.store.commandCandidates(profileID: world.profile.id, archiveLimit: 2)
        #expect(found.archived.map(\.title) == ["c", "b"])
    }

    // MARK: - Search

    @Test func typedRowComesFirst() {
        let found = candidates(tabs: ["Example page"])
        #expect(CommandBarSearch.results(query: "exa", candidates: found).first == .search(query: "exa"))
        #expect(CommandBarSearch.results(query: "example.com", candidates: found).first == .open(url: "https://example.com"))
    }

    @Test func rankingOrder() {
        let found = candidates(tabs: ["Readocs", "My docs", "Docs"])
        #expect(tabTitles(CommandBarSearch.results(query: "doc", candidates: found)) == ["Docs", "My docs", "Readocs"])
    }

    @Test func kindOrderBreaksScoreTies() {
        let workspace = Workspace(profileID: UUID(), name: "Docs space", icon: "", colorHex: "#FFFFFF", sortIndex: 0)
        let found = candidates(tabs: ["Docs tab"], archived: ["Docs old"], workspaces: [workspace], actions: [.newWindow])
        let results = CommandBarSearch.results(query: "doc", candidates: found)
        #expect(results.dropFirst().map { r -> String in
            switch r {
            case .tab: "tab"
            case .workspace: "workspace"
            case .action: "action"
            case .archived: "archived"
            default: "other"
            }
        } == ["tab", "workspace", "archived"])
    }

    @Test func urlMatchesRankBelowTitleMatches() {
        let found = candidates(tabs: ["Zzz"]) // url is https://example.com/x
        #expect(tabTitles(CommandBarSearch.results(query: "example", candidates: found)) == ["Zzz"])
    }

    @Test func diacriticsIgnored() {
        let found = candidates(tabs: ["Café menu"])
        #expect(tabTitles(CommandBarSearch.results(query: "cafe", candidates: found)) == ["Café menu"])
        #expect(tabTitles(CommandBarSearch.results(query: "CAFÉ", candidates: found)) == ["Café menu"])
    }

    @Test func actionsMatchOnTheirTitle() {
        let found = candidates(actions: [.toggleCompactMode, .switchProfile(id: UUID(), name: "Work")])
        let results = CommandBarSearch.results(query: "compact", candidates: found)
        #expect(results.contains(.action(.toggleCompactMode)))
        #expect(CommandBarSearch.results(query: "switch to w", candidates: found).count == 2)
    }

    @Test func emptyQueryListsRecentTabs() {
        let found = candidates(tabs: ["One", "Two"], archived: ["Old"])
        let results = CommandBarSearch.results(query: "  ", candidates: found)
        #expect(tabTitles(results) == ["One", "Two"])
        #expect(results.count == 2)
    }

    @Test func limitIsRespected() {
        let found = candidates(tabs: (0..<30).map { "Page \($0)" })
        #expect(CommandBarSearch.results(query: "", candidates: found).count == 12)
        #expect(CommandBarSearch.results(query: "page", candidates: found).count == 12)
        #expect(CommandBarSearch.results(query: "page", candidates: found, limit: 5).count == 5)
    }

    // MARK: - Model

    @Test func modelClampsSelection() {
        let model = CommandBarModel(mode: .newTab, candidates: candidates(tabs: ["A1", "A2"]), currentURL: nil)
        #expect(model.results.count == 2 && model.selectedIndex == 0)
        model.moveSelection(by: 5)
        #expect(model.selectedIndex == 1)
        model.moveSelection(by: -9)
        #expect(model.selectedIndex == 0)
        model.moveSelection(by: 1)
        model.query = "a"
        #expect(model.selectedIndex == 0)
        #expect(model.selectedResult == .search(query: "a"))
        model.query = "zzz-nothing"
        model.moveSelection(by: 3)
        #expect(model.selectedIndex == 0)
    }

    @Test func currentTabModePrefills() {
        let found = candidates(tabs: ["A1"])
        let current = CommandBarModel(mode: .currentTab, candidates: found, currentURL: "https://example.com/now")
        #expect(current.query == "https://example.com/now")
        #expect(current.selectedResult == .open(url: "https://example.com/now"))
        #expect(CommandBarModel(mode: .newTab, candidates: found, currentURL: "https://example.com/now").query == "")
        #expect(CommandBarModel(mode: .currentTab, candidates: found, currentURL: nil).query == "")
    }

    @Test func prefillIsOnlyForWebAddresses() {
        for url in ["file:///etc/hosts", "about:blank", "javascript:alert(1)", "data:text/html,x", ""] {
            #expect(CommandBarModel(mode: .currentTab, candidates: candidates(), currentURL: url).query == "", "\(url)")
        }
        #expect(CommandBarModel(mode: .currentTab, candidates: candidates(), currentURL: "HTTPS://example.com/a").query == "HTTPS://example.com/a")
    }

    @Test func untitledArchivedTabDoesNotTitleMatchItsScheme() {
        let found = candidates(tabs: ["Zzz https"], archived: [""]) // archived url is https://example.org/y, host example.org
        let results = CommandBarSearch.results(query: "https", candidates: found)
        #expect(results.dropFirst().map { r -> String in
            if case .tab = r { "tab" } else if case .archived = r { "archived" } else { "other" }
        } == ["tab", "archived"])
    }

    @Test func candidatesAreMostRecentlyActiveFirst() throws {
        let world = try makeWorld()
        let a = try world.tab("a")
        let b = try world.tab("b")
        let c = try world.tab("c")
        #expect(try world.store.commandCandidates(profileID: world.profile.id).tabs.map(\.tab.id) == [c.id, b.id, a.id])
        world.clock.advance(by: 10)
        try world.store.markActive(tabID: a.id)
        #expect(try world.store.commandCandidates(profileID: world.profile.id).tabs.map(\.tab.id) == [a.id, c.id, b.id])
    }

    // MARK: - Perform

    @Test func performOpenNewTab() throws {
        let world = try makeWorld()
        let first = try world.tab("first")
        let model = try world.window(selected: first.id)
        #expect(model.perform(.open(url: "https://example.net/a"), mode: .newTab) == .done)
        #expect(model.selectedTab?.url == "https://example.net/a")
        #expect(model.selectedTabID != first.id)
        #expect(model.snapshot.regular.count == 2)
    }

    @Test func performOpenCurrentTab() throws {
        let world = try makeWorld()
        let first = try world.tab("first")
        let model = try world.window(selected: first.id)
        #expect(model.perform(.open(url: "https://example.net/a"), mode: .currentTab) == .done)
        #expect(model.selectedTabID == first.id)
        #expect(model.selectedTab?.url == "https://example.net/a")
        #expect(model.snapshot.regular.count == 1)
    }

    @Test func performOpenCurrentTabWithoutSelectionOpensANewTab() throws {
        let world = try makeWorld()
        let model = try world.window()
        #expect(model.perform(.open(url: "https://example.net/a"), mode: .currentTab) == .done)
        #expect(model.selectedTab?.url == "https://example.net/a")
        #expect(model.snapshot.regular.count == 1)
    }

    @Test func performSearchWithoutEngine() throws {
        let world = try makeWorld()
        let model = try world.window()
        #expect(model.perform(.search(query: "cats"), mode: .newTab) == .chooseSearchEngine)
        #expect(model.snapshot.regular.isEmpty)
        #expect(model.selectedTabID == nil)
    }

    @Test func performSearchWithEngine() throws {
        let world = try makeWorld()
        try world.store.setSetting(SettingKeys.searchEngine, .kagi)
        let model = try world.window()
        #expect(model.perform(.search(query: "cats & dogs"), mode: .newTab) == .done)
        #expect(model.selectedTab?.url == "https://kagi.com/search?q=cats%20%26%20dogs")
    }

    @Test func performTabInOtherWorkspace() throws {
        let world = try makeWorld()
        let work = try world.store.createWorkspace(profileID: world.profile.id, name: "Work", icon: "", colorHex: "#FFFFFF")
        let target = try world.tab("target", in: work)
        let model = try world.window()
        let candidate = try #require(try world.store.commandCandidates(profileID: world.profile.id).tabs.first { $0.tab.id == target.id })
        #expect(model.perform(.tab(candidate), mode: .newTab) == .done)
        #expect(model.snapshot.workspace.id == work.id)
        #expect(model.selectedTabID == target.id)
    }

    @Test func performEssentialTabStaysInWorkspace() throws {
        let world = try makeWorld()
        let essential = try world.tab("mail")
        try world.store.makeEssential(essential.id)
        let model = try world.window()
        let candidate = try #require(try world.store.commandCandidates(profileID: world.profile.id).tabs.first)
        #expect(model.perform(.tab(candidate), mode: .newTab) == .done)
        #expect(model.snapshot.workspace.id == world.home.id)
        #expect(model.selectedTabID == essential.id)
    }

    @Test func performArchived() throws {
        let world = try makeWorld()
        let gone = try world.tab("gone")
        _ = try world.store.closeTab(gone.id)
        let model = try world.window()
        let archived = try #require(model.archivedTabs().first)
        #expect(model.perform(.archived(archived), mode: .newTab) == .done)
        #expect(model.selectedTab?.url == gone.url)
        #expect(model.archivedTabs().isEmpty)
    }

    @Test func performWorkspaceSwitches() throws {
        let world = try makeWorld()
        let work = try world.store.createWorkspace(profileID: world.profile.id, name: "Work", icon: "", colorHex: "#FFFFFF")
        let model = try world.window()
        #expect(model.perform(.workspace(work), mode: .newTab) == .done)
        #expect(model.snapshot.workspace.id == work.id)
    }

    @Test func performToggleCompact() throws {
        let world = try makeWorld()
        let model = try world.window()
        #expect(model.perform(.action(.toggleCompactMode), mode: .newTab) == .done)
        #expect(try world.store.setting(SettingKeys.compactMode) == true)
        #expect(model.perform(.action(.toggleCompactMode), mode: .newTab) == .done)
        #expect(try world.store.setting(SettingKeys.compactMode) == false)
    }

    @Test func performActionsWithUI() throws {
        let world = try makeWorld()
        let first = try world.tab("first")
        let model = try world.window(selected: first.id)
        #expect(model.perform(.action(.newWorkspace), mode: .newTab) == .newWorkspace)
        #expect(model.perform(.action(.newProfile), mode: .newTab) == .newProfile)
        #expect(model.perform(.action(.newWindow), mode: .newTab) == .newWindow)
        #expect(model.perform(.action(.importFromArc), mode: .newTab) == .showArcImport)
        #expect(model.perform(.action(.showArchive), mode: .newTab) == .showArchive)
        #expect(model.perform(.action(.copyAddress), mode: .newTab) == .copy(first.url))
    }

    @Test func performTabActionsFollowTheSelection() throws {
        let world = try makeWorld()
        let first = try world.tab("first")
        let model = try world.window(selected: first.id)
        #expect(model.perform(.action(.pinTab), mode: .newTab) == .done)
        #expect(model.snapshot.pinned.count == 1)
        #expect(model.perform(.action(.unpinTab), mode: .newTab) == .done)
        #expect(model.snapshot.pinned.isEmpty)
        #expect(model.perform(.action(.closeTab), mode: .newTab) == .done)
        #expect(model.selectedTabID == nil)
        #expect(model.perform(.action(.closeTab), mode: .newTab) == .done) // nothing selected: nothing to do
    }

    @Test func performSwitchProfileAndContainerTab() throws {
        let world = try makeWorld()
        let other = try world.store.createProfile(name: "Other")
        let container = try world.store.createContainer(profileID: world.profile.id, name: "Shop", colorHex: "#34C759")
        let model = try world.window()
        #expect(model.perform(.action(.newTabInContainer(id: container.id, name: "Shop")), mode: .newTab) == .done)
        #expect(model.selectedTab?.containerID == container.id)
        #expect(model.selectedTab?.url == "")
        #expect(model.perform(.action(.switchProfile(id: other.id, name: "Other")), mode: .newTab) == .done)
        #expect(model.snapshot.profile.id == other.id)
    }

    // MARK: - Window actions

    @Test func actionsFollowSelection() throws {
        let world = try makeWorld()
        let regular = try world.tab("regular")
        let pinned = try world.tab("pinned")
        try world.store.pinTab(pinned.id, folderID: nil)
        try world.store.updateNavigation(tabID: pinned.id, url: "https://example.com/elsewhere", title: "", faviconURL: nil, interactionState: nil)

        let none = try world.window().commandCandidates().actions
        #expect(!none.contains(.closeTab) && !none.contains(.pinTab) && !none.contains(.copyAddress))
        #expect(none.contains(.newWorkspace) && none.contains(.toggleCompactMode) && none.contains(.showArchive))

        let onRegular = try world.window(selected: regular.id).commandCandidates().actions
        #expect(onRegular.contains(.pinTab) && onRegular.contains(.closeTab) && onRegular.contains(.copyAddress))
        #expect(!onRegular.contains(.unpinTab) && !onRegular.contains(.resetPinnedTab))

        let onDrifted = try world.window(selected: pinned.id).commandCandidates().actions
        #expect(onDrifted.contains(.resetPinnedTab) && onDrifted.contains(.unpinTab) && onDrifted.contains(.closeTab))
        #expect(!onDrifted.contains(.pinTab))
        #expect(CommandAction.resetPinnedTab.title == "Back to Pinned Page")
    }

    @Test func actionsOfferOtherProfilesAndContainers() throws {
        let world = try makeWorld()
        let other = try world.store.createProfile(name: "Other")
        let container = try world.store.createContainer(profileID: world.profile.id, name: "Shop", colorHex: "#34C759")
        let actions = try world.window().commandCandidates().actions
        #expect(actions.contains(.switchProfile(id: other.id, name: "Other")))
        #expect(!actions.contains(.switchProfile(id: world.profile.id, name: world.profile.name)))
        #expect(actions.contains(.newTabInContainer(id: container.id, name: "Shop")))
    }

    @Test func actionTitles() {
        #expect(CommandAction.switchProfile(id: UUID(), name: "Work").title == "Switch to Work")
        #expect(CommandAction.newTabInContainer(id: UUID(), name: "Shop").title == "New Tab in Shop")
        #expect(CommandAction.importFromArc.title == "Import from Arc…")
        #expect(CommandAction.toggleCompactMode.title == "Toggle Compact Mode")
    }
}
