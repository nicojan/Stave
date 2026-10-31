import Foundation
import Testing
@testable import StaveCore

@MainActor
struct CompactModeTests {
    @MainActor private struct World {
        let store: OrganizationStore
        let revision = StoreRevision()
        let profile: Profile
        let workspace: Workspace
        let livePages = LivePageRegistry()

        func window() throws -> BrowserWindowModel {
            let state = WindowState(profileID: profile.id, workspaceID: workspace.id, selectedTabID: nil, frame: "", sortIndex: 0)
            return try BrowserWindowModel(store: store, revision: revision, livePages: livePages, state: state)
        }
    }

    private func makeWorld() throws -> World {
        let (store, _, _) = try makeTempStore()
        let profile = try store.ensureDefaultProfile()
        let workspace = try #require(try store.workspaces(profileID: profile.id).first)
        return World(store: store, profile: profile, workspace: workspace)
    }

    @Test func windowStartsWithTheStoredValue() throws {
        let world = try makeWorld()
        #expect(try !world.window().isCompact)
        try world.store.setSetting(SettingKeys.compactMode, true)
        #expect(try world.window().isCompact)
    }

    @Test func toggleFromOneWindowReachesTheOtherAfterItsReload() throws {
        let world = try makeWorld()
        let first = try world.window()
        let second = try world.window()
        let before = world.revision.value
        first.toggleCompactMode()
        #expect(first.isCompact)
        #expect(world.revision.value == before + 1)
        second.reload() // what the window view does when the revision changes
        #expect(second.isCompact)
        first.toggleCompactMode()
        second.reload()
        #expect(!first.isCompact && !second.isCompact)
    }

    @Test func commandBarActionUpdatesTheWindow() throws {
        let world = try makeWorld()
        let model = try world.window()
        #expect(model.perform(.action(.toggleCompactMode), mode: .newTab) == .done)
        #expect(model.isCompact)
    }

    @Test func settingWritesAndBumpsTheRevision() throws {
        let world = try makeWorld()
        let setting = CompactModeSetting(store: world.store, revision: world.revision)
        #expect(!setting.isEnabled)
        let before = world.revision.value
        setting.set(true)
        #expect(setting.isEnabled)
        #expect(try world.store.setting(SettingKeys.compactMode))
        #expect(world.revision.value == before + 1)
        setting.set(true) // no change, no write
        #expect(world.revision.value == before + 1)
    }

    @Test func settingFollowsAWriteFromAnotherPath() throws {
        let world = try makeWorld()
        let setting = CompactModeSetting(store: world.store, revision: world.revision)
        let model = try world.window()
        model.toggleCompactMode()
        #expect(setting.isEnabled)
    }

    @Test func settingToggleFlips() throws {
        let world = try makeWorld()
        let setting = CompactModeSetting(store: world.store, revision: world.revision)
        setting.toggle()
        #expect(setting.isEnabled)
        setting.toggle()
        #expect(!setting.isEnabled)
    }
}
