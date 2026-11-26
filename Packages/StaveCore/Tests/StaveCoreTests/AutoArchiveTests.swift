import Foundation
import GRDB
import Testing
@testable import StaveCore

/// Decision 34 (question 27): archiving idle tabs, off by default.
@MainActor
struct AutoArchiveTests {
    private static let hour: TimeInterval = 3600
    private static let day: TimeInterval = 86_400

    private struct World {
        let store: OrganizationStore
        let database: StaveDatabase
        let clock: TestClock
        let profile: Profile
        let home: Workspace

        func tab(_ name: String) throws -> Tab {
            try store.openTab(
                url: "https://example.com/\(name)", title: name, workspaceID: home.id,
                origin: .commandBar, containerID: nil, edge: .bottom
            )
        }

        func archive(
            limit: AutoArchiveAfter = .hours12, shown: Set<UUID> = [], busy: Set<UUID> = [], among: Set<UUID>? = nil
        ) throws -> Int {
            try store.archiveIdleTabs(profileID: profile.id, now: clock.date, limit: limit, shown: shown, busy: busy, among: among)
        }

        var regularIDs: [UUID] { get throws { try store.regularTabs(workspaceID: home.id).map(\.id) } }

        func stamp(_ id: UUID) throws -> Date? { try database.writer.read { try Tab.fetchOne($0, key: id)?.lastActiveAt } }

        var archivedRows: [ArchivedTab] { get throws { try store.archivedTabs(profileID: profile.id) } }
    }

    private func makeWorld() throws -> World {
        let clock = TestClock()
        let (store, database, _) = try makeTempStore(now: clock.now)
        let profile = try store.ensureDefaultProfile()
        let home = try #require(try store.workspaces(profileID: profile.id).first)
        // An enable time long ago, as after a long-enabled setting; the tests of a missing one delete it.
        try store.setSetting(SettingKeys.autoArchiveEnabledAt, clock.date.addingTimeInterval(-1000 * Self.day))
        return World(store: store, database: database, clock: clock, profile: profile, home: home)
    }

    // MARK: - The store

    @Test func offByDefaultArchivesNothing() throws {
        let world = try makeWorld()
        #expect(try world.store.setting(SettingKeys.autoArchiveAfter) == .never)
        _ = try world.tab("a")
        world.clock.advance(by: 400 * Self.day)
        #expect(try world.archive(limit: .never) == 0)
        #expect(try world.regularIDs.count == 1)
        #expect(try world.store.archivedTabs(profileID: world.profile.id).isEmpty)
    }

    @Test func pinnedAndEssentialsNeverArchived() throws {
        let world = try makeWorld()
        let pinned = try world.tab("pinned")
        let essential = try world.tab("essential")
        let regular = try world.tab("regular")
        try world.store.pinTab(pinned.id, folderID: nil)
        try world.store.makeEssential(essential.id)
        world.clock.advance(by: 2 * Self.day)
        #expect(try world.archive() == 1)
        let archived = try world.store.archivedTabs(profileID: world.profile.id)
        #expect(archived.map(\.url) == [regular.url])
        #expect(try world.store.tabExists(pinned.id))
        #expect(try world.store.tabExists(essential.id))
    }

    @Test func shownTabNeverArchived() throws {
        let world = try makeWorld()
        let shown = try world.tab("shown")
        let idle = try world.tab("idle")
        world.clock.advance(by: 2 * Self.day)
        #expect(try world.archive(shown: [shown.id]) == 1)
        #expect(try world.regularIDs == [shown.id])
        #expect(try world.store.archivedTabs(profileID: world.profile.id).map(\.url) == [idle.url])
    }

    @Test func busyTabNeverArchived() throws {
        let world = try makeWorld()
        let busy = try world.tab("busy")
        _ = try world.tab("idle")
        world.clock.advance(by: 2 * Self.day)
        #expect(try world.archive(busy: [busy.id]) == 1)
        #expect(try world.regularIDs == [busy.id])
    }

    @Test func idleRegularTabArchivedAndRestorable() throws {
        let world = try makeWorld()
        let tab = try world.tab("idle")
        let state = Data([9, 8, 7])
        try world.store.updateNavigation(tabID: tab.id, url: "https://example.com/idle/next", title: "Next", faviconURL: "https://example.com/i.png", interactionState: state)
        world.clock.advance(by: 2 * Self.day)
        #expect(try world.archive() == 1)
        #expect(try world.regularIDs.isEmpty)
        let row = try #require(try world.store.archivedTabs(profileID: world.profile.id).first)
        #expect(row.url == "https://example.com/idle/next" && row.title == "Next")
        #expect(row.interactionState == state && row.workspaceID == world.home.id)
        #expect(row.wasAutoArchived)
        // Restoring is the same call as for a closed tab.
        let restored = try world.store.restoreArchivedTab(row.id, workspaceID: world.home.id)
        #expect(restored.url == "https://example.com/idle/next" && restored.interactionState == state)
        #expect(try world.regularIDs == [restored.id])
        #expect(try world.store.archivedTabs(profileID: world.profile.id).isEmpty)
    }

    @Test func closedTabIsNotMarkedAutoArchived() throws {
        let world = try makeWorld()
        let tab = try world.tab("closed")
        world.clock.advance(by: 5)
        _ = try world.store.closeTab(tab.id)
        let row = try #require(try world.store.archivedTabs(profileID: world.profile.id).first)
        #expect(!row.wasAutoArchived)
    }

    @Test func importedTabsStampedNowAreNotArchived() throws {
        let world = try makeWorld()
        let sidebar = try arcFixture("basic")
        _ = try ArcImporter.run(sidebar: sidebar, localState: nil, options: .init(includeUnpinnedTabs: true), into: world.store)
        let regular = try world.database.writer.read { db in
            try Tab.fetchAll(db).filter { tab in try Slot.fetchOne(db, key: tab.slotID)?.section == .regular }
        }
        #expect(!regular.isEmpty, "the fixture must hold regular tabs for this test to mean anything")
        #expect(regular.allSatisfy { $0.lastActiveAt == world.clock.date })
        world.clock.advance(by: Self.hour)
        for profile in try world.store.profiles() {
            #expect(try world.store.archiveIdleTabs(profileID: profile.id, now: world.clock.date, limit: .hours12, shown: [], busy: []) == 0)
        }
        #expect(try world.database.writer.read { try ArchivedTab.fetchCount($0) } == 0)
    }

    @Test func idleCountsFromWhenTabWasLeft() throws {
        let world = try makeWorld()
        let left = try world.tab("left")
        let untouched = try world.tab("untouched")
        try world.store.markActive(tabID: left.id) // selected at t0 (14 hours before the check)
        world.clock.advance(by: 13 * Self.hour)
        try world.store.markLeft(tabIDs: [left.id]) // left 1 hour before the check
        world.clock.advance(by: Self.hour)
        #expect(try world.archive() == 1)
        #expect(try world.regularIDs == [left.id])
        #expect(try world.store.archivedTabs(profileID: world.profile.id).map(\.url) == [untouched.url])
    }

    @Test func markLeftSkipsTabsThatAreGone() throws {
        let world = try makeWorld()
        let tab = try world.tab("a")
        _ = try world.store.closeTab(tab.id)
        try world.store.markLeft(tabIDs: [tab.id, UUID()]) // never throws for a closed or unknown tab
    }

    @Test func splitSlotNeverArchived() throws {
        let world = try makeWorld()
        let slot = Slot(profileID: world.profile.id, workspaceID: world.home.id, section: .regular, kind: .split, sortIndex: 100, modifiedAt: world.clock.date)
        let first = Tab(slotID: slot.id, url: "https://example.com/s1", title: "s1", lastActiveAt: world.clock.date, modifiedAt: world.clock.date)
        let second = Tab(slotID: slot.id, url: "https://example.com/s2", title: "s2", lastActiveAt: world.clock.date, modifiedAt: world.clock.date)
        try world.database.writer.write { db in
            try slot.insert(db); try first.insert(db); try second.insert(db)
        }
        world.clock.advance(by: 40 * Self.day)
        #expect(try world.archive(limit: .days30) == 0)
        #expect(try world.store.tabExists(first.id) && world.store.tabExists(second.id))
        #expect(try world.database.writer.read { try ArchivedTab.fetchCount($0) } == 0)
    }

    @Test func shownAtQuitNotArchivedAtLaunch() throws {
        let world = try makeWorld()
        let shownAtQuit = try world.tab("shown")
        let other = try world.tab("other")
        try world.store.markActive(tabID: shownAtQuit.id) // selected 2 days ago ...
        world.clock.advance(by: 2 * Self.day)
        // ... and still shown at quit: the quit save stamps it with the quit time (through the real session and store).
        let session = WindowSession(store: world.store)
        session.selectedTabIDs = { [shownAtQuit.id] }
        session.update(WindowState(profileID: world.profile.id, workspaceID: world.home.id, selectedTabID: shownAtQuit.id, frame: "", sortIndex: 0))
        session.enableSaving()
        try session.saveNow()
        #expect(try world.stamp(shownAtQuit.id) == world.clock.date)
        world.clock.advance(by: Self.hour) // the next launch, with the tab's window not restored (`shown` empty)
        #expect(try world.archive(shown: []) == 1)
        #expect(try world.regularIDs == [shownAtQuit.id])
        #expect(try world.store.archivedTabs(profileID: world.profile.id).map(\.url) == [other.url])
    }

    @Test func archiveIsPerProfile() throws {
        let world = try makeWorld()
        let other = try world.store.createProfile(name: "Other")
        let otherHome = try #require(try world.store.workspaces(profileID: other.id).first)
        _ = try world.store.openTab(url: "https://example.org/", title: "o", workspaceID: otherHome.id, origin: .commandBar, containerID: nil, edge: .bottom)
        _ = try world.tab("mine")
        world.clock.advance(by: 2 * Self.day)
        #expect(try world.archive() == 1)
        #expect(try world.store.regularTabs(workspaceID: otherHome.id).count == 1)
    }

    // MARK: - The pure policy

    @Test func policyKeepsEverythingButOldRegularTabs() {
        let now = Date(timeIntervalSince1970: 2_000_000_000)
        func candidate(_ section: SlotSection, _ kind: SlotKind = .tab, age: TimeInterval) -> AutoArchiveCandidate {
            AutoArchiveCandidate(tabID: UUID(), section: section, slotKind: kind, lastActiveAt: now.addingTimeInterval(-age))
        }
        let old = candidate(.regular, age: 13 * Self.hour)
        let exactly = candidate(.regular, age: 12 * Self.hour) // not older than the limit
        let fresh = candidate(.regular, age: Self.hour)
        let pinned = candidate(.pinned, age: 99 * Self.day)
        let essential = candidate(.essential, age: 99 * Self.day)
        let split = candidate(.regular, .split, age: 99 * Self.day)
        let all = [old, exactly, fresh, pinned, essential, split]
        #expect(AutoArchivePolicy.toArchive(all, now: now, limit: .hours12, shown: [], busy: []) == [old.tabID])
        #expect(AutoArchivePolicy.toArchive(all, now: now, limit: .never, shown: [], busy: []).isEmpty)
        #expect(AutoArchivePolicy.toArchive(all, now: now, limit: .hours12, shown: [old.tabID], busy: []).isEmpty)
        #expect(AutoArchivePolicy.toArchive(all, now: now, limit: .hours12, shown: [], busy: [old.tabID]).isEmpty)
    }

    @Test func limitsAndLabels() {
        #expect(AutoArchiveAfter.allCases == [.never, .hours12, .day1, .days7, .days30])
        #expect(AutoArchiveAfter.allCases.map(\.title) == ["Never", "12 hours", "1 day", "7 days", "30 days"])
        #expect(AutoArchiveAfter.never.interval == nil)
        #expect(AutoArchiveAfter.hours12.interval == 12 * Self.hour)
        #expect(AutoArchiveAfter.days30.interval == 30 * Self.day)
        #expect(AutoArchiveAfter.settingTitle == "Archive idle tabs after")
    }

    // MARK: - The launch ordering

    @Test func launchCheckWaitsForRestoredWindows() throws {
        let world = try makeWorld()
        let selected = try world.tab("selected")
        let idle = try world.tab("idle")
        world.clock.advance(by: 2 * Self.day)
        let livePages = LivePageRegistry()
        var archived = -1
        let schedule = AutoArchiveSchedule {
            archived = (try? world.archive(shown: livePages.shownTabs)) ?? -2
        }
        schedule.requestCheck() // asked for before the windows are restored
        #expect(archived == -1)
        #expect(try world.regularIDs.count == 2)
        // The saved window is restored: its selected tab is registered with the registry ...
        let state = WindowState(profileID: world.profile.id, workspaceID: world.home.id, selectedTabID: selected.id, frame: "", sortIndex: 0)
        let model = try BrowserWindowModel(store: world.store, revision: StoreRevision(), livePages: livePages, state: state)
        #expect(model.selectedTabID == selected.id)
        #expect(archived == -1)
        // ... and only then does the waiting check run, once.
        schedule.launchCompleted()
        #expect(archived == 1)
        #expect(try world.regularIDs == [selected.id])
        #expect(try world.store.archivedTabs(profileID: world.profile.id).map(\.url) == [idle.url])
        archived = -1
        schedule.launchCompleted() // not run twice
        #expect(archived == -1)
        schedule.requestCheck() // after launch a check runs at once
        #expect(archived == 0)
    }

    @Test func scheduleWithoutAWaitingCheckRunsNothingAtLaunch() {
        var runs = 0
        let schedule = AutoArchiveSchedule { runs += 1 }
        schedule.launchCompleted()
        #expect(runs == 0)
        #expect(AutoArchiveSchedule.interval == 900)
    }

    // MARK: - Leaving a tab, in a window

    @Test func deselectingAndClosingAWindowStampTheTab() throws {
        let world = try makeWorld()
        let a = try world.tab("a")
        let b = try world.tab("b")
        let livePages = LivePageRegistry()
        let state = WindowState(profileID: world.profile.id, workspaceID: world.home.id, selectedTabID: nil, frame: "", sortIndex: 0)
        let model = try BrowserWindowModel(store: world.store, revision: StoreRevision(), livePages: livePages, state: state)
        func stamp(_ id: UUID) throws -> Date? { try world.stamp(id) }
        world.clock.advance(by: Self.hour)
        model.select(a.id)
        let selectedA = world.clock.date
        world.clock.advance(by: 5 * Self.hour)
        model.select(b.id) // leaves a
        #expect(try stamp(a.id) == world.clock.date)
        #expect(try stamp(a.id) != selectedA)
        world.clock.advance(by: Self.hour)
        model.select(nil) // leaves b
        #expect(try stamp(b.id) == world.clock.date)
        model.select(a.id)
        world.clock.advance(by: Self.hour)
        model.windowWillClose() // closing the window leaves a
        #expect(try stamp(a.id) == world.clock.date)
        #expect(livePages.shownTabs.isEmpty)
    }

    @Test func registryListsEveryShownTab() {
        let registry = LivePageRegistry()
        let (a, b, c) = (UUID(), UUID(), UUID())
        let (w1, w2) = (UUID(), UUID())
        registry.show(a, in: w1)
        registry.show(a, in: w2) // wanted by a second window, owned by the first
        registry.show(b, in: w2)
        #expect(registry.shownTabs == [a, b])
        registry.windowClosed(w2)
        #expect(registry.shownTabs == [a])
        registry.windowClosed(w1)
        #expect(registry.shownTabs.isEmpty && !registry.shownTabs.contains(c))
    }

    @Test func everySavedWriteStampsTheShownTabs() throws {
        let world = try makeWorld()
        let shown = try world.tab("shown")
        let session = WindowSession(store: world.store)
        session.selectedTabIDs = { [shown.id] }
        let before = try world.stamp(shown.id)
        world.clock.advance(by: Self.hour)
        try session.save() // no window known and saving not enabled: nothing is written, nothing is stamped
        #expect(try world.stamp(shown.id) == before)
        session.update(WindowState(profileID: world.profile.id, workspaceID: world.home.id, selectedTabID: shown.id, frame: "", sortIndex: 0))
        try session.save() // still not enabled
        #expect(try world.stamp(shown.id) == before)
        session.enableSaving()
        try session.saveNow()
        #expect(try world.stamp(shown.id) == world.clock.date)
        world.clock.advance(by: Self.hour)
        try session.save() // every write stamps, the debounced one and the quit one alike
        #expect(try world.stamp(shown.id) == world.clock.date)
    }

    // MARK: - Shift-Command-T

    @Test func reopenLastClosedSkipsAutoArchivedRows() throws {
        let world = try makeWorld()
        let closedByUser = try world.tab("closed")
        let idle = try world.tab("idle")
        world.clock.advance(by: 5)
        _ = try world.store.closeTab(closedByUser.id) // the user's own close, earlier ...
        world.clock.advance(by: 2 * Self.day)
        #expect(try world.archive() == 1) // ... the idle archive is newer by closedAt
        let rows = try world.store.archivedTabs(profileID: world.profile.id)
        #expect(rows.first?.url == idle.url && rows.first?.wasAutoArchived == true)
        let state = WindowState(profileID: world.profile.id, workspaceID: world.home.id, selectedTabID: nil, frame: "", sortIndex: 0)
        let model = try BrowserWindowModel(store: world.store, revision: StoreRevision(), livePages: LivePageRegistry(), state: state)
        model.reopenLastClosed()
        #expect(model.snapshot.regular.map(\.url) == [closedByUser.url])
        #expect(try world.store.archivedTabs(profileID: world.profile.id).map(\.url) == [idle.url]) // still restorable from the archive
        model.reopenLastClosed() // nothing the user closed is left: the auto-archived row stays put
        #expect(model.snapshot.regular.map(\.url) == [closedByUser.url])
        #expect(try world.store.archivedTabs(profileID: world.profile.id).count == 1)
    }

    // MARK: - Fix round 1

    /// H1: a tab that enters the regular section starts its idle time then, not at its old `lastActiveAt`.
    @Test func unpinnedTabStartsItsIdleTimeAtTheUnpin() throws {
        let world = try makeWorld()
        let tab = try world.tab("pinned")
        try world.store.pinTab(tab.id, folderID: nil)
        world.clock.advance(by: 2 * Self.day)
        try world.store.unpinTab(tab.id)
        world.clock.advance(by: Self.hour)
        #expect(try world.archive() == 0)
        #expect(try world.regularIDs == [tab.id])
        world.clock.advance(by: 12 * Self.hour)
        #expect(try world.archive() == 1)
    }

    @Test func essentialDraggedToRegularStartsItsIdleTime() throws {
        let world = try makeWorld()
        let tab = try world.tab("essential")
        try world.store.makeEssential(tab.id)
        world.clock.advance(by: 2 * Self.day)
        try world.store.moveTab(tab.id, toWorkspace: world.home.id, section: .regular, folderID: nil, after: nil)
        world.clock.advance(by: Self.hour)
        #expect(try world.archive() == 0)
        #expect(try world.stamp(tab.id) == world.clock.date.addingTimeInterval(-Self.hour))
    }

    @Test func tabMovedToAnotherWorkspaceStartsItsIdleTime() throws {
        let world = try makeWorld()
        let other = try world.store.createWorkspace(profileID: world.profile.id, name: "Other", icon: "star", colorHex: "#FF0000")
        let moved = try world.tab("moved")
        let stayed = try world.tab("stayed")
        world.clock.advance(by: 2 * Self.day)
        try world.store.moveTab(moved.id, toWorkspace: other.id, section: .regular, folderID: nil, after: nil)
        world.clock.advance(by: Self.hour)
        #expect(try world.archive() == 1) // only the tab that stayed is old
        #expect(try world.store.regularTabs(workspaceID: other.id).map(\.id) == [moved.id])
        #expect(try world.archivedRows.map(\.url) == [stayed.url])
    }

    @Test func reorderingInTheSameWorkspaceKeepsTheIdleTime() throws {
        let world = try makeWorld()
        let tab = try world.tab("a")
        let before = try world.stamp(tab.id)
        world.clock.advance(by: 2 * Self.day)
        try world.store.moveTab(tab.id, toWorkspace: world.home.id, section: .regular, folderID: nil, after: nil)
        #expect(try world.stamp(tab.id) == before)
    }

    /// M2: only tabs the busy check covered are archived, whatever became idle during the checks.
    @Test func archiveStaysWithinTheTabsThatWereChecked() throws {
        let world = try makeWorld()
        let checked = try world.tab("checked")
        let late = try world.tab("late")
        world.clock.advance(by: 2 * Self.day)
        #expect(try world.archive(among: [checked.id]) == 1)
        #expect(try world.regularIDs == [late.id])
        #expect(try world.archive(among: []) == 0)
        #expect(try world.archive(among: nil) == 1)
    }

    /// L5: leaving one tab for another is one write: the old tab is stamped, then the new one, and a missing new tab keeps the stamp.
    @Test func selectingStampsTheTabLeftFirstInOneWrite() throws {
        let world = try makeWorld()
        let old = try world.tab("old")
        let new = try world.tab("new")
        world.clock.advance(by: Self.hour)
        try world.store.markSelected(new.id, leaving: old.id)
        #expect(try world.stamp(old.id) == world.clock.date && world.stamp(new.id) == world.clock.date)
        world.clock.advance(by: Self.hour)
        #expect(throws: StoreError.self) { try world.store.markSelected(UUID(), leaving: new.id) }
        #expect(try world.stamp(new.id) == world.clock.date)
        try world.store.markSelected(old.id, leaving: UUID()) // a left tab that is gone is skipped
    }

    // MARK: L6, the wall clock

    @Test func clockJumpGuardSkipsAJumpAndRebaselines() {
        var clockGuard = ClockJumpGuard()
        let wall = Date(timeIntervalSince1970: 1_700_000_000)
        let start = ContinuousClock.now
        #expect(clockGuard.verdict(wall: wall, instant: start) == .proceed) // the first check has no reference
        // A normal 15 minutes.
        #expect(clockGuard.verdict(wall: wall.addingTimeInterval(900), instant: start.advanced(by: .seconds(900))) == .proceed)
        // Slept overnight: both clocks advanced 8 hours, so it is not a jump (sleep counts as idle).
        let wake = wall.addingTimeInterval(900 + 8 * Self.hour)
        #expect(clockGuard.verdict(wall: wake, instant: start.advanced(by: .seconds(900 + 8 * 3600))) == .proceed)
        // The wall clock moved a week ahead while the monotonic clock moved 15 minutes.
        let jumped = wake.addingTimeInterval(900 + 7 * Self.day)
        #expect(clockGuard.verdict(wall: jumped, instant: start.advanced(by: .seconds(900 + 8 * 3600 + 900))) == .skip(.wallClockJumpedForward))
        // The next check measures from the new reading, so it proceeds.
        #expect(clockGuard.verdict(wall: jumped.addingTimeInterval(900), instant: start.advanced(by: .seconds(900 + 8 * 3600 + 1800))) == .proceed)
        // Back a day.
        let back = jumped.addingTimeInterval(900 - Self.day)
        #expect(clockGuard.verdict(wall: back, instant: start.advanced(by: .seconds(900 + 8 * 3600 + 2700))) == .skip(.wallClockWentBack))
        #expect(clockGuard.verdict(wall: back.addingTimeInterval(900), instant: start.advanced(by: .seconds(900 + 8 * 3600 + 3600))) == .proceed)
    }

    @Test func clockJumpGuardAllowsAnHourOfSlack() {
        var clockGuard = ClockJumpGuard()
        let wall = Date(timeIntervalSince1970: 1_700_000_000)
        let start = ContinuousClock.now
        _ = clockGuard.verdict(wall: wall, instant: start)
        // 59 minutes more than the monotonic clock: inside the slack (a time-zone-free correction, a slow sync).
        #expect(clockGuard.verdict(wall: wall.addingTimeInterval(900 + 3540), instant: start.advanced(by: .seconds(900))) == .proceed)
        // Two hours more: a jump.
        #expect(clockGuard.verdict(wall: wall.addingTimeInterval(900 + 3540 + 900 + 7200), instant: start.advanced(by: .seconds(1800))) == .skip(.wallClockJumpedForward))
    }

    /// R1-1: after a forward jump the enable time moves to the new reading, so the checks that follow archive nothing for a full limit.
    @Test func forwardClockJumpGivesEveryTabAFullLimit() throws {
        let world = try makeWorld()
        _ = try world.tab("a")
        var clockGuard = ClockJumpGuard()
        let start = ContinuousClock.now
        #expect(world.store.checkClock(&clockGuard, wall: world.clock.date, instant: start) == .proceed)
        world.clock.advance(by: 7 * Self.day) // the wall clock jumps a week; 15 minutes pass on the monotonic clock
        let first = world.store.checkClock(&clockGuard, wall: world.clock.date, instant: start.advanced(by: .seconds(900)))
        #expect(first == .skip(.wallClockJumpedForward))
        #expect(try world.archive() == 0)
        world.clock.advance(by: 900)
        let second = world.store.checkClock(&clockGuard, wall: world.clock.date, instant: start.advanced(by: .seconds(1800)))
        #expect(second == .proceed)
        #expect(try world.archive() == 0) // without the restart this archives the tab
        world.clock.advance(by: 13 * Self.hour)
        #expect(try world.archive() == 1) // a full limit after the jump it does
    }

    // MARK: R1-2, an enable time that is missing

    @Test func missingEnableTimeCountsAsNowAndIsWritten() throws {
        let world = try makeWorld()
        _ = try world.tab("a")
        try world.store.setSetting(SettingKeys.autoArchiveAfter, AutoArchiveAfter.hours12) // the limit row is there, the time is not
        try world.database.writer.write { try $0.execute(sql: "DELETE FROM setting WHERE key = 'autoArchiveEnabledAt'") }
        world.clock.advance(by: 30 * Self.day)
        #expect(try world.archive() == 0)
        #expect(try world.store.setting(SettingKeys.autoArchiveEnabledAt) == world.clock.date)
        world.clock.advance(by: 13 * Self.hour)
        #expect(try world.archive() == 1)
    }

    @Test func unreadableEnableTimeCountsAsNowAndIsRewritten() throws {
        let world = try makeWorld()
        _ = try world.tab("a")
        try world.store.setSetting(SettingKeys.autoArchiveAfter, AutoArchiveAfter.hours12)
        try world.database.writer.write {
            try $0.execute(sql: "UPDATE setting SET value = '\"not a date\"' WHERE key = 'autoArchiveEnabledAt'")
        }
        world.clock.advance(by: 30 * Self.day)
        #expect(try world.store.idleTabIDs(profileID: world.profile.id, now: world.clock.date, limit: .hours12, shown: [], busy: []).isEmpty)
        #expect(try world.store.setting(SettingKeys.autoArchiveEnabledAt) == world.clock.date)
    }

    // MARK: R1-5, a failed stamp

    @Test func failedStampDoesNotUndoTheSelection() throws {
        let world = try makeWorld()
        let a = try world.tab("a")
        let state = WindowState(profileID: world.profile.id, workspaceID: world.home.id, selectedTabID: nil, frame: "", sortIndex: 0)
        let model = try BrowserWindowModel(store: world.store, revision: StoreRevision(), livePages: LivePageRegistry(), state: state)
        try world.database.writer.write {
            try $0.execute(sql: "CREATE TRIGGER failStamp BEFORE UPDATE ON tab BEGIN SELECT RAISE(ABORT, 'stamp failed'); END")
        }
        model.select(a.id)
        #expect(model.selectedTabID == a.id)
        #expect(model.lastError == nil)
    }

    // MARK: L7, the first enable

    @Test func turningItOnDoesNotArchiveWhatWasAlreadyOld() throws {
        let world = try makeWorld()
        let old = try world.tab("old")
        world.clock.advance(by: 30 * Self.day)
        try world.store.setAutoArchiveAfter(.hours12) // Never to a limit: idle time starts now
        #expect(try world.store.setting(SettingKeys.autoArchiveAfter) == .hours12)
        #expect(try world.archive() == 0)
        world.clock.advance(by: 11 * Self.hour)
        #expect(try world.archive() == 0)
        let fresh = try world.tab("fresh") // opened after enabling: counts from its own time
        world.clock.advance(by: 2 * Self.hour)
        #expect(try world.archive() == 1) // the old tab has now been idle 13 hours since enabling
        #expect(try world.regularIDs == [fresh.id])
        #expect(try world.archivedRows.map(\.url) == [old.url])
        #expect(try world.archivedRows.allSatisfy(\.wasAutoArchived))
    }

    @Test func changingBetweenLimitsKeepsTheEnableTimeAndTurningItOffAndOnRestartsIt() throws {
        let world = try makeWorld()
        _ = try world.tab("a")
        try world.store.setAutoArchiveAfter(.days30)
        let first = try #require(try world.store.setting(SettingKeys.autoArchiveEnabledAt))
        world.clock.advance(by: Self.day)
        try world.store.setAutoArchiveAfter(.hours12) // a limit to a limit: the time stays
        #expect(try world.store.setting(SettingKeys.autoArchiveEnabledAt) == first)
        #expect(try world.archive() == 1) // it has been idle since enabling, a day
        _ = try world.tab("b")
        world.clock.advance(by: 3 * Self.day)
        try world.store.setAutoArchiveAfter(.never)
        try world.store.setAutoArchiveAfter(.hours12) // Never to a limit again: restarts
        let second = try #require(try world.store.setting(SettingKeys.autoArchiveEnabledAt))
        #expect(second == world.clock.date)
        #expect(try world.archive() == 0)
    }

    // MARK: L4, closes are never auto-archived

    @Test func everyUserArchiveWriterLeavesRowsThatAreNotAutoArchived() throws {
        let world = try makeWorld()
        let pinned = try world.tab("pinned")
        try world.store.pinTab(pinned.id, folderID: nil)
        let essential = try world.tab("essential")
        try world.store.makeEssential(essential.id)
        world.clock.advance(by: 3 * Self.day)
        try world.store.removePinnedTab(pinned.id)
        try world.store.removeEssential(essential.id)
        #expect(try world.archivedRows.count == 2 && world.archivedRows.allSatisfy { !$0.wasAutoArchived })
    }

    @Test func workspaceDeleteLeavesRowsThatAreNotAutoArchived() throws {
        let world = try makeWorld()
        let other = try world.store.createWorkspace(profileID: world.profile.id, name: "Other", icon: "star", colorHex: "#FF0000")
        for name in ["a", "b"] {
            let tab = try world.store.openTab(url: "https://example.com/\(name)", title: name, workspaceID: other.id, origin: .commandBar, containerID: nil, edge: .bottom)
            if name == "b" { try world.store.pinTab(tab.id, folderID: nil) }
        }
        world.clock.advance(by: 3 * Self.day)
        try world.store.deleteWorkspace(other.id)
        #expect(try world.archivedRows.count == 2 && world.archivedRows.allSatisfy { !$0.wasAutoArchived })
    }

    @Test func driftedPagesArchivedOnUnpinAndRestoreAreNotAutoArchived() throws {
        let world = try makeWorld()
        let tab = try world.tab("pinned")
        try world.store.pinTab(tab.id, folderID: nil)
        try world.store.updateNavigation(tabID: tab.id, url: "https://example.com/elsewhere", title: "Elsewhere", faviconURL: nil, interactionState: nil)
        world.clock.advance(by: 3 * Self.day)
        try world.store.unpinTab(tab.id) // archives the pinned page
        #expect(try world.archivedRows.count == 1 && world.archivedRows.allSatisfy { !$0.wasAutoArchived })
        // A drifted pinned tab closed through removePinnedTab is archived with its pinned page; restoring that row archives the pinned page too.
        let second = try world.tab("second")
        try world.store.pinTab(second.id, folderID: nil)
        try world.store.updateNavigation(tabID: second.id, url: "https://example.com/second-elsewhere", title: "Elsewhere 2", faviconURL: nil, interactionState: nil)
        try world.store.removePinnedTab(second.id)
        let row = try #require(try world.archivedRows.first { $0.pinnedURL != nil })
        world.clock.advance(by: Self.day)
        _ = try world.store.restoreArchivedTab(row.id, workspaceID: world.home.id)
        #expect(try world.archivedRows.count == 2 && world.archivedRows.allSatisfy { !$0.wasAutoArchived })
    }
}
