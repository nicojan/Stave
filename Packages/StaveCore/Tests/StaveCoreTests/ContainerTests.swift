import Foundation
import GRDB
import Testing
@testable import StaveCore

struct ContainerTests {
    private let day: TimeInterval = 86_400

    private func fixture() throws -> (OrganizationStore, StaveDatabase, TestClock, Profile, Workspace) {
        let clock = TestClock()
        let (store, database, _) = try makeTempStore(now: clock.now)
        let profile = try store.createProfile(name: "P")
        let workspace = try #require(try store.workspaces(profileID: profile.id).first)
        return (store, database, clock, profile, workspace)
    }

    private func open(_ store: OrganizationStore, _ workspace: Workspace, container: UUID?) throws -> Tab {
        try store.openTab(url: "https://a.example", title: "a", workspaceID: workspace.id, origin: .commandBar, containerID: container, edge: .bottom)
    }

    private func count<R: TableRecord>(_ type: R.Type, _ database: StaveDatabase) throws -> Int {
        try database.writer.read { db in try type.fetchCount(db) }
    }

    @Test func createStampsFieldsAndDistinctDataStore() throws {
        let (store, _, clock, profile, _) = try fixture()
        clock.advance(by: 10)
        let c = try store.createContainer(profileID: profile.id, name: "Work", colorHex: "#FF0000")
        #expect(c.profileID == profile.id)
        #expect(c.name == "Work")
        #expect(c.colorHex == "#FF0000")
        #expect(c.dataStoreID != c.id)
        #expect(c.modifiedAt == clock.date)
        let stored = try #require(try store.containers(profileID: profile.id).first)
        #expect(stored.id == c.id && stored.dataStoreID == c.dataStoreID && stored.name == "Work" && stored.colorHex == "#FF0000")
        #expect(abs(stored.modifiedAt.timeIntervalSince(clock.date)) < 0.001)
    }

    @Test func createOnUnknownProfileThrowsNotFound() throws {
        let (store, _, _, _, _) = try fixture()
        #expect(throws: StoreError.notFound) { try store.createContainer(profileID: UUID(), name: "X", colorHex: "#000000") }
    }

    @Test func listIsOrderedByNameThenCreationAndScopedToProfile() throws {
        let (store, _, _, profile, _) = try fixture()
        let other = try store.createProfile(name: "Other")
        let b = try store.createContainer(profileID: profile.id, name: "B", colorHex: "#111111")
        let a1 = try store.createContainer(profileID: profile.id, name: "A", colorHex: "#222222")
        let a2 = try store.createContainer(profileID: profile.id, name: "A", colorHex: "#333333")
        _ = try store.createContainer(profileID: other.id, name: "Z", colorHex: "#444444")
        #expect(try store.containers(profileID: profile.id).map(\.id) == [a1.id, a2.id, b.id])
    }

    @Test func containerTabsCarryContainer() throws {
        let (store, _, _, profile, ws) = try fixture()
        let c = try store.createContainer(profileID: profile.id, name: "Work", colorHex: "#FF0000")
        let tab = try open(store, ws, container: c.id)
        #expect(tab.containerID == c.id)
        #expect(try store.regularTabs(workspaceID: ws.id).first?.containerID == c.id)
    }

    @Test func deleteUnusedReturnsDataStoreAndRemovesRow() throws {
        let (store, _, _, profile, _) = try fixture()
        let keep = try store.createContainer(profileID: profile.id, name: "Keep", colorHex: "#111111")
        let c = try store.createContainer(profileID: profile.id, name: "Work", colorHex: "#FF0000")
        #expect(try store.deleteContainer(c.id) == c.dataStoreID)
        #expect(try store.containers(profileID: profile.id).map(\.id) == [keep.id])
    }

    @Test func deleteUnknownThrowsNotFound() throws {
        let (store, _, _, _, _) = try fixture()
        #expect(throws: StoreError.notFound) { try store.deleteContainer(UUID()) }
    }

    @Test func deleteInUseRefused() throws {
        let (store, database, clock, profile, ws) = try fixture()
        let c = try store.createContainer(profileID: profile.id, name: "Work", colorHex: "#FF0000")
        let tab = try open(store, ws, container: c.id)

        // Open tab references it.
        #expect(throws: StoreError.containerInUse) { try store.deleteContainer(c.id) }
        #expect(try store.containers(profileID: profile.id).count == 1)
        #expect(try count(Tab.self, database) == 1)

        // Closed: only the archived tab references it (R12).
        _ = try store.closeTab(tab.id)
        #expect(try count(Tab.self, database) == 0)
        #expect(throws: StoreError.containerInUse) { try store.deleteContainer(c.id) }
        #expect(try store.containers(profileID: profile.id).count == 1)
        #expect(try store.archivedTabs(profileID: profile.id).count == 1)

        // Archive trimmed after 30 days: deletion goes through.
        clock.advance(by: 31 * day)
        #expect(try store.trimArchive() == 1)
        #expect(try store.deleteContainer(c.id) == c.dataStoreID)
        #expect(try store.containers(profileID: profile.id).isEmpty)
    }

    @Test func deleteRefusedWhenEssentialTabUsesContainer() throws {
        let (store, database, _, profile, _) = try fixture()
        let c = try store.createContainer(profileID: profile.id, name: "Work", colorHex: "#FF0000")
        try database.writer.write { db in
            let slot = Slot(profileID: profile.id, workspaceID: nil, section: .essential, kind: .tab, sortIndex: 0)
            try slot.insert(db)
            try Tab(slotID: slot.id, containerID: c.id, pinnedURL: "https://e", pinnedTitle: "e", url: "https://e", title: "e").insert(db)
        }
        #expect(throws: StoreError.containerInUse) { try store.deleteContainer(c.id) }
        #expect(try store.containers(profileID: profile.id).count == 1)
    }

    @Test func deleteProfileReturnsAllStores() throws {
        let (store, database, _, profile, ws) = try fixture()
        let c1 = try store.createContainer(profileID: profile.id, name: "A", colorHex: "#111111")
        let c2 = try store.createContainer(profileID: profile.id, name: "B", colorHex: "#222222")
        let doomed = try open(store, ws, container: c1.id)
        _ = try open(store, ws, container: nil)
        _ = try store.closeTab(doomed.id)
        try database.writer.write { db in
            try WindowState(profileID: profile.id, workspaceID: ws.id, frame: "0,0,1,1", sortIndex: 0).insert(db)
        }

        let other = try store.createProfile(name: "Other")
        let otherWS = try #require(try store.workspaces(profileID: other.id).first)
        let otherContainer = try store.createContainer(profileID: other.id, name: "Keep", colorHex: "#333333")
        let otherTab = try open(store, otherWS, container: otherContainer.id)

        let ids = try store.deleteProfile(profile.id)
        #expect(ids.count == 3)
        #expect(ids.first == profile.dataStoreID)
        #expect(Set(ids) == [profile.dataStoreID, c1.dataStoreID, c2.dataStoreID])

        #expect(try store.profiles().map(\.id) == [other.id])
        let theirs = Column("profileID") == profile.id
        let remaining = try database.writer.read { db in
            (workspaces: try Workspace.filter(theirs).fetchCount(db),
             slots: try Slot.filter(theirs).fetchCount(db),
             containers: try Container.filter(theirs).fetchCount(db),
             archived: try ArchivedTab.filter(theirs).fetchCount(db),
             windows: try WindowState.filter(theirs).fetchCount(db),
             tabs: try Tab.fetchCount(db))
        }
        #expect(remaining.workspaces == 0 && remaining.slots == 0 && remaining.containers == 0)
        #expect(remaining.archived == 0 && remaining.windows == 0)
        #expect(remaining.tabs == 1) // only the other profile's tab survives
        // The other profile is untouched.
        #expect(try store.workspaces(profileID: other.id).map(\.id) == [otherWS.id])
        #expect(try store.regularTabs(workspaceID: otherWS.id).map(\.id) == [otherTab.id])
        #expect(try store.containers(profileID: other.id).map(\.id) == [otherContainer.id])
    }

    @Test func deleteProfileWithContainerInUseByOpenTabSucceeds() throws {
        let (store, database, _, profile, ws) = try fixture()
        _ = try store.createProfile(name: "Other")
        let c = try store.createContainer(profileID: profile.id, name: "Work", colorHex: "#FF0000")
        _ = try open(store, ws, container: c.id)
        let ids = try store.deleteProfile(profile.id)
        #expect(Set(ids) == [profile.dataStoreID, c.dataStoreID])
        #expect(try count(Tab.self, database) == 0)
        #expect(try count(Container.self, database) == 0)
    }

    @Test func lastProfileRefused() throws {
        let (store, _, _, profile, _) = try fixture()
        #expect(throws: StoreError.lastProfile) { try store.deleteProfile(profile.id) }
        #expect(try store.profiles().count == 1)
    }

    @Test func deleteUnknownProfileThrowsNotFound() throws {
        let (store, _, _, _, _) = try fixture()
        _ = try store.createProfile(name: "Other")
        #expect(throws: StoreError.notFound) { try store.deleteProfile(UUID()) }
    }
}
