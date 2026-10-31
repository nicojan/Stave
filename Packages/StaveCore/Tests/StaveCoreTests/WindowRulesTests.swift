import CoreGraphics
import Foundation
import Testing
@testable import StaveCore

struct WindowFrameRestoreTests {
    private let screen = CGRect(x: 0, y: 0, width: 1440, height: 900)

    @Test(arguments: ["", "garbage", "{{0, 0}, {0, 0}}", "{{10, 10}, {0, 500}}", "{{nan, 0}, {800, 600}}", "{{0, 0}, {inf, 600}}", "{{0, 0}, {800, -5}}"])
    func unusableStringsFallBack(_ saved: String) {
        #expect(WindowFrameRestore.restore(saved, visibleFrames: [screen]) == nil)
    }

    @Test func goodFrameIsKept() {
        #expect(WindowFrameRestore.restore(NSStringFromRect(CGRect(x: 100, y: 100, width: 900, height: 600)), visibleFrames: [screen])
            == CGRect(x: 100, y: 100, width: 900, height: 600))
    }

    @Test func smallFrameGrowsToMinimum() {
        let result = WindowFrameRestore.restore("{{100, 100}, {300, 200}}", visibleFrames: [screen])
        #expect(result == CGRect(x: 100, y: 100, width: 800, height: 500))
    }

    @Test func frameOffScreenIsPulledOn() {
        let result = WindowFrameRestore.restore("{{5000, 100}, {900, 600}}", visibleFrames: [screen])
        #expect(result == CGRect(x: 270, y: 150, width: 900, height: 600))
    }

    @Test func growthIsClampedToTheScreen() {
        let small = CGRect(x: 0, y: 0, width: 700, height: 450)
        #expect(WindowFrameRestore.restore("{{0, 0}, {300, 200}}", visibleFrames: [small]) == small)
    }
}

@MainActor
struct SidebarWidthTests {
    @Test func clampKeepsTheRange() {
        #expect(SidebarWidthModel.clamp(100) == 200)
        #expect(SidebarWidthModel.clamp(260) == 260)
        #expect(SidebarWidthModel.clamp(900) == 400)
        #expect(SidebarWidthModel.clamp(.nan) == 260)
        #expect(SidebarWidthModel.clamp(.infinity) == 260)
    }

    @Test func startsFromTheStoredSettingClamped() throws {
        let store = try makeTempStore(now: TestClock().now).0
        try store.setSetting(SettingKeys.sidebarWidth, 999)
        #expect(SidebarWidthModel(store: store).width == 400)
    }

    @Test func oneModelIsOneWidthAndSavesOnceAfterTheLastChange() async throws {
        let store = try makeTempStore(now: TestClock().now).0
        let model = SidebarWidthModel(store: store, saveDelay: .milliseconds(80))
        model.set(300)
        model.set(320)
        model.nudge(by: 10)
        #expect(model.width == 330)
        #expect(try store.setting(SettingKeys.sidebarWidth) == 260)
        await model.saveTask?.value
        #expect(try store.setting(SettingKeys.sidebarWidth) == 330)
        #expect(model.writeCount == 1)
    }

    @Test func settingBackToTheStoredWidthCancelsThePendingSave() async throws {
        let store = try makeTempStore(now: TestClock().now).0
        let model = SidebarWidthModel(store: store, saveDelay: .milliseconds(80))
        model.set(300)
        let first = model.saveTask
        model.set(260) // same as stored: the earlier save is cancelled, nothing is written
        await first?.value
        await model.saveTask?.value
        #expect(try store.setting(SettingKeys.sidebarWidth) == 260)
        #expect(model.width == 260)
        #expect(model.writeCount == 0)
    }

    @Test func aSecondModelOnTheSameStoreReadsTheSavedWidth() throws {
        let store = try makeTempStore(now: TestClock().now).0
        let first = SidebarWidthModel(store: store)
        first.set(350)
        first.saveIfChanged()
        #expect(SidebarWidthModel(store: store).width == 350)
    }
}

struct WindowTitleTests {
    @Test func selectedTabTitleThenHostThenWorkspaceName() {
        let tab = Tab(slotID: UUID(), url: "https://example.com/a", title: "Recipes")
        #expect(WindowTitle.title(selectedTab: tab, workspaceName: "Home") == "Recipes")
        #expect(WindowTitle.title(selectedTab: Tab(slotID: UUID(), url: "https://www.example.org/x", title: ""), workspaceName: "Home") == "www.example.org")
        #expect(WindowTitle.title(selectedTab: nil, workspaceName: "Home") == "Home")
    }
}

struct LaunchArgumentsTests {
    @Test func absentFlagsAreNil() throws {
        #expect(try LaunchArguments.parse(["Stave"]) == .none)
    }

    @Test func usableFlagsParse() throws {
        let parsed = try LaunchArguments.parse(["Stave", "-StaveDataDirectory", "/tmp/a", "-StaveArcHome", "/tmp/b", "-StaveSeedSample"])
        #expect(parsed == LaunchArguments(dataDirectory: "/tmp/a", arcHome: "/tmp/b", seedSample: true))
    }

    @Test(arguments: [
        (["-StaveDataDirectory"], "-StaveDataDirectory"),
        (["-StaveDataDirectory", "-StaveSeedSample"], "-StaveDataDirectory"),
        (["-StaveDataDirectory", "relative/path"], "-StaveDataDirectory"),
        (["-StaveDataDirectory", ""], "-StaveDataDirectory"),
        (["-StaveArcHome"], "-StaveArcHome"),
        (["-StaveArcHome", "home"], "-StaveArcHome"),
    ])
    func presentButUnusableThrowsNamingTheFlag(arguments: [String], flag: String) {
        #expect(throws: LaunchArguments.Failure.unusable(flag: flag)) { try LaunchArguments.parse(arguments) }
    }
}

@MainActor
struct WindowSessionSaveTests {
    @Test func scheduledSaveWritesAllWindowsOnceAfterTheDelay() async throws {
        let store = try makeTempStore(now: TestClock().now).0
        _ = try store.ensureDefaultProfile()
        let windows = try store.restoredWindows()
        let session = WindowSession(store: store, saveDelay: .milliseconds(80))
        session.enableSaving()
        session.update(windows[0])
        session.scheduleSave()
        session.scheduleSave()
        #expect(try store.restoredWindows().count == 1)
        var moved = windows[0]
        moved.frame = "{{10, 20}, {900, 700}}"
        session.update(moved)
        session.scheduleSave()
        await session.saveTask?.value
        #expect(try store.restoredWindows().first?.frame == "{{10, 20}, {900, 700}}")
    }

    @Test func saveNowCancelsThePendingSave() async throws {
        let store = try makeTempStore(now: TestClock().now).0
        _ = try store.ensureDefaultProfile()
        let window = try store.restoredWindows()[0]
        let session = WindowSession(store: store, saveDelay: .milliseconds(80))
        session.enableSaving()
        session.update(window)
        session.scheduleSave()
        let pending = session.saveTask
        try session.saveNow()
        session.windowClosed(window.id, isLast: false)
        await pending?.value // without the cancel in saveNow this task would now save the emptied state
        // A delayed save that ran after the removal would have saved nothing, and restore would invent a different default window.
        #expect(try store.restoredWindows().first?.id == window.id)
    }
}

@MainActor
struct WindowSessionLaunchTests {
    @Test func nothingIsWrittenWhileSavingIsDisabled() async throws {
        let store = try makeTempStore(now: TestClock().now).0
        _ = try store.ensureDefaultProfile()
        let saved = try store.restoredWindows()[0]
        try store.saveWindows([saved])
        let session = WindowSession(store: store, saveDelay: .milliseconds(50))
        #expect(!session.isSavingEnabled)
        var other = saved
        other.id = UUID()
        session.update(other) // a launch that got only this far
        session.scheduleSave()
        let pending = session.saveTask
        try session.saveNow()
        await pending?.value
        #expect(try store.restoredWindows().map(\.id) == [saved.id])
    }

    @Test func enablingLetsTheSessionSave() async throws {
        let store = try makeTempStore(now: TestClock().now).0
        _ = try store.ensureDefaultProfile()
        let saved = try store.restoredWindows()[0]
        try store.saveWindows([saved])
        let session = WindowSession(store: store, saveDelay: .milliseconds(50))
        var other = saved
        other.id = UUID()
        session.update(other)
        session.enableSaving()
        session.scheduleSave()
        await session.saveTask?.value
        #expect(try store.restoredWindows().map(\.id) == [other.id])
    }

    @Test func closingTheLastWindowKeepsItUntilANewWindowOpensWithNoneLive() throws {
        let store = try makeTempStore(now: TestClock().now).0
        _ = try store.ensureDefaultProfile()
        let first = try store.restoredWindows()[0]
        let session = WindowSession(store: store)
        session.enableSaving()
        session.update(first)
        session.windowClosed(first.id, isLast: true)
        #expect(session.states.map(\.id) == [first.id]) // kept for the next launch
        session.discardStates(exceptLive: []) // a new window opens with no live window
        var second = first
        second.id = UUID()
        session.update(second)
        #expect(session.states.map(\.id) == [second.id])
        try session.saveNow()
        #expect(try store.restoredWindows().map(\.id) == [second.id]) // quit saves one
    }

    @Test func discardKeepsStatesOfLiveWindows() {
        let session = WindowSession(store: try! makeTempStore(now: TestClock().now).0)
        let profile = UUID(), workspace = UUID()
        let live = WindowState(profileID: profile, workspaceID: workspace, frame: "", sortIndex: 0)
        let gone = WindowState(profileID: profile, workspaceID: workspace, frame: "", sortIndex: 1)
        session.update(live)
        session.update(gone)
        session.discardStates(exceptLive: [live.id])
        #expect(session.states.map(\.id) == [live.id])
    }

    @Test func savingAnEmptyStateSetKeepsTheSavedWindows() throws {
        let store = try makeTempStore(now: TestClock().now).0
        _ = try store.ensureDefaultProfile()
        let saved = try store.restoredWindows()[0]
        try store.saveWindows([saved])
        let session = WindowSession(store: store)
        session.enableSaving()
        try session.save()
        try session.saveNow()
        #expect(try store.restoredWindows().map(\.id) == [saved.id])
    }
}
