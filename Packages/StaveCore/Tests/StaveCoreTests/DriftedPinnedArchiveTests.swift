import Foundation
import Testing
@testable import StaveCore

/// Making a drifted pinned tab or Essential regular clears its pinned page, so the page goes to the archive first.
struct DriftedPinnedArchiveTests {
    private func fixture() throws -> (OrganizationStore, Profile, Workspace) {
        let (store, _, _) = try makeTempStore(now: TestClock().now)
        let profile = try store.createProfile(name: "P")
        let workspace = try #require(try store.workspaces(profileID: profile.id).first)
        return (store, profile, workspace)
    }

    private func pinned(_ store: OrganizationStore, _ workspace: Workspace, drifted: Bool) throws -> Tab {
        let tab = try store.openTab(url: "https://example.com/pinned", title: "Pinned page", workspaceID: workspace.id, origin: .commandBar, containerID: nil, edge: .bottom)
        try store.pinTab(tab.id, folderID: nil)
        if drifted {
            try store.updateNavigation(tabID: tab.id, url: "https://example.com/elsewhere", title: "Elsewhere", faviconURL: nil, interactionState: nil)
        }
        return tab
    }

    @Test func driftedPinnedMovedToRegularArchivesThePinnedPage() throws {
        let (store, profile, ws) = try fixture()
        let tab = try pinned(store, ws, drifted: true)
        try store.moveTab(tab.id, toWorkspace: ws.id, section: .regular, folderID: nil, after: nil)
        let archived = try store.archivedTabs(profileID: profile.id)
        #expect(archived.count == 1)
        #expect(archived.first?.url == "https://example.com/pinned")
        #expect(archived.first?.title == "Pinned page")
        #expect(archived.first?.workspaceID == ws.id)
        #expect(try store.regularTabs(workspaceID: ws.id).map(\.id) == [tab.id]) // the tab itself still moved
    }

    @Test func nonDriftedPinnedMovedToRegularArchivesNothing() throws {
        let (store, profile, ws) = try fixture()
        let tab = try pinned(store, ws, drifted: false)
        try store.moveTab(tab.id, toWorkspace: ws.id, section: .regular, folderID: nil, after: nil)
        #expect(try store.archivedTabs(profileID: profile.id).isEmpty)
    }

    @Test func driftedEssentialMovedToRegularArchivesThePinnedPage() throws {
        let (store, profile, ws) = try fixture()
        let tab = try pinned(store, ws, drifted: true)
        try store.makeEssential(tab.id)
        try store.moveTab(tab.id, toWorkspace: ws.id, section: .regular, folderID: nil, after: nil)
        #expect(try store.archivedTabs(profileID: profile.id).map(\.url) == ["https://example.com/pinned"])
    }

    @Test func movingBetweenPinnedAndEssentialsArchivesNothing() throws {
        let (store, profile, ws) = try fixture()
        let tab = try pinned(store, ws, drifted: true)
        try store.moveTab(tab.id, toWorkspace: nil, section: .essential, folderID: nil, after: nil)
        try store.moveTab(tab.id, toWorkspace: ws.id, section: .pinned, folderID: nil, after: nil)
        #expect(try store.archivedTabs(profileID: profile.id).isEmpty)
    }

    @Test func unpinningADriftedTabArchivesThePinnedPage() throws {
        let (store, profile, ws) = try fixture()
        let tab = try pinned(store, ws, drifted: true)
        try store.unpinTab(tab.id)
        #expect(try store.archivedTabs(profileID: profile.id).map(\.url) == ["https://example.com/pinned"])
    }

    @Test func unpinningANonDriftedTabArchivesNothing() throws {
        let (store, profile, ws) = try fixture()
        let tab = try pinned(store, ws, drifted: false)
        try store.unpinTab(tab.id)
        #expect(try store.archivedTabs(profileID: profile.id).isEmpty)
    }
}
