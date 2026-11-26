import Foundation
import GRDB
import Testing
@testable import StaveCore

/// History (plan 5 decision 9, questions 15 and 16): one row per visit, merged within 30 minutes, cleared and trimmed without touching
/// tabs or the archive, and never copied into a backup.
@MainActor
struct HistoryTests {
    private struct World {
        let store: OrganizationStore
        let database: StaveDatabase
        let file: URL
        let clock: TestClock
        let profile: Profile
        let home: Workspace
    }

    private func makeWorld() throws -> World {
        let clock = TestClock()
        let (store, database, file) = try makeTempStore(now: clock.now)
        let profile = try store.ensureDefaultProfile()
        let home = try #require(try store.workspaces(profileID: profile.id).first)
        return World(store: store, database: database, file: file, clock: clock, profile: profile, home: home)
    }

    /// A fixed calendar and time zone, so day boundaries never depend on the machine running the tests.
    private static let calendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Europe/Berlin")!
        return calendar
    }()

    private func visits(_ world: World) throws -> [HistoryVisit] {
        try world.store.history(profileID: world.profile.id, matching: "", limit: 1000)
    }

    private func count(_ world: World) throws -> Int {
        try world.database.writer.read { db in try HistoryVisit.fetchCount(db) }
    }

    // MARK: - Recording

    @Test func visitRecordedOnce() throws {
        let world = try makeWorld()
        let first = world.clock.date
        try world.store.recordVisit(profileID: world.profile.id, url: "https://example.com/a", title: "Alpha", at: first)
        let later = first.addingTimeInterval(10 * 60)
        try world.store.recordVisit(profileID: world.profile.id, url: "https://example.com/a", title: "", at: later)
        let rows = try visits(world)
        #expect(rows.count == 1)
        #expect(rows.first?.visitedAt == OrganizationStore.storedPrecision(later))
        #expect(rows.first?.title == "Alpha") // an empty title at commit keeps the one already known
    }

    @Test func visitsSeparateAfterThirtyMinutes() throws {
        let world = try makeWorld()
        let first = world.clock.date
        try world.store.recordVisit(profileID: world.profile.id, url: "https://example.com/a", title: "Alpha", at: first)
        try world.store.recordVisit(profileID: world.profile.id, url: "https://example.com/a", title: "Alpha", at: first.addingTimeInterval(31 * 60))
        // Another page in between never merges with the first.
        try world.store.recordVisit(profileID: world.profile.id, url: "https://example.org/b", title: "Beta", at: first.addingTimeInterval(32 * 60))
        let rows = try visits(world)
        #expect(rows.map(\.url) == ["https://example.org/b", "https://example.com/a", "https://example.com/a"])
    }

    @Test func titleArrivesLater() throws {
        let world = try makeWorld()
        try world.store.recordVisit(profileID: world.profile.id, url: "https://example.com/a", title: "", at: world.clock.date)
        try world.store.updateVisitTitle(profileID: world.profile.id, url: "https://example.com/a", title: "Arrived")
        #expect(try visits(world).map(\.title) == ["Arrived"])
        // A blank title never erases a known one.
        try world.store.updateVisitTitle(profileID: world.profile.id, url: "https://example.com/a", title: "  ")
        #expect(try visits(world).map(\.title) == ["Arrived"])
        // Only the newest visit of the URL takes the title.
        try world.store.recordVisit(profileID: world.profile.id, url: "https://example.com/a", title: "", at: world.clock.date.addingTimeInterval(3600))
        try world.store.updateVisitTitle(profileID: world.profile.id, url: "https://example.com/a", title: "Newer")
        #expect(try visits(world).map(\.title) == ["Newer", "Arrived"])
    }

    @Test func nonWebURLsNotRecorded() throws {
        let world = try makeWorld()
        let refused = [
            "", "about:blank", "javascript:alert(1)", "data:text/html,x", "file:///private/tmp/page.html", "blob:https://example.com/1",
            "https://", "ftp://example.com/", "https://example.com/" + String(repeating: "a", count: HistoryRules.maxURLLength),
        ]
        for url in refused {
            try world.store.recordVisit(profileID: world.profile.id, url: url, title: "T", at: world.clock.date)
            #expect(!HistoryRules.isRecordable(url), "\(url.prefix(40)) counted as recordable")
        }
        #expect(try count(world) == 0)
        try world.store.recordVisit(profileID: world.profile.id, url: "http://example.net/", title: "T", at: world.clock.date)
        #expect(try count(world) == 1)
    }

    @Test func longTitleIsCapped() throws {
        let world = try makeWorld()
        let long = String(repeating: "t", count: HistoryRules.maxTitleLength * 3)
        try world.store.recordVisit(profileID: world.profile.id, url: "https://example.com/", title: long, at: world.clock.date)
        #expect(try visits(world).first?.title.count == HistoryRules.maxTitleLength)
    }

    // MARK: - Reading

    @Test func searchMatchesTitleAndAddress() throws {
        let world = try makeWorld()
        try world.store.recordVisit(profileID: world.profile.id, url: "https://example.com/news", title: "Morning Paper", at: world.clock.date)
        try world.store.recordVisit(profileID: world.profile.id, url: "https://example.org/", title: "Recipes", at: world.clock.date.addingTimeInterval(60))
        try world.store.recordVisit(profileID: world.profile.id, url: "https://example.net/100%_off", title: "Sale", at: world.clock.date.addingTimeInterval(120))
        #expect(try world.store.history(profileID: world.profile.id, matching: "paper", limit: 10).map(\.title) == ["Morning Paper"])
        #expect(try world.store.history(profileID: world.profile.id, matching: "EXAMPLE.ORG", limit: 10).map(\.title) == ["Recipes"])
        // LIKE wildcards in the typed text are taken literally.
        #expect(try world.store.history(profileID: world.profile.id, matching: "%_", limit: 10).map(\.title) == ["Sale"])
        #expect(try world.store.history(profileID: world.profile.id, matching: "", limit: 2).map(\.title) == ["Sale", "Recipes"])
    }

    @Test func historyPagesDontDropTies() throws {
        let world = try makeWorld()
        let second = world.clock.date
        for name in ["a", "b", "c"] {
            try world.store.recordVisit(profileID: world.profile.id, url: "https://example.com/\(name)", title: name, at: second)
        }
        let first = try world.store.historyPage(profileID: world.profile.id, matching: "", after: nil, limit: 2)
        #expect(first.visits.count == 2)
        let cursor = try #require(first.next)
        let rest = try world.store.historyPage(profileID: world.profile.id, matching: "", after: cursor, limit: 2)
        #expect(rest.visits.count == 1)
        #expect(rest.next == nil)
        #expect(Set((first.visits + rest.visits).map(\.title)) == ["a", "b", "c"])
    }

    @Test func historyIsPerProfile() throws {
        let world = try makeWorld()
        let other = try world.store.createProfile(name: "Work")
        try world.store.recordVisit(profileID: world.profile.id, url: "https://example.com/", title: "Mine", at: world.clock.date)
        try world.store.recordVisit(profileID: other.id, url: "https://example.org/", title: "Theirs", at: world.clock.date)
        #expect(try visits(world).map(\.title) == ["Mine"])
    }

    // MARK: - Removing

    /// Review Focus 4: Clear History removes history rows only.
    @Test func clearHistoryLeavesArchiveAndTabs() throws {
        let world = try makeWorld()
        let open = try world.store.openTab(url: "https://example.com/open", title: "Open", workspaceID: world.home.id, origin: .commandBar, containerID: nil, edge: .bottom)
        let closing = try world.store.openTab(url: "https://example.com/closed", title: "Closed", workspaceID: world.home.id, origin: .commandBar, containerID: nil, edge: .bottom)
        _ = try world.store.closeTab(closing.id)
        let pinnedSource = try world.store.openTab(url: "https://example.com/pinned", title: "Pinned", workspaceID: world.home.id, origin: .commandBar, containerID: nil, edge: .bottom)
        try world.store.pinTab(pinnedSource.id, folderID: nil)
        for url in ["https://example.com/open", "https://example.com/closed", "https://example.com/pinned"] {
            try world.store.recordVisit(profileID: world.profile.id, url: url, title: "", at: world.clock.date)
        }
        let before = try world.store.sidebarSnapshot(workspaceID: world.home.id)
        let archiveBefore = try world.store.archivedTabs(profileID: world.profile.id)

        #expect(try world.store.clearHistory(profileID: world.profile.id, since: nil) == 3)

        #expect(try count(world) == 0)
        #expect(try world.store.sidebarSnapshot(workspaceID: world.home.id) == before)
        #expect(try world.store.archivedTabs(profileID: world.profile.id) == archiveBefore)
        #expect(try world.store.tabExists(open.id))
        #expect(archiveBefore.count == 1)
    }

    /// Review Focus 4: Clear History also removes the profile's ended download rows in the range, never a file, and keeps a running row.
    @MainActor @Test func clearHistoryClearsEndedDownloads() throws {
        let world = try makeWorld()
        let clock = world.clock
        let list = DownloadList(store: world.store, retention: { .manually }, now: { clock.date })
        let owner = DownloadOwner.profile(world.profile.id)
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("StaveClearDL-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        func download(_ name: String, finish: Bool) throws -> (UUID, URL) {
            let file = dir.appendingPathComponent(name)
            try Data("x".utf8).write(to: file)
            let id = list.begin(owner: owner, filename: name, sourceHost: nil)
            if finish { list.finish(id, at: file) }
            return (id, file)
        }
        let old = try download("old.txt", finish: true)
        clock.advance(by: 3 * 86_400)
        let recentDone = try download("recent.txt", finish: true)
        let recentFailed = list.begin(owner: owner, filename: "bad.bin", sourceHost: nil)
        list.fail(recentFailed, message: "no")
        let running = try download("running.bin", finish: false)
        let since = clock.date.addingTimeInterval(-3600)

        _ = try world.store.clearHistory(profileID: world.profile.id, since: since)
        list.forgetEnded(owner: owner, since: since) // the open list follows the store

        let ids = list.items(for: owner).map(\.id)
        #expect(ids.contains(old.0), "before the range: kept")
        #expect(!ids.contains(recentDone.0) && !ids.contains(recentFailed), "ended rows in the range go")
        #expect(ids.contains(running.0), "a running download's row is kept")
        for file in [old.1, recentDone.1, running.1] { #expect(FileManager.default.fileExists(atPath: file.path)) }

        _ = try world.store.clearHistory(profileID: world.profile.id, since: nil)
        let left = try world.database.writer.read { db in try DownloadRecord.fetchAll(db) }
        #expect(left.map(\.filename) == ["running.bin"], "all history clears every ended row, never a running one")
    }

    @Test func clearRanges() throws {
        let world = try makeWorld()
        let calendar = Self.calendar
        // 2026-11-14 10:00 in Berlin.
        let now = try #require(calendar.date(from: DateComponents(year: 2026, month: 11, day: 14, hour: 10)))
        let ages: [(String, TimeInterval)] = [
            ("tenMinutes", 10 * 60), ("twoHours", 2 * 3600), ("yesterday", 20 * 3600), ("twoDays", 50 * 3600),
        ]
        func seed() throws {
            _ = try world.store.clearHistory(profileID: world.profile.id, since: nil)
            for (name, age) in ages {
                try world.store.recordVisit(profileID: world.profile.id, url: "https://example.com/\(name)", title: name, at: now.addingTimeInterval(-age))
            }
        }
        let expectations: [(HistoryClearRange, [String])] = [
            (.lastHour, ["twoHours", "yesterday", "twoDays"]),
            (.today, ["yesterday", "twoDays"]),
            (.todayAndYesterday, ["twoDays"]),
            (.all, []),
        ]
        for (range, kept) in expectations {
            try seed()
            _ = try world.store.clearHistory(profileID: world.profile.id, since: range.since(now: now, calendar: calendar))
            #expect(try visits(world).map(\.title) == kept, "\(range)")
        }
        #expect(HistoryClearRange.allCases.map(\.title) == ["the last hour", "today", "today and yesterday", "all history"])
    }

    @Test func trimByRetention() throws {
        let world = try makeWorld()
        let calendar = Self.calendar
        let now = try #require(calendar.date(from: DateComponents(year: 2026, month: 11, day: 14, hour: 10)))
        let days: [Int] = [0, 2, 10, 20, 40, 400]
        func seed() throws {
            _ = try world.store.clearHistory(profileID: world.profile.id, since: nil)
            for age in days {
                let at = try #require(calendar.date(byAdding: .day, value: -age, to: now))
                try world.store.recordVisit(profileID: world.profile.id, url: "https://example.com/\(age)", title: "\(age)", at: at)
            }
        }
        let expectations: [(HistoryRetention, [String])] = [
            (.day, ["0"]),
            (.week, ["0", "2"]),
            (.twoWeeks, ["0", "2", "10"]),
            (.month, ["0", "2", "10", "20"]),
            (.year, ["0", "2", "10", "20", "40"]),
            (.manually, ["0", "2", "10", "20", "40", "400"]),
        ]
        for (retention, kept) in expectations {
            try seed()
            _ = try world.store.trimHistory(retention: retention, now: now, calendar: calendar)
            #expect(try visits(world).map(\.title) == kept, "\(retention)")
        }
        #expect(SettingKeys.historyRetention.defaultValue == .year)
        #expect(HistoryRetention.year.cutoff(now: now, calendar: calendar) != nil)
        #expect(HistoryRetention.manually.cutoff(now: now, calendar: calendar) == nil)
        #expect(HistoryRetention.allCases.map(\.title) == [
            "After one day", "After one week", "After two weeks", "After one month", "After one year", "Manually",
        ])
    }

    /// Launch maintenance trims by the stored setting; the default keeps a year.
    @Test func launchMaintenanceTrimsByTheSetting() throws {
        let world = try makeWorld()
        let now = world.clock.date
        try world.store.recordVisit(profileID: world.profile.id, url: "https://example.com/old", title: "old", at: now.addingTimeInterval(-400 * 86_400))
        try world.store.recordVisit(profileID: world.profile.id, url: "https://example.com/week", title: "week", at: now.addingTimeInterval(-8 * 86_400))
        try world.store.launchMaintenance()
        #expect(try visits(world).map(\.title) == ["week"])
        try world.store.setSetting(SettingKeys.historyRetention, .week)
        try world.store.launchMaintenance()
        #expect(try visits(world).isEmpty)
    }

    @Test func profileDeletionCascades() throws {
        let world = try makeWorld()
        let other = try world.store.createProfile(name: "Work")
        try world.store.recordVisit(profileID: other.id, url: "https://example.com/", title: "Theirs", at: world.clock.date)
        try world.store.recordVisit(profileID: world.profile.id, url: "https://example.org/", title: "Mine", at: world.clock.date)
        _ = try world.store.deleteProfile(other.id)
        #expect(try count(world) == 1)
        #expect(try visits(world).map(\.title) == ["Mine"])
    }

    @Test func deleteVisitsLeavesArchiveAndTabs() throws {
        let world = try makeWorld()
        let open = try world.store.openTab(url: "https://example.com/a", title: "A", workspaceID: world.home.id, origin: .commandBar, containerID: nil, edge: .bottom)
        let closing = try world.store.openTab(url: "https://example.com/b", title: "B", workspaceID: world.home.id, origin: .commandBar, containerID: nil, edge: .bottom)
        _ = try world.store.closeTab(closing.id)
        try world.store.recordVisit(profileID: world.profile.id, url: "https://example.com/a", title: "A", at: world.clock.date)
        try world.store.recordVisit(profileID: world.profile.id, url: "https://example.com/b", title: "B", at: world.clock.date.addingTimeInterval(1))
        let archiveBefore = try world.store.archivedTabs(profileID: world.profile.id)
        let ids = try visits(world).map(\.id)

        #expect(try world.store.deleteVisits(ids: ids + [UUID()]) == 2)
        #expect(try world.store.deleteVisits(ids: []) == 0)

        #expect(try count(world) == 0)
        #expect(try world.store.tabExists(open.id))
        #expect(try world.store.archivedTabs(profileID: world.profile.id) == archiveBefore)
    }

    // MARK: - The History view

    @Test func historyGroupsByDay() throws {
        let calendar = Self.calendar
        let locale = Locale(identifier: "en_US")
        let now = try #require(calendar.date(from: DateComponents(year: 2026, month: 11, day: 14, hour: 10)))
        let profile = UUID()
        func visit(_ title: String, _ hoursAgo: Double) -> HistoryVisit {
            HistoryVisit(profileID: profile, url: "https://example.com/\(title)", title: title, visitedAt: now.addingTimeInterval(-hoursAgo * 3600))
        }
        // 9:00 and 00:30 today; 23:30 yesterday (local, not UTC); 6 days ago.
        let list = [visit("a", 1), visit("b", 9.5), visit("c", 10.5), visit("d", 6 * 24)]
        let sections = HistoryGrouping.byDay(list, now: now, calendar: calendar, locale: locale)
        #expect(sections.map { $0.visits.map(\.title) } == [["a", "b"], ["c"], ["d"]])
        #expect(sections.map(\.heading).prefix(2) == ["Today", "Yesterday"])
        #expect(sections.last?.heading == "Sunday, November 8, 2026")
        #expect(sections.map(\.day) == sections.map { calendar.startOfDay(for: $0.visits[0].visitedAt) })
    }

    @Test func historyBrowserSearchesDeletesAndPages() throws {
        let world = try makeWorld()
        for index in 0..<5 {
            try world.store.recordVisit(profileID: world.profile.id, url: "https://example.com/\(index)", title: "Page \(index)", at: world.clock.date.addingTimeInterval(Double(index)))
        }
        let browser = HistoryBrowser(store: world.store, profileID: world.profile.id, pageSize: 2, now: { world.clock.date }, calendar: Self.calendar, locale: Locale(identifier: "en_US"))
        #expect(browser.visits.map(\.title) == ["Page 4", "Page 3"])
        #expect(browser.canLoadMore)
        browser.loadMore()
        browser.loadMore()
        #expect(browser.visits.count == 5)
        #expect(!browser.canLoadMore)
        browser.query = "page 2"
        #expect(browser.visits.map(\.title) == ["Page 2"])
        browser.query = ""
        browser.selection = Set(browser.visits.prefix(2).map(\.id))
        #expect(browser.deleteSelected() == 2)
        #expect(browser.selection.isEmpty)
        #expect(browser.visits.map(\.title) == ["Page 2", "Page 1"])
        #expect(try count(world) == 3)
        #expect(browser.visitToOpen(clicked: nil) == nil)
        browser.selection = [browser.visits[1].id]
        #expect(browser.visitToOpen(clicked: nil)?.title == "Page 1")
    }

    @Test func historyTextLabels() throws {
        #expect(HistoryText.title == "History")
        #expect(HistoryText.showAllHistory == "Show All History")
        #expect(HistoryText.clearHistoryMenuItem == "Clear History…")
        #expect(HistoryText.clearButton == "Clear History…")
        #expect(HistoryText.delete == "Delete")
        #expect(HistoryText.emptyState(searching: false) == "No history")
        #expect(HistoryText.emptyState(searching: true) == "No matching history")
        let visit = HistoryVisit(profileID: UUID(), url: "https://example.com/a", title: "", visitedAt: Date())
        #expect(HistoryText.rowTitle(visit) == "example.com")
    }

    @Test func privateWindowHasNoHistoryView() {
        #expect(!HistoryText.isShowAllHistoryEnabled(isPrivate: true, busy: false))
        #expect(!HistoryText.isShowAllHistoryEnabled(isPrivate: true, busy: true))
        #expect(!HistoryText.isShowAllHistoryEnabled(isPrivate: false, busy: true))
        #expect(HistoryText.isShowAllHistoryEnabled(isPrivate: false, busy: false))
    }

    @Test func selectingATabLeavesHistory() throws {
        let world = try makeWorld()
        let first = try world.store.openTab(url: "https://example.com/1", title: "1", workspaceID: world.home.id, origin: .commandBar, containerID: nil, edge: .bottom)
        let second = try world.store.openTab(url: "https://example.com/2", title: "2", workspaceID: world.home.id, origin: .commandBar, containerID: nil, edge: .bottom)
        let work = try world.store.createWorkspace(profileID: world.profile.id, name: "Work", icon: "briefcase", colorHex: "#FFFFFF")
        let model = try BrowserWindowModel(
            store: world.store, revision: StoreRevision(), livePages: LivePageRegistry(),
            state: WindowState(profileID: world.profile.id, workspaceID: world.home.id, selectedTabID: first.id, frame: "", sortIndex: 0)
        )
        #expect(!model.isShowingHistory)
        model.toggleHistory()
        #expect(model.isShowingHistory)
        model.toggleHistory()
        #expect(!model.isShowingHistory)

        model.showHistory()
        model.select(first.id) // the tab already selected still leaves the view, as clicking it does in Safari
        #expect(!model.isShowingHistory)
        model.showHistory()
        model.select(second.id)
        #expect(!model.isShowingHistory)
        model.showHistory()
        model.switchWorkspace(to: work.id)
        #expect(!model.isShowingHistory)
        model.showHistory()
        model.openTab(url: "")
        #expect(!model.isShowingHistory)
        model.showHistory()
        _ = model.perform(.open(url: "https://example.net/"), mode: .currentTab, target: nil)
        #expect(!model.isShowingHistory)
        // An action that isn't a page (compact mode) leaves it showing.
        model.showHistory()
        _ = model.perform(.action(.toggleCompactMode), mode: .newTab, target: nil)
        #expect(model.isShowingHistory)
        let visit = HistoryVisit(profileID: world.profile.id, url: "https://example.org/v", title: "V", visitedAt: world.clock.date)
        model.openVisit(visit)
        #expect(!model.isShowingHistory)
        #expect(model.selectedTab?.url == "https://example.org/v")
    }

    @Test func pageCommandsOffOverHistory() {
        let status = PageStatusSummary(isLoading: true, canGoBack: true, canGoForward: true, hasPage: true, blockingOn: true)
        #expect(PageMenuState.from(status: status, sheetOpen: false, historyShown: true) == .disabled)
        #expect(PageMenuState.from(status: status, sheetOpen: false, historyShown: false) != .disabled)
    }

    @Test func clearHistoryFromTheWindowRefreshesTheView() async throws {
        let world = try makeWorld()
        try world.store.recordVisit(profileID: world.profile.id, url: "https://example.com/", title: "A", at: world.clock.date)
        let model = try BrowserWindowModel(
            store: world.store, revision: StoreRevision(), livePages: LivePageRegistry(),
            state: WindowState(profileID: world.profile.id, workspaceID: world.home.id, frame: "", sortIndex: 0)
        )
        model.showHistory()
        #expect(model.history?.visits.count == 1)
        await model.clearHistory(.all, alsoWebsiteData: false)
        #expect(model.history?.visits.isEmpty == true)
        #expect(try count(world) == 0)
    }

    // MARK: - Backups

    @Test func backupLeavesOutHistory() async throws {
        let world = try makeWorld()
        try world.store.recordVisit(profileID: world.profile.id, url: "https://example.com/", title: "A", at: world.clock.date)
        #expect(BackupPolicy.excludedTables.contains("historyVisit"))
        let folder = world.file.deletingLastPathComponent().appendingPathComponent(BackupPolicy.folderName, isDirectory: true)
        let url = try DatabaseBackups.copy(
            from: world.database.writer, to: folder, kind: .regular, excludedTables: BackupPolicy.excludedTables, now: world.clock.date
        )
        var readOnly = Configuration()
        readOnly.readonly = true
        let queue = try DatabaseQueue(path: url.path, configuration: readOnly)
        let (exists, rows, profiles) = try await queue.read { db in
            (try db.tableExists("historyVisit"), try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM historyVisit"), try Profile.fetchCount(db))
        }
        try queue.close()
        #expect(exists)
        #expect(rows == 0)
        #expect(profiles == 1)
        #expect(try count(world) == 1) // the live database keeps its history
    }
}
