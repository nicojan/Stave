import Foundation
import GRDB
import Testing
@testable import StaveCore

@MainActor
struct BrowserWindowModelTests {
    @MainActor private struct World {
        let store: OrganizationStore
        let database: StaveDatabase
        let revision = StoreRevision()
        let livePages = LivePageRegistry()
        let clock: TestClock
        let profile: Profile
        let home: Workspace

        func state(workspace: Workspace? = nil, selected: UUID? = nil, frame: String = "") -> WindowState {
            WindowState(profileID: profile.id, workspaceID: (workspace ?? home).id, selectedTabID: selected, frame: frame, sortIndex: 0)
        }

        func window(workspace: Workspace? = nil, selected: UUID? = nil) throws -> BrowserWindowModel {
            try BrowserWindowModel(store: store, revision: revision, livePages: livePages, state: state(workspace: workspace, selected: selected))
        }

        func tab(_ name: String, in workspace: Workspace? = nil) throws -> Tab {
            try store.openTab(
                url: "https://example.com/\(name)", title: name, workspaceID: (workspace ?? home).id,
                origin: .commandBar, containerID: nil, edge: .bottom
            )
        }
    }

    private func makeWorld() throws -> World {
        let clock = TestClock()
        let (store, database, _) = try makeTempStore(now: clock.now)
        let profile = try store.ensureDefaultProfile()
        let home = try #require(try store.workspaces(profileID: profile.id).first)
        return World(store: store, database: database, clock: clock, profile: profile, home: home)
    }

    // MARK: - Start and state

    @Test func startsOnSavedWorkspace() throws {
        let world = try makeWorld()
        let second = try world.store.createWorkspace(profileID: world.profile.id, name: "Two", icon: "", colorHex: "#FFFFFF")
        let model = try world.window(workspace: second)
        #expect(model.snapshot.workspace.id == second.id)
        #expect(model.windowID == model.windowState.id)
        #expect(model.selectedTabID == nil)
    }

    @Test func windowStateFollowsChanges() throws {
        let world = try makeWorld()
        let other = try world.store.createWorkspace(profileID: world.profile.id, name: "Two", icon: "", colorHex: "#FFFFFF")
        let tab = try world.tab("a")
        let model = try world.window()
        model.select(tab.id)
        model.frame = "10 20 300 400"
        #expect(model.windowState.selectedTabID == tab.id)
        #expect(model.windowState.frame == "10 20 300 400")
        #expect(model.windowState.workspaceID == world.home.id)
        model.switchWorkspace(to: other.id)
        #expect(model.windowState.workspaceID == other.id)
        #expect(model.windowState.selectedTabID == nil)
        model.createProfile(name: "Work")
        #expect(model.windowState.profileID == model.snapshot.profile.id)
        #expect(model.windowState.profileID != world.profile.id)
    }

    @Test func selectMarksActive() throws {
        let world = try makeWorld()
        let tab = try world.tab("a")
        let model = try world.window()
        world.clock.advance(by: 60)
        model.select(tab.id)
        let stamped = try #require(model.selectedTab)
        #expect(stamped.lastActiveAt > tab.lastActiveAt)
        #expect(model.placement == .here)
    }

    @Test func selectNilReleasesTheClaim() throws {
        let world = try makeWorld()
        let tab = try world.tab("a")
        let one = try world.window(), two = try world.window()
        one.select(tab.id)
        two.select(tab.id)
        #expect(two.placement == .elsewhere(windowID: one.windowID))
        one.select(nil)
        #expect(one.selectedTabID == nil && one.placement == nil)
        #expect(world.livePages.show(tab.id, in: two.windowID) == .here)
    }

    // MARK: - Switching

    @Test func switchByNumberAndOffset() throws {
        let world = try makeWorld()
        let second = try world.store.createWorkspace(profileID: world.profile.id, name: "Two", icon: "", colorHex: "#FFFFFF")
        let third = try world.store.createWorkspace(profileID: world.profile.id, name: "Three", icon: "", colorHex: "#FFFFFF")
        let model = try world.window()
        model.switchWorkspace(number: 2)
        #expect(model.snapshot.workspace.id == second.id)
        #expect(model.lastSwitchDirection == 1)
        model.switchWorkspace(number: 9)
        #expect(model.snapshot.workspace.id == second.id)
        model.switchWorkspace(offset: 1)
        #expect(model.snapshot.workspace.id == third.id)
        model.switchWorkspace(offset: 1)
        #expect(model.snapshot.workspace.id == third.id)
        model.switchWorkspace(offset: -2)
        #expect(model.snapshot.workspace.id == world.home.id)
        #expect(model.lastSwitchDirection == -1)
    }

    @Test func switchByNumberZeroOrNegativeDoesNothing() throws {
        let world = try makeWorld()
        _ = try world.store.createWorkspace(profileID: world.profile.id, name: "Two", icon: "", colorHex: "#FFFFFF")
        let tab = try world.tab("a")
        let model = try world.window()
        model.select(tab.id)
        model.switchWorkspace(number: 2)
        model.switchWorkspace(number: 1)
        model.select(tab.id) // leaving a workspace dropped the selection
        let direction = model.lastSwitchDirection
        let revision = world.revision.value
        for number in [0, -1, -5] {
            model.switchWorkspace(number: number)
            #expect(model.snapshot.workspace.id == world.home.id)
            #expect(model.selectedTabID == tab.id)
            #expect(model.lastSwitchDirection == direction)
            #expect(model.lastError == nil)
        }
        #expect(world.revision.value == revision)
    }

    @Test func switchByNumberAtIntMin() throws {
        let world = try makeWorld()
        _ = try world.store.createWorkspace(profileID: world.profile.id, name: "Two", icon: "", colorHex: "#FFFFFF")
        let model = try world.window()
        let revision = world.revision.value
        for number in [Int.min, Int.max] {
            model.switchWorkspace(number: number)
            #expect(model.snapshot.workspace.id == world.home.id)
            #expect(model.lastError == nil)
        }
        #expect(world.revision.value == revision)
    }

    @Test func switchProfileGoesToFirstWorkspace() throws {
        let world = try makeWorld()
        let work = try world.store.createProfile(name: "Work")
        let workFirst = try #require(try world.store.workspaces(profileID: work.id).first)
        let tab = try world.tab("a")
        let model = try world.window(selected: tab.id)
        model.switchProfile(to: work.id)
        #expect(model.snapshot.profile.id == work.id)
        #expect(model.snapshot.workspace.id == workFirst.id)
        #expect(model.selectedTabID == nil)
        #expect(model.lastSwitchDirection == 0)
    }

    @Test func essentialStaysSelectedAcrossWorkspaceSwitch() throws {
        let world = try makeWorld()
        let other = try world.store.createWorkspace(profileID: world.profile.id, name: "Two", icon: "", colorHex: "#FFFFFF")
        let tab = try world.tab("a")
        let model = try world.window()
        model.makeEssential(tab.id)
        model.select(tab.id)
        model.switchWorkspace(to: other.id)
        #expect(model.selectedTabID == tab.id)
    }

    @Test func createWorkspaceSwitchesToIt() throws {
        let world = try makeWorld()
        let model = try world.window()
        model.createWorkspace(name: "New", icon: "star", colorHex: "#FF0000")
        #expect(model.snapshot.workspace.name == "New")
        #expect(model.lastSwitchDirection == 1)
    }

    @Test func deletingTheCurrentWorkspaceMovesToItsNeighbour() throws {
        let world = try makeWorld()
        let second = try world.store.createWorkspace(profileID: world.profile.id, name: "Two", icon: "", colorHex: "#FFFFFF")
        let model = try world.window(workspace: second)
        model.deleteWorkspace(second.id)
        #expect(model.snapshot.workspace.id == world.home.id)
        #expect(model.workspaces.count == 1)
        model.deleteWorkspace(world.home.id)
        #expect(model.lastError == "A profile needs at least one workspace.")
    }

    // MARK: - Tabs

    /// A delete the store refuses leaves the window where it was, with its selection, and says why.
    @Test func failedDeleteKeepsTheWorkspace() throws {
        let world = try makeWorld()
        let second = try world.store.createWorkspace(profileID: world.profile.id, name: "Two", icon: "", colorHex: "#FFFFFF")
        let tab = try world.tab("a", in: second)
        let model = try world.window(workspace: second, selected: tab.id)
        try world.database.writer.write { db in
            try db.execute(sql: "CREATE TRIGGER refuseWorkspaceDelete BEFORE DELETE ON workspace BEGIN SELECT RAISE(ABORT, 'refused by the test'); END")
        }
        model.deleteWorkspace(second.id)
        #expect(model.snapshot.workspace.id == second.id)
        #expect(model.selectedTabID == tab.id)
        #expect(model.lastError == StoreErrorText.fallback)
        #expect(model.workspaces.map(\.id) == [world.home.id, second.id])
    }

    /// Decision 30: the selected tab sent to another workspace (dropped on its icon, or Move to Workspace) takes the window with it, keeps its
    /// selection and its page; a non-selected tab sent away leaves the window where it is.
    @Test func selectedTabMovedToWorkspaceIsFollowed() throws {
        let world = try makeWorld()
        let work = try world.store.createWorkspace(profileID: world.profile.id, name: "Work", icon: "briefcase", colorHex: "#FFFFFF")
        let moving = try world.tab("moving")
        let staying = try world.tab("staying")
        let model = try world.window(selected: moving.id)
        let pages = SpyPages()
        model.pages = pages

        #expect(model.drop(.tab(moving.id), onto: .workspace(work.id)))
        #expect(model.snapshot.workspace.id == work.id)
        #expect(model.selectedTabID == moving.id)
        #expect(model.lastSwitchDirection == 1)
        #expect(world.livePages.owner(of: moving.id) == model.windowID)
        #expect(pages.calls.isEmpty)

        let target = try #require(SidebarMenus.moveTargets(
            for: .tab(moving.id), currentWorkspaceID: model.snapshot.workspace.id, workspaces: model.workspaces
        ).first)
        #expect(target.workspaceID == world.home.id)
        #expect(model.run(target, on: .tab(moving.id)))
        #expect(model.snapshot.workspace.id == world.home.id)
        #expect(model.selectedTabID == moving.id)
        #expect(world.livePages.owner(of: moving.id) == model.windowID)
        #expect(pages.calls.isEmpty)

        // Control: a tab that is not selected goes alone.
        #expect(model.drop(.tab(staying.id), onto: .workspace(work.id)))
        #expect(model.snapshot.workspace.id == world.home.id)
        #expect(model.selectedTabID == moving.id)
        #expect(try world.store.sidebarSnapshot(workspaceID: work.id).regular.map(\.id) == [staying.id])
        #expect(pages.calls.isEmpty)
    }

    @Test func openTabHonoursEdgeSetting() throws {
        let world = try makeWorld()
        _ = try world.tab("a")
        _ = try world.tab("b")
        try world.store.setSetting(SettingKeys.newTabEdge, .bottom)
        let model = try world.window()
        model.openTab(url: "https://example.com/new")
        #expect(model.snapshot.regular.last?.url == "https://example.com/new")
        #expect(model.selectedTabID == model.snapshot.regular.last?.id)
        try world.store.setSetting(SettingKeys.newTabEdge, .top)
        model.openTab(url: "https://example.com/top")
        #expect(model.snapshot.regular.first?.url == "https://example.com/top")
    }

    @Test func closeSelectsNeighbour() throws {
        let world = try makeWorld()
        let a = try world.tab("a"), b = try world.tab("b"), c = try world.tab("c")
        let model = try world.window()
        model.select(b.id)
        model.close(b.id)
        #expect(model.selectedTabID == c.id)
        model.close(c.id)
        #expect(model.selectedTabID == a.id)
        model.close(a.id)
        #expect(model.selectedTabID == nil)
        #expect(model.placement == nil)
        #expect(model.archivedTabs().count == 3)
    }

    @Test func closingAnotherTabKeepsTheSelection() throws {
        let world = try makeWorld()
        let a = try world.tab("a"), b = try world.tab("b")
        let model = try world.window()
        model.select(a.id)
        model.close(b.id)
        #expect(model.selectedTabID == a.id)
    }

    @Test func removePinnedArchivesAndMovesTheSelectionOn() throws {
        let world = try makeWorld()
        let pinned = try world.tab("a"), regular = try world.tab("b")
        let model = try world.window()
        model.pin(pinned.id, folderID: nil)
        model.select(pinned.id)
        #expect(model.run(.removeFromPinned, on: .tab(pinned.id))) // the menu path applies the selection rule
        #expect(model.lastError == nil)
        #expect(!model.rows.contains { $0.id == .tab(pinned.id) })
        #expect(model.selectedTabID == regular.id)
        #expect(model.archivedTabs().map(\.url) == ["https://example.com/a"])
    }

    @Test func removePinnedDirectlyArchivesAndClearsAVanishedSelection() throws {
        let world = try makeWorld()
        let pinned = try world.tab("a")
        let model = try world.window()
        model.pin(pinned.id, folderID: nil)
        model.select(pinned.id)
        model.removePinned(pinned.id)
        #expect(model.lastError == nil)
        #expect(model.rows.isEmpty)
        #expect(model.selectedTabID == nil)
        #expect(model.archivedTabs().map(\.url) == ["https://example.com/a"])
    }

    @Test func pinnedOnlyActionsOnARegularTabShowAMessageAndChangeNothing() throws {
        let world = try makeWorld()
        let tab = try world.tab("a")
        let model = try world.window()
        let message = "Only pinned tabs and Essentials have a pinned page."
        for act in [{ model.unpin(tab.id) }, { model.removePinned(tab.id) }, { model.removeEssential(tab.id) }] {
            act()
            #expect(model.lastError == message)
            #expect(model.rows.first?.isRegular == true)
            #expect(model.archivedTabs().isEmpty)
        }
    }

    @Test func removeEssentialArchivesIt() throws {
        let world = try makeWorld()
        let tab = try world.tab("a")
        let model = try world.window()
        model.makeEssential(tab.id)
        model.select(tab.id)
        model.removeEssential(tab.id)
        #expect(model.snapshot.essentials.isEmpty)
        #expect(model.selectedTabID == nil)
        #expect(model.archivedTabs().map(\.url) == ["https://example.com/a"])
    }

    @Test func restoreArchivedSelectsIt() throws {
        let world = try makeWorld()
        let tab = try world.tab("a")
        let model = try world.window()
        model.close(tab.id)
        let archived = try #require(model.archivedTabs().first)
        model.restoreArchived(archived.id)
        #expect(model.selectedTab?.url == "https://example.com/a")
        #expect(model.archivedTabs().isEmpty)
    }

    // MARK: - Folders

    @Test func folderCalls() throws {
        let world = try makeWorld()
        let model = try world.window()
        model.createFolder(title: "F", parentID: nil)
        let folder = try #require(model.rows.first)
        guard case .folder(let id) = folder.id else { Issue.record("not a folder"); return }
        model.renameFolder(id, to: "G")
        #expect(model.rows.first?.title == "G")
        model.setFolderOpen(id, false)
        #expect(model.rows.first?.kind == .folder(isOpen: false, childCount: 0))
        model.deleteFolder(id)
        #expect(model.rows.isEmpty)
    }

    @Test func errorsBecomeMessages() throws {
        let world = try makeWorld()
        let model = try world.window()
        model.createFolder(title: "1", parentID: nil)
        let firstRow = try #require(model.rows.first)
        guard case .folder(let first) = firstRow.id else { Issue.record("not a folder"); return }
        model.createFolder(title: "2", parentID: first)
        let second = try #require(model.rows.first { $0.depth == 1 })
        guard case .folder(let secondID) = second.id else { Issue.record("not a folder"); return }
        model.createFolder(title: "3", parentID: secondID)
        #expect(model.lastError == "Folders go only one level deep.")
        model.createFolder(title: "ok", parentID: nil)
        #expect(model.lastError == nil)
    }

    @Test func writesBumpRevision() throws {
        let world = try makeWorld()
        let model = try world.window()
        let before = world.revision.value
        model.createFolder(title: "F", parentID: nil)
        #expect(world.revision.value == before + 1)
        model.createFolder(title: "G", parentID: UUID())
        #expect(world.revision.value == before + 1)
    }

    // MARK: - Two windows

    @Test func workspaceDeletedElsewhereFallsBack() throws {
        let world = try makeWorld()
        let second = try world.store.createWorkspace(profileID: world.profile.id, name: "Two", icon: "", colorHex: "#FFFFFF")
        let tab = try world.tab("a", in: second)
        let one = try world.window(workspace: second, selected: tab.id)
        let two = try world.window(workspace: second)
        #expect(one.selectedTabID == tab.id)
        two.deleteWorkspace(second.id)
        one.reload()
        #expect(one.snapshot.workspace.id == world.home.id)
        #expect(one.selectedTabID == nil)
    }

    @Test func selectedTabClosedElsewhereClearsSelection() throws {
        let world = try makeWorld()
        let tab = try world.tab("a")
        let one = try world.window(), two = try world.window()
        one.select(tab.id)
        two.close(tab.id)
        one.reload()
        #expect(one.selectedTabID == nil)
        #expect(world.livePages.placement(of: tab.id, in: two.windowID) == .here)
    }

    @Test func reloadReleasesTheClaimOfAVanishedTab() throws {
        let world = try makeWorld()
        let tab = try world.tab("a")
        let one = try world.window(), two = try world.window()
        one.select(tab.id)
        _ = try world.store.closeTab(tab.id) // behind the registry's back
        #expect(world.livePages.placement(of: tab.id, in: two.windowID) == .elsewhere(windowID: one.windowID))
        one.reload()
        #expect(one.selectedTabID == nil)
        #expect(world.livePages.placement(of: tab.id, in: two.windowID) == .here)
    }

    @Test func bringHereSwapsPlacement() throws {
        let world = try makeWorld()
        let tab = try world.tab("a")
        let one = try world.window(), two = try world.window()
        one.select(tab.id)
        two.select(tab.id)
        #expect(two.placement == .elsewhere(windowID: one.windowID))
        two.bringSelectedHere()
        #expect(two.placement == .here)
        #expect(one.placement == .elsewhere(windowID: two.windowID)) // no reload: the registry answers
    }

    @Test func ownerSwitchingWorkspaceHandsThePageToTheWaiter() throws {
        let world = try makeWorld()
        let other = try world.store.createWorkspace(profileID: world.profile.id, name: "Two", icon: "", colorHex: "#FFFFFF")
        let tab = try world.tab("a")
        let one = try world.window(), two = try world.window()
        one.select(tab.id)
        two.select(tab.id)
        #expect(two.placement == .elsewhere(windowID: one.windowID))
        one.switchWorkspace(to: other.id)
        #expect(two.placement == .here)
    }

    @Test func closingTheOwnerWindowHandsThePageToTheWaiter() throws {
        let world = try makeWorld()
        let tab = try world.tab("a")
        let one = try world.window(), two = try world.window()
        one.select(tab.id)
        two.select(tab.id)
        one.windowWillClose()
        #expect(two.placement == .here)
    }

    @Test func closingASelectedEssentialSelectsTheNextEssential() throws {
        let world = try makeWorld()
        let a = try world.tab("a"), b = try world.tab("b"), c = try world.tab("c")
        let model = try world.window()
        for tab in [a, b, c] { model.makeEssential(tab.id) }
        model.select(b.id)
        model.close(b.id)
        #expect(model.selectedTabID == c.id)
        model.close(c.id) // last in the grid: the previous Essential (closing only unloads, so all three remain)
        #expect(model.selectedTabID == b.id)
        #expect(model.snapshot.essentials.count == 3)
    }

    @Test func closingTheOnlyEssentialSelectsNothing() throws {
        let world = try makeWorld()
        let tab = try world.tab("a")
        let model = try world.window()
        model.makeEssential(tab.id)
        model.select(tab.id)
        model.close(tab.id)
        #expect(model.selectedTabID == nil)
    }

    @Test func switchingToTheCurrentWorkspaceOrProfileKeepsTheSelection() throws {
        let world = try makeWorld()
        _ = try world.store.createWorkspace(profileID: world.profile.id, name: "Two", icon: "", colorHex: "#FFFFFF")
        let tab = try world.tab("a")
        let model = try world.window()
        model.select(tab.id)
        model.switchWorkspace(number: 1)
        model.switchWorkspace(to: world.home.id)
        model.switchProfile(to: world.profile.id)
        #expect(model.selectedTabID == tab.id)
        #expect(model.lastSwitchDirection == 0)
    }

    @Test func windowWillCloseReleasesItsPage() throws {
        let world = try makeWorld()
        let tab = try world.tab("a")
        let one = try world.window(), two = try world.window()
        one.select(tab.id)
        one.windowWillClose()
        two.select(tab.id)
        #expect(two.placement == .here)
    }

    // MARK: - Moves

    @Test func applyMovesAndBumps() throws {
        let world = try makeWorld()
        let a = try world.tab("a"), b = try world.tab("b"), c = try world.tab("c")
        let model = try world.window()
        let before = world.revision.value
        model.apply(.tab(c.id, workspaceID: world.home.id, section: .regular, folderID: nil, after: nil))
        #expect(world.revision.value == before + 1)
        #expect(model.snapshot.regular.map(\.id) == [c.id, a.id, b.id])
        model.apply(.tab(a.id, workspaceID: world.home.id, section: .pinned, folderID: nil, after: nil))
        #expect(model.snapshot.regular.map(\.id) == [c.id, b.id])
        #expect(model.rows.map(\.id) == [.tab(a.id), .tab(c.id), .tab(b.id)])
        let folder = try world.store.createFolder(workspaceID: world.home.id, parentFolderID: nil, title: "F")
        model.reload()
        model.apply(.folder(folder.id, parentID: nil, after: nil))
        #expect(model.rows.first?.id == .folder(folder.id))
        #expect(model.lastError == nil)
    }

    @Test func aRefusedMoveShowsAMessageAndWritesNothing() throws {
        let world = try makeWorld()
        let a = try world.tab("a")
        let model = try world.window()
        model.apply(.tab(a.id, workspaceID: world.home.id, section: .regular, folderID: nil, after: .tab(UUID())))
        #expect(model.lastError == StoreErrorText.message(for: StoreError.notFound))
        #expect(model.snapshot.regular.map(\.id) == [a.id])
    }

    @Test func dropMovesATabToAnotherWorkspaceAndRefusesWhatThePlannerRefuses() throws {
        let world = try makeWorld()
        let work = try world.store.createWorkspace(profileID: world.profile.id, name: "Work", icon: "", colorHex: "#FFFFFF")
        let pinnedAlready = try world.tab("p")
        try world.store.pinTab(pinnedAlready.id, folderID: nil)
        let tail = try world.tab("t", in: work)
        try world.store.pinTab(tail.id, folderID: nil)
        let regular = try world.tab("r")
        let model = try world.window()
        #expect(model.drop(.tab(pinnedAlready.id), onto: .workspace(work.id)))
        #expect(model.snapshot.pinned.isEmpty)
        let inWork = try world.store.sidebarSnapshot(workspaceID: work.id)
        let pinnedIDs = inWork.pinned.compactMap { item -> UUID? in
            if case .tab(let t) = item { t.id } else { nil }
        }
        #expect(pinnedIDs == [tail.id, pinnedAlready.id])
        let revision = world.revision.value
        #expect(!model.drop(.tab(regular.id), onto: .row(.tab(regular.id), .before)))
        #expect(world.revision.value == revision)
    }

    @Test func moveHighlightedActsOnTheHighlightOnly() throws {
        let world = try makeWorld()
        let a = try world.tab("a"), b = try world.tab("b"), c = try world.tab("c")
        let model = try world.window(selected: c.id)
        model.moveHighlighted(by: -1) // nothing highlighted: the selection is not a fallback
        #expect(model.snapshot.regular.map(\.id) == [a.id, b.id, c.id])
        model.sidebarHighlight = .tab(c.id)
        model.moveHighlighted(by: -1)
        model.moveHighlighted(by: -1)
        #expect(model.snapshot.regular.map(\.id) == [c.id, a.id, b.id])
        let revision = world.revision.value
        model.moveHighlighted(by: -1) // at the top: nothing
        #expect(world.revision.value == revision)
        model.run(.moveDown, on: .tab(c.id))
        #expect(model.snapshot.regular.map(\.id) == [a.id, c.id, b.id])
        #expect(model.selectedTabID == c.id)
    }

    @Test func updateWorkspaceChangesItsAppearanceOrShowsAMessage() throws {
        let world = try makeWorld()
        let two = try world.store.createWorkspace(profileID: world.profile.id, name: "Two", icon: "", colorHex: "#FFFFFF")
        let model = try world.window()
        let before = world.revision.value
        model.updateWorkspace(two.id, name: "Deux", icon: "🎨", colorHex: "#123456")
        let updated = try #require(model.workspaces.first { $0.id == two.id })
        #expect(updated.name == "Deux" && updated.icon == "🎨" && updated.colorHex == "#123456")
        #expect(model.lastError == nil)
        #expect(world.revision.value == before + 1)
        model.updateWorkspace(UUID(), name: "x", icon: "y", colorHex: "#000000")
        #expect(model.lastError == "That item no longer exists.")
        #expect(world.revision.value == before + 1)
        #expect(model.workspaces.map(\.name) == ["Home", "Deux"])
    }

    @Test func moveWorkspaceReordersOrShowsAMessage() throws {
        let world = try makeWorld()
        let two = try world.store.createWorkspace(profileID: world.profile.id, name: "Two", icon: "", colorHex: "#FFFFFF")
        let three = try world.store.createWorkspace(profileID: world.profile.id, name: "Three", icon: "", colorHex: "#FFFFFF")
        let model = try world.window()
        model.moveWorkspace(three.id, after: nil)
        #expect(model.workspaces.map(\.id) == [three.id, world.home.id, two.id])
        model.moveWorkspace(three.id, after: two.id)
        #expect(model.workspaces.map(\.id) == [world.home.id, two.id, three.id])
        #expect(model.lastError == nil)
        let other = try world.store.createProfile(name: "Other")
        let foreign = try #require(try world.store.workspaces(profileID: other.id).first)
        let revision = world.revision.value
        model.moveWorkspace(two.id, after: foreign.id)
        #expect(model.lastError == "That belongs to another profile. Move it by opening it there.")
        #expect(model.workspaces.map(\.id) == [world.home.id, two.id, three.id])
        #expect(world.revision.value == revision)
        #expect(model.snapshot.workspace.id == world.home.id)
    }

    @Test func dropWorkspaceReordersAndKeepsTheOrder() throws {
        let world = try makeWorld()
        let two = try world.store.createWorkspace(profileID: world.profile.id, name: "Two", icon: "", colorHex: "#FFFFFF")
        let three = try world.store.createWorkspace(profileID: world.profile.id, name: "Three", icon: "", colorHex: "#FFFFFF")
        let model = try world.window()
        #expect(model.dropWorkspace(three.id, onto: world.home.id, side: .before))
        #expect(model.workspaces.map(\.id) == [three.id, world.home.id, two.id])
        #expect(try world.store.workspaces(profileID: world.profile.id).map(\.id) == [three.id, world.home.id, two.id])
        #expect(!model.dropWorkspace(three.id, onto: three.id, side: .after))
        #expect(!model.dropWorkspace(three.id, onto: world.home.id, side: .before))
    }

    // MARK: - Support types

    @Test func errorTextCoversEveryCase() {
        #expect(StoreErrorText.message(for: StoreError.lastWorkspace) == "A profile needs at least one workspace.")
        #expect(StoreErrorText.message(for: StoreError.folderTooDeep) == "Folders go only one level deep.")
        #expect(StoreErrorText.message(for: StoreError.crossProfileMove) == "That belongs to another profile. Move it by opening it there.")
        #expect(StoreErrorText.message(for: StoreError.notFound) == "That item no longer exists.")
        #expect(StoreErrorText.message(for: StoreError.notPinned) == "Only pinned tabs and Essentials have a pinned page.")
        #expect(StoreErrorText.message(for: StoreError.containerInUse) == "Something went wrong saving that change.")
        #expect(StoreErrorText.message(for: CocoaError(.fileNoSuchFile)) == "Something went wrong saving that change.")
    }
}

/// Records every page-lifecycle call, so a test can show a moved tab's page was never deselected, unloaded, reloaded or closed.
@MainActor
private final class SpyPages: PageLifecycle {
    private(set) var calls: [String] = []
    func tabClosed(_ id: UUID) { calls = calls + ["closed \(id)"] }
    func tabUnloaded(_ id: UUID) { calls = calls + ["unloaded \(id)"] }
    func tabDeselected(_ id: UUID) { calls = calls + ["deselected \(id)"] }
    func tabNavigated(_ id: UUID) { calls = calls + ["navigated \(id)"] }
}
