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
        let l2 = try #require(level2)
        #expect(l2.parentFolderID == l1.0.id)
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

    // MARK: - Import record and file reading

    private func makeStoreAndClock() throws -> (OrganizationStore, TestClock) {
        let clock = TestClock()
        return (try makeTempStore(now: clock.now).0, clock)
    }

    private func makeTempFolder() throws -> URL {
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("StaveTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder
    }

    @Test func importWritesRecord() throws {
        let (store, clock) = try makeStoreAndClock()
        #expect(try store.lastImport(source: .arc) == nil)
        _ = try ArcImporter.run(sidebar: try arcFixture("basic"), localState: nil, options: .init(), into: store)
        #expect(try store.lastImport(source: .arc) == clock.date)
    }

    @Test func lastImportIsTheNewest() throws {
        let (store, clock) = try makeStoreAndClock()
        _ = try ArcImporter.run(sidebar: try arcFixture("basic"), localState: nil, options: .init(), into: store)
        clock.advance(by: 60)
        _ = try ArcImporter.run(sidebar: try arcFixture("basic"), localState: nil, options: .init(), into: store)
        #expect(try store.lastImport(source: .arc) == clock.date)
    }

    @Test func failedImportWritesNoRecord() throws {
        let store = try makeStore()
        let deep = PlannedPinned.folder(title: "a", children: [.folder(title: "b", children: [.folder(title: "c", children: [])])])
        let workspace = PlannedWorkspace(name: "W", icon: "x", colorHex: "#000000", pinned: [deep], regular: [])
        let bad = ArcImportPlan(
            profiles: [PlannedProfile(target: .existingDefault, workspaces: [workspace], essentials: [])],
            flattened: [], skipped: []
        )
        #expect(throws: StoreError.folderTooDeep) { try store.importArc(bad) }
        #expect(try store.lastImport(source: .arc) == nil)
    }

    private func makeSparseFile(at file: URL, size: Int) throws {
        #expect(FileManager.default.createFile(atPath: file.path, contents: nil))
        let handle = try FileHandle(forWritingTo: file)
        try handle.truncate(atOffset: UInt64(size))
        try handle.close()
    }

    @Test func oversizedFileRefusedBeforeReading() throws {
        let folder = try makeTempFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let file = folder.appendingPathComponent("StorableSidebar.json")
        try makeSparseFile(at: file, size: ArcSidebarParser.maximumFileSize + 1)
        // Mode 000 makes any read fail with .unreadable, so .fileTooLarge proves the size was checked first.
        // Root ignores permissions, so there the check below cannot tell the two orders apart and is skipped.
        let canTellOrder = getuid() != 0
        if canTellOrder { try FileManager.default.setAttributes([.posixPermissions: 0], ofItemAtPath: file.path) }
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path) }
        let store = try makeStore()
        #expect(throws: ArcImportError.fileTooLarge) {
            try ArcImporter.run(sidebarFile: file, localStateFile: nil, options: .init(), into: store)
        }
        #expect(try store.lastImport(source: .arc) == nil)
    }

    @Test func directoryIsUnreadable() throws {
        let folder = try makeTempFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let store = try makeStore()
        #expect(throws: ArcImportError.unreadable) {
            try ArcImporter.run(sidebarFile: folder, localStateFile: nil, options: .init(), into: store)
        }
        #expect(try store.lastImport(source: .arc) == nil)
    }

    @Test func missingFileIsUnreadable() throws {
        let folder = try makeTempFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let store = try makeStore()
        #expect(throws: ArcImportError.unreadable) {
            try ArcImporter.run(
                sidebarFile: folder.appendingPathComponent("StorableSidebar.json"), localStateFile: nil, options: .init(), into: store
            )
        }
        #expect(try store.lastImport(source: .arc) == nil)
    }

    @Test func symlinkToASidebarFileImports() throws {
        let folder = try makeTempFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let real = folder.appendingPathComponent("real.json")
        try arcFixture("basic").write(to: real)
        let home = folder.appendingPathComponent("home", isDirectory: true)
        let link = ArcImporter.sidebarFile(home: home)
        try FileManager.default.createDirectory(at: link.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: real)
        #expect(ArcImporter.isAvailable(home: home))
        let store = try makeStore()
        let report = try ArcImporter.run(sidebarFile: link, localStateFile: nil, options: .init(), into: store)
        #expect(report.imported.workspaces == 2)
    }

    @Test func symlinkToADeviceIsRefused() throws {
        let folder = try makeTempFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let home = folder.appendingPathComponent("home", isDirectory: true)
        let link = ArcImporter.sidebarFile(home: home)
        try FileManager.default.createDirectory(at: link.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: URL(fileURLWithPath: "/dev/null"))
        #expect(!ArcImporter.isAvailable(home: home))
        let store = try makeStore()
        #expect(throws: ArcImportError.unreadable) {
            try ArcImporter.run(sidebarFile: link, localStateFile: nil, options: .init(), into: store)
        }
    }

    @Test func localStateBesideAPickedFile() throws {
        let folder = try makeTempFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let sidebarFile = folder.appendingPathComponent("StorableSidebar.json")
        try arcFixture("edge-cases").write(to: sidebarFile)
        let localState = ArcImporter.localStateFile(nextTo: sidebarFile)
        #expect(localState.path == folder.appendingPathComponent("User Data").appendingPathComponent("Local State").path)
        try FileManager.default.createDirectory(at: localState.deletingLastPathComponent(), withIntermediateDirectories: true)
        try arcFixture("local-state").write(to: localState)

        let withNames = try makeStore()
        _ = try ArcImporter.run(sidebarFile: sidebarFile, localStateFile: localState, options: .init(), into: withNames)
        #expect(try withNames.profiles().map(\.name).contains("Client Work"))

        try FileManager.default.removeItem(at: localState)
        let without = try makeStore()
        _ = try ArcImporter.run(sidebarFile: sidebarFile, localStateFile: localState, options: .init(), into: without)
        let names = try without.profiles().map(\.name)
        #expect(!names.contains("Client Work"))
        #expect(names.contains("Profile 1"))
    }

    /// Imports the edge-cases sidebar with `localState` as the Local State path and returns the profile names.
    private func profileNames(withLocalState make: (URL) throws -> Void) throws -> [String] {
        let folder = try makeTempFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let sidebarFile = folder.appendingPathComponent("StorableSidebar.json")
        try arcFixture("edge-cases").write(to: sidebarFile)
        let localState = ArcImporter.localStateFile(nextTo: sidebarFile)
        try FileManager.default.createDirectory(at: localState.deletingLastPathComponent(), withIntermediateDirectories: true)
        try make(localState)
        let store = try makeStore()
        _ = try ArcImporter.run(sidebarFile: sidebarFile, localStateFile: localState, options: .init(), into: store)
        return try store.profiles().map(\.name)
    }

    @Test func oversizedLocalStateIsTreatedAsAbsent() throws {
        // Valid Local State padded with trailing whitespace (legal JSON) past the cap: without the cap it would decode and name the profile.
        let names = try profileNames { url in
            var data = try arcFixture("local-state")
            data.append(Data(repeating: UInt8(ascii: " "), count: ArcImporter.maximumLocalStateSize + 1 - data.count))
            #expect(data.count == ArcImporter.maximumLocalStateSize + 1)
            try data.write(to: url)
        }
        #expect(!names.contains("Client Work"))
        #expect(names.contains("Profile 1"))
    }

    @Test func fifoLocalStateIsTreatedAsAbsentWithoutHanging() throws {
        let names = try profileNames { url in #expect(mkfifo(url.path, 0o600) == 0) }
        #expect(names.contains("Profile 1"))
    }

    @Test func deviceSymlinkLocalStateIsTreatedAsAbsent() throws {
        let names = try profileNames { url in
            try FileManager.default.createSymbolicLink(at: url, withDestinationURL: URL(fileURLWithPath: "/dev/null"))
        }
        #expect(names.contains("Profile 1"))
    }

    @Test func symlinkedLocalStateIsRead() throws {
        let names = try profileNames { url in
            let real = url.deletingLastPathComponent().appendingPathComponent("real-state.json")
            try arcFixture("local-state").write(to: real)
            try FileManager.default.createSymbolicLink(at: url, withDestinationURL: real)
        }
        #expect(names.contains("Client Work"))
    }

    @Test func unreadableLocalStateIsTreatedAsAbsent() throws {
        let folder = try makeTempFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let sidebarFile = folder.appendingPathComponent("StorableSidebar.json")
        try arcFixture("edge-cases").write(to: sidebarFile)
        let store = try makeStore()
        // A directory where Local State should be: unreadable, so profile names fall back.
        _ = try ArcImporter.run(sidebarFile: sidebarFile, localStateFile: folder, options: .init(), into: store)
        #expect(try store.profiles().map(\.name).contains("Profile 1"))
    }

    @Test func availabilityNeedsARegularFile() throws {
        let home = try makeTempFolder()
        defer { try? FileManager.default.removeItem(at: home) }
        #expect(!ArcImporter.isAvailable(home: home))
        let file = ArcImporter.sidebarFile(home: home)
        try FileManager.default.createDirectory(at: file, withIntermediateDirectories: true)
        #expect(!ArcImporter.isAvailable(home: home))
        try FileManager.default.removeItem(at: file)
        try arcFixture("basic").write(to: file)
        #expect(ArcImporter.isAvailable(home: home))
    }
}
