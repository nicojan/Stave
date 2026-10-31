import Foundation
import Testing
@testable import StaveCore

@MainActor
struct BrowserWindowModelTests {
    @MainActor private struct World {
        let store: OrganizationStore
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
        let (store, _, _) = try makeTempStore(now: clock.now)
        let profile = try store.ensureDefaultProfile()
        let home = try #require(try store.workspaces(profileID: profile.id).first)
        return World(store: store, clock: clock, profile: profile, home: home)
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

    @Test func navigateSelectedDrifts() throws {
        let world = try makeWorld()
        let tab = try world.tab("a")
        let model = try world.window()
        model.pin(tab.id, folderID: nil)
        model.select(tab.id)
        model.navigateSelected(to: "https://example.org/elsewhere")
        let stored = try #require(model.selectedTab)
        #expect(stored.url == "https://example.org/elsewhere")
        #expect(stored.title == "")
        #expect(model.rows.first?.kind == .pinnedTab(drifted: true))
        model.resetPinned(tab.id)
        #expect(model.rows.first?.kind == .pinnedTab(drifted: false))
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
        guard case .folder(let first) = try #require(model.rows.first).id else { return }
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
        one.reload()
        #expect(one.placement == .elsewhere(windowID: two.windowID))
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
