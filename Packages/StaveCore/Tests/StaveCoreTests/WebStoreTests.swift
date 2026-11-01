import Foundation
import GRDB
import Testing
@testable import StaveCore

struct WebStoreTests {
    @Test func siteDecisionRoundTrips() throws {
        let (store, _, _) = try makeTempStore()
        let p = try store.createProfile(name: "P")
        let q = try store.createProfile(name: "Q")
        try store.setSiteDecision(profileID: p.id, host: "example.com", key: .camera, .allow)
        #expect(try store.siteDecision(profileID: p.id, host: "example.com", key: .camera) == .allow)
        #expect(try store.siteDecision(profileID: q.id, host: "example.com", key: .camera) == nil)
        #expect(try store.siteDecision(profileID: p.id, host: "example.com", key: .microphone) == nil)
        try store.setSiteDecision(profileID: p.id, host: "example.com", key: .camera, .deny)
        #expect(try store.siteDecision(profileID: p.id, host: "example.com", key: .camera) == .deny)
        try store.setSiteDecision(profileID: p.id, host: "example.com", key: .camera, nil)
        #expect(try store.siteDecision(profileID: p.id, host: "example.com", key: .camera) == nil)
    }

    @Test func siteDecisionsFollowProfileDeletionAndMissingProfile() throws {
        let (store, database, _) = try makeTempStore()
        let p = try store.createProfile(name: "P")
        try store.setSiteDecision(profileID: p.id, host: "example.org", key: .contentBlocking, .deny)
        try database.writer.write { db in _ = try Profile.deleteOne(db, key: p.id) }
        #expect(try database.writer.read { db in try SiteSetting.fetchCount(db) } == 0)
        #expect(throws: StoreError.notFound) {
            try store.setSiteDecision(profileID: UUID(), host: "example.org", key: .camera, .allow)
        }
    }

    @Test func hostsNormalize() {
        #expect(SiteHost.normalized("https://WWW.Example.com:8443/x") == "example.com")
        #expect(SiteHost.normalized("http://user@Example.NET/p?q#f") == "example.net")
        #expect(SiteHost.normalized("EXAMPLE.org") == "example.org")
        #expect(SiteHost.normalized("www.example.org:8080") == "example.org")
        #expect(SiteHost.normalized("file:///x") == nil)
        #expect(SiteHost.normalized("mailto:a@example.com") == nil)
        #expect(SiteHost.normalized("about:blank") == nil)
        #expect(SiteHost.normalized("https:///x") == nil)
        #expect(SiteHost.normalized("") == nil)
    }

    @Test func interactionStateOnlyTouchesState() throws {
        let clock = TestClock()
        let (store, _, _) = try makeTempStore(now: clock.now)
        let profile = try store.createProfile(name: "P")
        let workspace = try #require(try store.workspaces(profileID: profile.id).first)
        let tab = try store.openTab(url: "https://example.com", title: "T", workspaceID: workspace.id, origin: .commandBar, containerID: nil, edge: .top)
        try store.updateNavigation(tabID: tab.id, url: "https://example.com/a", title: "A", faviconURL: "https://example.com/f.ico", interactionState: nil)
        clock.advance(by: 10)
        try store.updateInteractionState(tabID: tab.id, Data([1, 2]))
        let after = try #require(try store.regularTabs(workspaceID: workspace.id).first)
        #expect(after.url == "https://example.com/a")
        #expect(after.title == "A")
        #expect(after.faviconURL == "https://example.com/f.ico")
        #expect(after.interactionState == Data([1, 2]))
        #expect(after.modifiedAt == clock.date)

        _ = try store.closeTab(tab.id)
        #expect(throws: StoreError.notFound) { try store.updateInteractionState(tabID: tab.id, Data([3])) }
        #expect(try store.tabExists(tab.id) == false)
    }

    @Test func dataStoreFollowsContainer() throws {
        let (store, _, _) = try makeTempStore()
        let profile = try store.createProfile(name: "P")
        let workspace = try #require(try store.workspaces(profileID: profile.id).first)
        let container = try store.createContainer(profileID: profile.id, name: "C", colorHex: "#000000")
        let plain = try store.openTab(url: "https://example.com", title: "a", workspaceID: workspace.id, origin: .commandBar, containerID: nil, edge: .top)
        let contained = try store.openTab(url: "https://example.org", title: "b", workspaceID: workspace.id, origin: .commandBar, containerID: container.id, edge: .top)
        let essential = try store.openTab(url: "https://example.net", title: "c", workspaceID: workspace.id, origin: .commandBar, containerID: nil, edge: .top)
        try store.makeEssential(essential.id)
        #expect(try store.dataStoreID(forTab: plain.id) == profile.dataStoreID)
        #expect(try store.dataStoreID(forTab: contained.id) == container.dataStoreID)
        #expect(container.dataStoreID != profile.dataStoreID)
        #expect(try store.dataStoreID(forTab: essential.id) == profile.dataStoreID)
        #expect(throws: StoreError.notFound) { try store.dataStoreID(forTab: UUID()) }
    }

    @Test func latePinnedFaviconAdopted() throws {
        let (store, database, _) = try makeTempStore()
        let profile = try store.createProfile(name: "P")
        let workspace = try #require(try store.workspaces(profileID: profile.id).first)
        let tab = try store.openTab(url: "https://example.com", title: "T", workspaceID: workspace.id, origin: .commandBar, containerID: nil, edge: .top)
        try store.pinTab(tab.id, folderID: nil)
        func pinnedFavicon() throws -> String? {
            try database.writer.read { db in try Tab.fetchOne(db, key: tab.id)?.pinnedFaviconURL }
        }
        #expect(try pinnedFavicon() == nil)
        // No icon yet: nothing to adopt.
        try store.updateNavigation(tabID: tab.id, url: "https://example.com", title: "T", faviconURL: nil, interactionState: nil)
        #expect(try pinnedFavicon() == nil)
        // Drifted: not adopted.
        try store.updateNavigation(tabID: tab.id, url: "https://example.com/other", title: "O", faviconURL: "https://example.com/drift.ico", interactionState: nil)
        #expect(try pinnedFavicon() == nil)
        try store.updateNavigation(tabID: tab.id, url: "https://example.com", title: "T", faviconURL: "https://example.com/f.ico", interactionState: nil)
        #expect(try pinnedFavicon() == "https://example.com/f.ico")
        try store.updateNavigation(tabID: tab.id, url: "https://example.com", title: "T", faviconURL: "https://example.com/g.ico", interactionState: nil)
        #expect(try pinnedFavicon() == "https://example.com/f.ico")
    }

    @Test func regularTabNeverGainsPinnedFavicon() throws {
        let (store, database, _) = try makeTempStore()
        let profile = try store.createProfile(name: "P")
        let workspace = try #require(try store.workspaces(profileID: profile.id).first)
        let tab = try store.openTab(url: "https://example.com", title: "T", workspaceID: workspace.id, origin: .commandBar, containerID: nil, edge: .top)
        try store.updateNavigation(tabID: tab.id, url: "https://example.com", title: "T", faviconURL: "https://example.com/f.ico", interactionState: nil)
        let stored = try database.writer.read { db in try Tab.fetchOne(db, key: tab.id) }
        #expect(stored?.pinnedFaviconURL == nil)
    }

    @Test func migrationAddsSiteSetting() throws {
        let (database, file) = try makeTempDatabase()
        try database.close()
        // A file migrated only to v3, then opened by the full migrator.
        let folder = file.deletingLastPathComponent().appendingPathComponent("v3", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let v3File = folder.appendingPathComponent(StavePaths.databaseFileName)
        var migrator = StaveDatabase.makeMigrator()
        let queue = try DatabaseQueue(path: v3File.path)
        try migrator.migrate(queue, upTo: "v3")
        try queue.close()
        migrator = StaveDatabase.makeMigrator()
        let reopened = try StaveDatabase.open(at: v3File)
        let tables = try reopened.writer.read { db in
            try String.fetchAll(db, sql: "SELECT name FROM sqlite_master WHERE type = 'table'")
        }
        #expect(tables.contains("siteSetting"))
    }
}
