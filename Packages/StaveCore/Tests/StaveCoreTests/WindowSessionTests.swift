import CoreGraphics
import Foundation
import Testing
@testable import StaveCore

struct WindowFrameClampTests {
    private let screen = CGRect(x: 0, y: 0, width: 1440, height: 900)

    @Test func frameInsideStaysPut() {
        let frame = CGRect(x: 100, y: 100, width: 800, height: 600)
        #expect(WindowFrameClamp.clamp(frame, visibleFrames: [screen]) == frame)
    }

    @Test func emptyScreensLeaveFrameAlone() {
        let frame = CGRect(x: 5000, y: 5000, width: 800, height: 600)
        #expect(WindowFrameClamp.clamp(frame, visibleFrames: []) == frame)
    }

    @Test func frameHalfOffIsPulledIn() {
        let second = CGRect(x: 1440, y: 0, width: 1920, height: 1080)
        let frame = CGRect(x: 1440 + 1500, y: 200, width: 800, height: 600)
        let result = WindowFrameClamp.clamp(frame, visibleFrames: [screen, second])
        #expect(result.size == frame.size)
        #expect(result == CGRect(x: 3360 - 800, y: 200, width: 800, height: 600))
        #expect(second.contains(result))
    }

    @Test func frameLargerThanScreenShrinks() {
        let frame = CGRect(x: -50, y: -50, width: 3000, height: 2000)
        #expect(WindowFrameClamp.clamp(frame, visibleFrames: [screen]) == screen)
    }

    @Test func frameOnMissingScreenIsCentred() {
        let frame = CGRect(x: 5000, y: 100, width: 800, height: 600)
        let result = WindowFrameClamp.clamp(frame, visibleFrames: [screen])
        #expect(result == CGRect(x: 320, y: 150, width: 800, height: 600))
    }
}

@MainActor
struct WindowSessionTests {
    private func fixture(clock: TestClock = TestClock()) throws -> (OrganizationStore, Profile, Workspace) {
        let (store, _, _) = try makeTempStore(now: clock.now)
        let profile = try store.createProfile(name: "P")
        let workspace = try #require(try store.workspaces(profileID: profile.id).first)
        return (store, profile, workspace)
    }

    private func state(_ profile: Profile, _ workspace: Workspace, frame: String = "0 0 800 600") -> WindowState {
        WindowState(profileID: profile.id, workspaceID: workspace.id, frame: frame, sortIndex: 99)
    }

    @Test func sessionKeepsOrderAndSaves() throws {
        let (store, profile, ws) = try fixture()
        let session = WindowSession(store: store)
        let a = state(profile, ws)
        let b = state(profile, ws)
        session.update(a)
        session.update(b)
        var movedA = a
        movedA.frame = "10 10 900 700"
        session.update(movedA)
        #expect(session.states.map(\.id) == [a.id, b.id])
        #expect(session.states[0].frame == "10 10 900 700")

        try session.save()
        let restored = try store.restoredWindows()
        #expect(restored.map(\.id) == [a.id, b.id])
        #expect(restored.map(\.sortIndex) == [0, 1])
    }

    @Test func closingNonLastRemoves() throws {
        let (store, profile, ws) = try fixture()
        let session = WindowSession(store: store)
        let a = state(profile, ws)
        let b = state(profile, ws)
        session.update(a)
        session.update(b)
        session.windowClosed(a.id, isLast: false)
        #expect(session.states.map(\.id) == [b.id])
        try session.save()
        #expect(try store.restoredWindows().map(\.id) == [b.id])
    }

    @Test func closingLastKeeps() throws {
        let (store, profile, ws) = try fixture()
        let session = WindowSession(store: store)
        let a = state(profile, ws)
        session.update(a)
        session.windowClosed(a.id, isLast: true)
        #expect(session.states.map(\.id) == [a.id])
        try session.save()
        #expect(try store.restoredWindows().map(\.id) == [a.id])
    }

    @Test func launchMaintenanceTrims() throws {
        let clock = TestClock()
        let (store, profile, ws) = try fixture(clock: clock)
        let old = try store.openTab(url: "https://example.com/old", title: "Old", workspaceID: ws.id, origin: .commandBar, containerID: nil, edge: .top)
        let recent = try store.openTab(url: "https://example.com/new", title: "New", workspaceID: ws.id, origin: .commandBar, containerID: nil, edge: .top)
        _ = try store.closeTab(old.id)
        clock.advance(by: 2 * 86_400)
        _ = try store.closeTab(recent.id)
        clock.advance(by: 29 * 86_400)
        #expect(try store.archivedTabs(profileID: profile.id).count == 2)
        try store.launchMaintenance()
        let left = try store.archivedTabs(profileID: profile.id)
        #expect(left.count == 1)
        #expect(left.first?.url == "https://example.com/new")
    }
}
