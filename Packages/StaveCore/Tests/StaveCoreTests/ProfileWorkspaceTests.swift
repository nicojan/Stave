import Foundation
import GRDB
import Testing
@testable import StaveCore

struct ProfileWorkspaceTests {
    @Test func createProfileMakesHomeWorkspace() throws {
        let (store, _, _) = try makeTempStore()
        let profile = try store.createProfile(name: "Work")
        let workspaces = try store.workspaces(profileID: profile.id)
        #expect(workspaces.count == 1)
        #expect(workspaces.first?.name == "Home")
        #expect(workspaces.first?.icon == "house")
        #expect(workspaces.first?.colorHex == "#8E8E93")
        #expect(profile.dataStoreID != profile.id)
    }

    @Test func ensureDefaultProfileIsIdempotent() throws {
        let (store, _, _) = try makeTempStore()
        let first = try store.ensureDefaultProfile()
        let second = try store.ensureDefaultProfile()
        let all = try store.profiles()
        #expect(all.count == 1)
        #expect(all.first?.name == "Personal")
        #expect(first.id == second.id)
    }

    @Test func profilesKeepOrder() throws {
        let (store, _, _) = try makeTempStore()
        _ = try store.createProfile(name: "A")
        _ = try store.createProfile(name: "B")
        _ = try store.createProfile(name: "C")
        #expect(try store.profiles().map(\.name) == ["A", "B", "C"])
    }

    @Test func workspacesKeepOrder() throws {
        let (store, _, _) = try makeTempStore()
        let profile = try store.createProfile(name: "P")
        for name in ["A", "B", "C"] {
            _ = try store.createWorkspace(profileID: profile.id, name: name, icon: "star", colorHex: "#000000")
        }
        #expect(try store.workspaces(profileID: profile.id).map(\.name) == ["Home", "A", "B", "C"])
    }

    @Test func renameBumpsModifiedAt() throws {
        let clock = TestClock()
        let (store, _, _) = try makeTempStore(now: clock.now)
        let profile = try store.createProfile(name: "P")
        let home = try #require(try store.workspaces(profileID: profile.id).first)
        clock.advance(by: 1)
        try store.renameWorkspace(home.id, to: "Main")
        let renamed = try #require(try store.workspaces(profileID: profile.id).first)
        #expect(renamed.name == "Main")
        #expect(renamed.modifiedAt > home.modifiedAt)
        #expect(renamed.modifiedAt == clock.date)
    }

    @Test func renameUnknownThrowsNotFound() throws {
        let (store, _, _) = try makeTempStore()
        #expect(throws: StoreError.notFound) { try store.renameWorkspace(UUID(), to: "X") }
    }

    @Test func deleteUnknownThrowsNotFound() throws {
        let (store, _, _) = try makeTempStore()
        #expect(throws: StoreError.notFound) { try store.deleteWorkspace(UUID()) }
    }

    @Test func deleteLastWorkspaceRefused() throws {
        let (store, _, _) = try makeTempStore()
        let profile = try store.createProfile(name: "P")
        let home = try #require(try store.workspaces(profileID: profile.id).first)
        #expect(throws: StoreError.lastWorkspace) { try store.deleteWorkspace(home.id) }
        #expect(try store.workspaces(profileID: profile.id).count == 1)
    }

    @Test func deleteWorkspaceRemovesIt() throws {
        let (store, _, _) = try makeTempStore()
        let profile = try store.createProfile(name: "P")
        let extra = try store.createWorkspace(profileID: profile.id, name: "X", icon: "star", colorHex: "#111111")
        try store.deleteWorkspace(extra.id)
        #expect(try store.workspaces(profileID: profile.id).map(\.name) == ["Home"])
    }

    @Test func deleteWorkspaceArchivesItsTabs() throws {
        let clock = TestClock()
        let (store, database, _) = try makeTempStore(now: clock.now)
        let profile = try store.createProfile(name: "P")
        let doomed = try store.createWorkspace(profileID: profile.id, name: "Doomed", icon: "star", colorHex: "#111111")
        let now = clock.date
        let survivor = try store.createWorkspace(profileID: profile.id, name: "Survivor", icon: "star", colorHex: "#333333")
        let survivingTab = try store.openTab(url: "https://survivor.example", title: "Survivor", workspaceID: survivor.id, origin: .commandBar, containerID: nil, edge: .top)
        try database.writer.write { db in
            let pinnedSlot = Slot(profileID: profile.id, workspaceID: doomed.id, section: .pinned, sortIndex: 0, modifiedAt: now)
            let regularSlot = Slot(profileID: profile.id, workspaceID: doomed.id, section: .regular, sortIndex: 1, modifiedAt: now)
            try pinnedSlot.insert(db)
            try regularSlot.insert(db)
            try Tab(slotID: pinnedSlot.id, pinnedURL: "https://pinned.example", pinnedTitle: "Pinned", url: "https://pinned.example/a", title: "Pinned", lastActiveAt: now, modifiedAt: now).insert(db)
            try Tab(slotID: regularSlot.id, url: "https://regular.example", title: "Regular", lastActiveAt: now, modifiedAt: now).insert(db)
        }
        clock.advance(by: 5)
        try store.deleteWorkspace(doomed.id)
        let archived = try store.archivedTabs(profileID: profile.id)
        #expect(Set(archived.map(\.url)) == ["https://pinned.example/a", "https://regular.example"])
        #expect(!archived.contains { $0.url == "https://survivor.example" })
        #expect(try store.regularTabs(workspaceID: survivor.id).map(\.id) == [survivingTab.id])
        #expect(archived.allSatisfy { $0.workspaceID == doomed.id && $0.profileID == profile.id && $0.closedAt == clock.date })
    }

    @Test func everyWriteSurvivesReopen() throws {
        let (store, database, file) = try makeTempStore()
        let profile = try store.createProfile(name: "P")
        let extra = try store.createWorkspace(profileID: profile.id, name: "Extra", icon: "star", colorHex: "#222222")
        try database.close()

        let reopened = OrganizationStore(database: try StaveDatabase.open(at: file))
        #expect(try reopened.profiles().map(\.id) == [profile.id])
        #expect(try reopened.workspaces(profileID: profile.id).map(\.name) == ["Home", "Extra"])
        #expect(try reopened.workspaces(profileID: profile.id).last?.id == extra.id)
    }
}
