import Foundation
import Testing
@testable import StaveCore

struct SidebarRowsTests {
    private func home() throws -> (OrganizationStore, SidebarSnapshot, [Container]) {
        let (store, _, _) = try makeTempStore()
        try SampleOrganization.seed(into: store)
        let profile = try #require(try store.profiles().first)
        let homeWorkspace = try #require(try store.workspaces(profileID: profile.id).first)
        let snapshot = try store.sidebarSnapshot(workspaceID: homeWorkspace.id)
        return (store, snapshot, try store.containers(profileID: profile.id))
    }

    private func tab(url: String = "", title: String = "") -> Tab {
        Tab(slotID: UUID(), url: url, title: title)
    }

    @Test func untitledAddresslessTabReadsNewTab() throws {
        let (_, snapshot, containers) = try home()
        var blank = snapshot
        blank.regular = [tab()]
        blank.pinned = [.tab(tab())]
        let rows = SidebarRows.build(blank, containers: containers)
        #expect(rows.map(\.title) == ["New Tab", "New Tab"])
        #expect(rows.map(\.accessibilityLabel) == ["New Tab, pinned tab", "New Tab, tab"])
    }

    @Test func rowsInVisualOrder() throws {
        let (_, snapshot, containers) = try home()
        let rows = SidebarRows.build(snapshot, containers: containers)
        try #require(rows.count == 12)
        let longTitle = rows[9].title
        #expect(longTitle.hasPrefix("Long title ") && longTitle.count == 200)
        #expect(rows.map(\.title) == [
            "Reading", "Later", "Saved essay", "日本の天気予報", "Morning headlines", "Post 42",
            "Reference docs", "Project board",
            "Weeknight recipes", longTitle, "Shopping cart", "Shared files",
        ])
        #expect(rows.map(\.depth) == [0, 1, 2, 2, 1, 1, 0, 0, 0, 0, 0, 0])
        let reading = rows[0], later = rows[1]
        guard case .folder(let readingID) = reading.id, case .folder(let laterID) = later.id else { Issue.record("not folders"); return }
        #expect(reading.parentFolderID == nil)
        #expect(later.parentFolderID == readingID)
        #expect(rows[2].parentFolderID == laterID && rows[3].parentFolderID == laterID)
        #expect(rows[4].parentFolderID == readingID && rows[5].parentFolderID == readingID)
        #expect(rows[6].parentFolderID == nil)
        #expect(rows[5].kind == .pinnedTab(drifted: true))
        #expect(rows[4].kind == .pinnedTab(drifted: false))
        #expect(rows[8].kind == .regularTab)
        let work = try #require(containers.first)
        #expect(rows[11].containerColorHex == work.colorHex)
        #expect(rows[11].accessibilityLabel == "Shared files, tab, in Work Google")
        #expect(rows[8].containerColorHex == nil)
        #expect(rows[5].accessibilityLabel == "Post 42, pinned tab, away from its pinned page")
        #expect(rows[1].accessibilityLabel == "Later, folder, open, 2 items")
    }

    @Test func closedFolderHidesChildren() throws {
        let (store, snapshot, containers) = try home()
        guard case .folder(let reading, _) = try #require(snapshot.pinned.first) else { Issue.record("not a folder"); return }
        try store.setFolderOpen(reading.id, false)
        let closed = try store.sidebarSnapshot(workspaceID: snapshot.workspace.id)
        let rows = SidebarRows.build(closed, containers: containers)
        try #require(rows.count == 7)
        #expect(!rows.map(\.title).contains("Later"))
        #expect(!rows.map(\.title).contains("Morning headlines"))
        #expect(rows[0].kind == .folder(isOpen: false, childCount: 3))
        #expect(rows[0].accessibilityLabel == "Reading, folder, closed, 3 items")
    }

    @Test func labelsAreExact() {
        #expect(SidebarLabels.essential(title: "Mail") == "Mail, Essential")
        #expect(SidebarLabels.pinnedTab(title: "Docs", drifted: false) == "Docs, pinned tab")
        #expect(SidebarLabels.pinnedTab(title: "Docs", drifted: true) == "Docs, pinned tab, away from its pinned page")
        #expect(SidebarLabels.folder(title: "Reading", isOpen: true, childCount: 1) == "Reading, folder, open, 1 item")
        #expect(SidebarLabels.folder(title: "Reading", isOpen: false, childCount: 0) == "Reading, folder, closed, 0 items")
        #expect(SidebarLabels.folder(title: "Reading", isOpen: true, childCount: 3) == "Reading, folder, open, 3 items")
        #expect(SidebarLabels.regularTab(title: "Cart", containerName: nil) == "Cart, tab")
        #expect(SidebarLabels.regularTab(title: "Cart", containerName: "Work") == "Cart, tab, in Work")
        #expect(SidebarLabels.workspace(name: "Home", position: 1, count: 2, isCurrent: false) == "Home, workspace 1 of 2")
        #expect(SidebarLabels.workspace(name: "Work", position: 2, count: 2, isCurrent: true) == "Work, workspace 2 of 2, current")
    }

    @Test func driftRule() {
        var pinned = tab(url: "https://example.com/a")
        #expect(!pinned.isDrifted)
        pinned.pinnedURL = "https://example.com/a"
        #expect(!pinned.isDrifted)
        pinned.url = "https://example.com/b"
        #expect(pinned.isDrifted)
    }

    @Test func addressText() {
        #expect(DisplayText.address(for: "https://www.example.com/a") == "example.com")
        #expect(DisplayText.address(for: "https://sub.example.org") == "sub.example.org")
        #expect(DisplayText.address(for: "about:blank") == "about:blank")
        #expect(DisplayText.address(for: "") == "")
    }

    @Test func titleRule() {
        #expect(DisplayText.title(for: tab(url: "https://www.example.com/x", title: "Hi")) == "Hi")
        #expect(DisplayText.title(for: tab(url: "https://www.example.com/x")) == "www.example.com")
        #expect(DisplayText.title(for: tab(url: "about:blank")) == "about:blank")
        #expect(DisplayText.title(for: tab()) == "New Tab")
        #expect(DisplayText.title(title: "", url: "") == "New Tab")
    }

    @Test func monogram() {
        #expect(DisplayText.monogram(for: tab(url: "https://www.example.com")) == "E")
        #expect(DisplayText.monogram(for: tab(url: "", title: "zeta")) == "Z")
        #expect(DisplayText.monogram(for: tab()) == "?")
    }

    @Test func workspaceIcon() {
        #expect(WorkspaceIcon(stored: "💼") == .emoji("💼"))
        #expect(WorkspaceIcon(stored: "house") == .symbol("house"))
        #expect(WorkspaceIcon(stored: "") == .symbol("square.grid.2x2"))
    }
}
