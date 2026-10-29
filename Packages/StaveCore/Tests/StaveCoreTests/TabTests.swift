import Foundation
import GRDB
import Testing
@testable import StaveCore

struct TabTests {
    private func fixture() throws -> (OrganizationStore, StaveDatabase, TestClock, Profile, Workspace) {
        let clock = TestClock()
        let (store, database, _) = try makeTempStore(now: clock.now)
        let profile = try store.createProfile(name: "P")
        let workspace = try #require(try store.workspaces(profileID: profile.id).first)
        return (store, database, clock, profile, workspace)
    }

    private func open(_ store: OrganizationStore, _ url: String, in workspace: Workspace,
                      origin: NewTabOrigin = .commandBar, edge: NewTabEdge = .bottom) throws -> Tab {
        try store.openTab(url: url, title: url, workspaceID: workspace.id, origin: origin, containerID: nil, edge: edge)
    }

    @Test func openPlacesByOrigin() throws {
        let (store, _, _, _, ws) = try fixture()
        let a = try open(store, "https://a.example", in: ws)
        let b = try open(store, "https://b.example", in: ws, edge: .bottom)
        let top = try open(store, "https://top.example", in: ws, origin: .commandBar, edge: .top)
        let child = try open(store, "https://child.example", in: ws, origin: .link(openerTabID: a.id))
        #expect(try store.regularTabs(workspaceID: ws.id).map(\.id) == [top.id, a.id, child.id, b.id])
    }

    @Test func openOnUnknownWorkspaceThrowsNotFound() throws {
        let (store, _, _, _, _) = try fixture()
        #expect(throws: StoreError.notFound) {
            try store.openTab(url: "https://x", title: "x", workspaceID: UUID(), origin: .commandBar, containerID: nil, edge: .top)
        }
    }

    @Test func closeRegularArchives() throws {
        let (store, database, clock, profile, ws) = try fixture()
        let tab = try open(store, "https://a.example", in: ws)
        let state = Data([1, 2, 3])
        try store.updateNavigation(tabID: tab.id, url: "https://a.example/next", title: "Next", faviconURL: nil, interactionState: state)
        clock.advance(by: 10)
        let result = try store.closeTab(tab.id)
        guard case .archived(let archiveID) = result else { Issue.record("expected archived"); return }
        #expect(try store.regularTabs(workspaceID: ws.id).isEmpty)
        let archived = try #require(try store.archivedTabs(profileID: profile.id).first)
        #expect(archived.id == archiveID)
        #expect(archived.url == "https://a.example/next")
        #expect(archived.title == "Next")
        #expect(archived.interactionState == state)
        #expect(archived.closedAt == clock.date)
        let slots = try database.writer.read { db in try Slot.fetchCount(db) }
        #expect(slots == 0)
    }

    @Test func closeUnknownThrowsNotFound() throws {
        let (store, _, _, _, _) = try fixture()
        #expect(throws: StoreError.notFound) { try store.closeTab(UUID()) }
        #expect(throws: StoreError.notFound) { try store.markActive(tabID: UUID()) }
    }

    @Test func restoreFromArchive() throws {
        let (store, _, _, profile, ws) = try fixture()
        let first = try open(store, "https://first.example", in: ws)
        let state = Data([9, 8])
        try store.updateNavigation(tabID: first.id, url: first.url, title: "First", faviconURL: nil, interactionState: state)
        guard case .archived(let id) = try store.closeTab(first.id) else { Issue.record("expected archived"); return }
        let other = try open(store, "https://other.example", in: ws)
        let restored = try store.restoreArchivedTab(id, workspaceID: ws.id)
        #expect(try store.regularTabs(workspaceID: ws.id).map(\.id) == [restored.id, other.id])
        #expect(restored.interactionState == state)
        #expect(restored.url == "https://first.example")
        #expect(try store.archivedTabs(profileID: profile.id).isEmpty)
        #expect(throws: StoreError.notFound) { try store.restoreArchivedTab(id, workspaceID: ws.id) }
    }

    @Test func restoreKeepsContainer() throws {
        let (store, database, clock, profile, ws) = try fixture()
        let container = Container(profileID: profile.id, name: "C", colorHex: "#000000", modifiedAt: clock.date)
        try database.writer.write { db in try container.insert(db) }
        let tab = try store.openTab(url: "https://c.example", title: "c", workspaceID: ws.id, origin: .commandBar, containerID: container.id, edge: .top)
        guard case .archived(let id) = try store.closeTab(tab.id) else { Issue.record("expected archived"); return }
        #expect(try store.archivedTabs(profileID: profile.id).first?.containerID == container.id)
        #expect(try store.restoreArchivedTab(id, workspaceID: ws.id).containerID == container.id)
    }

    @Test func trimRemovesOnlyOld() throws {
        let (store, database, clock, profile, _) = try fixture()
        let day: TimeInterval = 86_400
        let old = ArchivedTab(profileID: profile.id, url: "https://old", title: "old", closedAt: clock.date.addingTimeInterval(-31 * day), modifiedAt: clock.date)
        let recent = ArchivedTab(profileID: profile.id, url: "https://recent", title: "recent", closedAt: clock.date.addingTimeInterval(-29 * day), modifiedAt: clock.date)
        try database.writer.write { db in try old.insert(db); try recent.insert(db) }
        #expect(try store.trimArchive() == 1)
        #expect(try store.archivedTabs(profileID: profile.id).map(\.id) == [recent.id])
    }

    @Test func updateAfterCloseThrowsNotFound() throws {
        let (store, _, _, _, ws) = try fixture()
        let tab = try open(store, "https://a.example", in: ws)
        _ = try store.closeTab(tab.id)
        #expect(throws: StoreError.notFound) {
            try store.updateNavigation(tabID: tab.id, url: "https://z", title: "z", faviconURL: nil, interactionState: nil)
        }
        #expect(throws: StoreError.notFound) { try store.markActive(tabID: tab.id) }
        #expect(try store.regularTabs(workspaceID: ws.id).isEmpty)
    }

    @Test func titlesStoredUnchanged() throws {
        let (store, _, _, _, ws) = try fixture()
        let titles = ["", String(repeating: "a", count: 5_000), "日本語のタイトル 🎵"]
        for title in titles {
            let tab = try store.openTab(url: "https://example.com/x", title: title, workspaceID: ws.id, origin: .commandBar, containerID: nil, edge: .bottom)
            #expect(tab.title == title)
        }
        #expect(try store.regularTabs(workspaceID: ws.id).map(\.title) == titles)
        let blank = try #require(try store.regularTabs(workspaceID: ws.id).first)
        #expect(store.displayTitle(for: blank) == "example.com")
        let noHost = Tab(slotID: UUID(), url: "not a url", title: "")
        #expect(store.displayTitle(for: noHost) == "not a url")
    }

    @Test func renormalizesWhenCrowded() throws {
        let (store, _, _, _, ws) = try fixture()
        let opener = try open(store, "https://opener.example", in: ws)
        _ = try open(store, "https://tail.example", in: ws)
        var expected: [UUID] = []
        for i in 0..<60 {
            expected.insert(try open(store, "https://c\(i).example", in: ws, origin: .link(openerTabID: opener.id)).id, at: 0)
        }
        // Each link opens directly below the opener, so later ones sit above earlier ones.
        let tabs = try store.regularTabs(workspaceID: ws.id)
        #expect(tabs.map(\.id) == [opener.id] + expected + [tabs.last!.id])
        #expect(tabs.count == 62)
    }

    @Test func renormalizedIndicesAreDistinct() throws {
        let (store, database, _, _, ws) = try fixture()
        let opener = try open(store, "https://opener.example", in: ws)
        _ = try open(store, "https://tail.example", in: ws)
        for i in 0..<60 { _ = try open(store, "https://c\(i).example", in: ws, origin: .link(openerTabID: opener.id)) }
        let indices = try database.writer.read { db in
            try Double.fetchAll(db, Slot.filter(Column("workspaceID") == ws.id).select(Column("sortIndex")))
        }
        #expect(Set(indices).count == 62)
    }
}
