import Foundation
import Testing
@testable import StaveCore

struct ArcImportStoreTests {
    private func makeStore() throws -> OrganizationStore {
        let clock = TestClock()
        return try makeTempStore(now: clock.now).0
    }

    private func plan(_ fixture: String, includeUnpinned: Bool = false) throws -> ArcImportPlan {
        let sidebar = try ArcSidebarParser.parse(try arcFixture(fixture))
        return ArcImportPlanner.plan(sidebar, options: ArcImportOptions(includeUnpinnedTabs: includeUnpinned), profileNames: [:])
    }

    private func tab(_ url: String, _ title: String) -> PlannedTab { PlannedTab(url: url, title: title) }

    /// Mirrors a stored pinned tree as plan nodes, so it can be compared with the plan.
    private func mirror(_ items: [PinnedItem]) -> [PlannedPinned] {
        items.map { item in
            switch item {
            case .tab(let t):
                return .tab(PlannedTab(url: t.pinnedURL ?? "?", title: t.pinnedTitle ?? "?"))
            case .folder(let f, let children):
                return .folder(title: f.title, children: mirror(children))
            }
        }
    }

    @Test func importBasicFixture() throws {
        let store = try makeStore()
        let report = try ArcImporter.run(sidebar: try arcFixture("basic"), localState: nil, options: .init(), into: store)
        #expect(report.imported == ArcImportReport.Counts(
            profiles: 0, workspaces: 2, folders: 1, pinnedTabs: 4, essentials: 2, regularTabs: 0
        ))
        let profile = try #require(try store.profiles().first)
        let workspaces = try store.workspaces(profileID: profile.id)
        #expect(workspaces.suffix(2).map(\.name) == ["Work", "Space 1"])
        let work = try #require(workspaces.first { $0.name == "Work" })
        let expected = try #require(try plan("basic").profiles.first?.workspaces.first?.pinned)
        #expect(mirror(try store.pinnedItems(workspaceID: work.id)) == expected)
        let essentials = try store.essentials(profileID: profile.id)
        let plannedEssentials = try #require(try plan("basic").profiles.first?.essentials)
        #expect(essentials.map(\.pinnedURL) == plannedEssentials.map(\.url))
        #expect(essentials.map(\.pinnedTitle) == plannedEssentials.map(\.title))
        #expect(essentials.map(\.url) == plannedEssentials.map(\.url))
    }

    @Test func importEdgeCasesCreatesProfile() throws {
        let store = try makeStore()
        let report = try ArcImporter.run(
            sidebar: try arcFixture("edge-cases"), localState: try arcFixture("local-state"), options: .init(), into: store
        )
        #expect(report.imported.profiles == 1)
        #expect(try store.profiles().map(\.name) == ["Personal", "Client Work"])
        let client = try #require(try store.profiles().first { $0.name == "Client Work" })
        let workspaces = try store.workspaces(profileID: client.id)
        #expect(workspaces.map(\.name) == ["Acme"])
        #expect(try store.essentials(profileID: client.id).count == 2)
        let level1 = try findFolder("Level 1", in: try store.pinnedItems(workspaceID: try #require(workspaces.first).id))
        let all = try store.profiles().flatMap { try store.workspaces(profileID: $0.id) }
        var level2: Folder?
        for w in all {
            if let f = findFolder("Level 2", in: try store.pinnedItems(workspaceID: w.id)) { level2 = f.0 }
        }
        let l1 = try #require(level1)
        #expect(try #require(level2).parentFolderID == l1.0.id)
    }

    private func findFolder(_ title: String, in items: [PinnedItem]) -> (Folder, [PinnedItem])? {
        for item in items {
            if case .folder(let f, let children) = item {
                if f.title == title { return (f, children) }
                if let found = findFolder(title, in: children) { return found }
            }
        }
        return nil
    }

    @Test func favoritesOnlyProfileGetsHome() throws {
        let store = try makeStore()
        let plan = ArcImportPlan(
            profiles: [PlannedProfile(target: .new(name: "Solo"), workspaces: [], essentials: [tab("https://a.example.com", "A")])],
            flattened: [], skipped: []
        )
        let report = try store.importArc(plan)
        #expect(report.imported == ArcImportReport.Counts(profiles: 1, essentials: 1))
        let solo = try #require(try store.profiles().first { $0.name == "Solo" })
        #expect(try store.workspaces(profileID: solo.id).map(\.name) == ["Home"])
        #expect(try store.essentials(profileID: solo.id).count == 1)
    }

    @Test func importAppendsAfterExistingData() throws {
        let store = try makeStore()
        let profile = try store.createProfile(name: "Personal")
        let home = try #require(try store.workspaces(profileID: profile.id).first)
        let existing = try store.openTab(url: "https://keep.example.com", title: "Keep", workspaceID: home.id, origin: .commandBar, containerID: nil, edge: .top)
        try store.pinTab(existing.id, folderID: nil)
        // Two Essentials, the first removed: the survivor has sortIndex 1, so restarting imported Essentials at 0 would show.
        let removed = try store.openTab(url: "https://gone.example.com", title: "Gone", workspaceID: home.id, origin: .commandBar, containerID: nil, edge: .top)
        try store.makeEssential(removed.id)
        try store.makeEssential(try store.openTab(url: "https://ess.example.com", title: "Ess", workspaceID: home.id, origin: .commandBar, containerID: nil, edge: .top).id)
        try store.removeEssential(removed.id)
        let pinnedBefore = try store.pinnedItems(workspaceID: home.id)
        let regularBefore = try store.regularTabs(workspaceID: home.id)
        let essentialBefore = try #require(try store.essentials(profileID: profile.id).first)

        _ = try ArcImporter.run(sidebar: try arcFixture("basic"), localState: nil, options: .init(), into: store)

        let workspaces = try store.workspaces(profileID: profile.id)
        #expect(workspaces.first?.id == home.id)
        #expect(workspaces.map(\.name) == ["Home", "Work", "Space 1"])
        #expect(try store.pinnedItems(workspaceID: home.id) == pinnedBefore)
        #expect(try store.regularTabs(workspaceID: home.id) == regularBefore)
        let essentials = try store.essentials(profileID: profile.id)
        #expect(essentials.count == 3)
        #expect(essentials.first == essentialBefore)
        let plannedEssentials = try #require(try plan("basic").profiles.first?.essentials)
        #expect(essentials.map(\.pinnedURL) == ["https://ess.example.com"] + plannedEssentials.map(\.url))
        #expect(try store.profiles().count == 1)
    }

    @Test func regularTabsKeepArcOrder() throws {
        let store = try makeStore()
        let expected = try #require(try plan("basic", includeUnpinned: true).profiles.first?.workspaces.first?.regular)
        let report = try ArcImporter.run(
            sidebar: try arcFixture("basic"), localState: nil, options: .init(includeUnpinnedTabs: true), into: store
        )
        #expect(report.imported.regularTabs == expected.count)
        #expect(!expected.isEmpty)
        let profile = try #require(try store.profiles().first)
        let work = try #require(try store.workspaces(profileID: profile.id).first { $0.name == "Work" })
        #expect(try store.regularTabs(workspaceID: work.id).map(\.url) == expected.map(\.url))
    }

    @Test func failedImportWritesNothing() throws {
        let store = try makeStore()
        let profile = try store.createProfile(name: "Personal")
        func snapshot() throws -> ([Profile], [[Workspace]], [[Tab]], [[ArchivedTab]]) {
            let profiles = try store.profiles()
            return (
                profiles,
                try profiles.map { try store.workspaces(profileID: $0.id) },
                try profiles.map { try store.essentials(profileID: $0.id) },
                try profiles.map { try store.archivedTabs(profileID: $0.id) }
            )
        }
        let before = try snapshot()
        let deep = PlannedPinned.folder(title: "a", children: [.folder(title: "b", children: [.folder(title: "c", children: [])])])
        let workspace = PlannedWorkspace(name: "W", icon: "x", colorHex: "#000000", pinned: [deep], regular: [])
        let bad = ArcImportPlan(
            profiles: [
                PlannedProfile(target: .existingDefault, workspaces: [workspace], essentials: [tab("https://e.example.com", "E")]),
                PlannedProfile(target: .new(name: "Extra"), workspaces: [], essentials: []),
            ],
            flattened: [], skipped: []
        )
        #expect(throws: StoreError.folderTooDeep) { try store.importArc(bad) }
        let after = try snapshot()
        #expect(after.0 == before.0)
        #expect(after.1 == before.1)
        #expect(after.2 == before.2)
        #expect(after.3 == before.3)
        #expect(try store.profiles().map(\.id) == [profile.id])
    }

    @Test func emptyExistingDefaultWritesNothingElse() throws {
        let store = try makeStore()
        let plan = ArcImportPlan(
            profiles: [PlannedProfile(target: .existingDefault, workspaces: [], essentials: [])], flattened: [], skipped: []
        )
        let report = try store.importArc(plan)
        #expect(report.imported == ArcImportReport.Counts())
        let profile = try #require(try store.profiles().first)
        #expect(try store.workspaces(profileID: profile.id).map(\.name) == ["Home"])
    }

    @Test func fileLocations() {
        let home = URL(fileURLWithPath: "/Users/test")
        #expect(ArcImporter.sidebarFile(home: home).path == "/Users/test/Library/Application Support/Arc/StorableSidebar.json")
        #expect(ArcImporter.localStateFile(home: home).path == "/Users/test/Library/Application Support/Arc/User Data/Local State")
    }

    @Test func defaultProfileIsResolvedBeforeNewProfiles() throws {
        let store = try makeStore()
        let workspace = { (name: String) in PlannedWorkspace(name: name, icon: "square.grid.2x2", colorHex: "#8E8E93", pinned: [], regular: []) }
        let plan = ArcImportPlan(
            profiles: [
                PlannedProfile(target: .new(name: "X"), workspaces: [workspace("In X")], essentials: []),
                PlannedProfile(target: .existingDefault, workspaces: [workspace("In Default")], essentials: []),
            ],
            flattened: [], skipped: [])
        _ = try store.importArc(plan)
        let profiles = try store.profiles()
        #expect(profiles.map(\.name) == ["Personal", "X"])
        let names = try profiles.map { profile in try store.workspaces(profileID: profile.id).map(\.name) }
        #expect(names[0].contains("In Default"))
        #expect(names[1] == ["In X"])
    }
}
