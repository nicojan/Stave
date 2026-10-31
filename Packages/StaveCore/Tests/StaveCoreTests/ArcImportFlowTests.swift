import Foundation
import Testing
@testable import StaveCore

@MainActor
struct ArcImportFlowTests {
    private func makeStore() throws -> OrganizationStore {
        let clock = TestClock()
        return try makeTempStore(now: clock.now).0
    }

    /// A throwaway folder; the caller never touches the real Arc folder.
    private func tempFolder() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("stave-flow-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func makeHome(fixture: String = "basic") throws -> URL {
        let home = try tempFolder()
        let arc = home.appendingPathComponent("Library/Application Support/Arc", isDirectory: true)
        try FileManager.default.createDirectory(at: arc, withIntermediateDirectories: true)
        try arcFixture(fixture).write(to: arc.appendingPathComponent("StorableSidebar.json"))
        return home
    }

    private func workspaceCount(_ store: OrganizationStore) throws -> Int {
        try store.profiles().reduce(0) { $0 + (try store.workspaces(profileID: $1.id).count) }
    }

    private func flow(_ store: OrganizationStore, _ revision: StoreRevision, home: URL) -> ArcImportFlow {
        ArcImportFlow(store: store, revision: revision, source: .arcOnThisMac(home: home))
    }

    private func hasRegularTabs(_ summary: ArcImportSummary) -> Bool {
        summary.imported.contains { !$0.contains("pinned") && ($0.hasSuffix(" tab") || $0.hasSuffix(" tabs")) }
    }

    @Test func importsFromAHome() async throws {
        let store = try makeStore()
        let revision = StoreRevision()
        let home = try makeHome()
        let flow = flow(store, revision, home: home)
        #expect(flow.phase == .ready)
        #expect(flow.previousImport == nil)
        await flow.start()
        guard case .finished(let summary) = flow.phase else { Issue.record("phase was \(flow.phase)"); return }
        #expect(summary.imported == ["2 workspaces", "1 folder", "4 pinned tabs", "2 Essentials"])
        #expect(revision.value == 1)
        #expect(try store.lastImport(source: .arc) != nil)
    }

    @Test func repeatAsksFirst() async throws {
        let store = try makeStore()
        let revision = StoreRevision()
        let home = try makeHome()
        await flow(store, revision, home: home).start()
        let first = try #require(try store.lastImport(source: .arc))
        let before = try workspaceCount(store)

        let second = flow(store, revision, home: home)
        #expect(second.previousImport == first)
        await second.start()
        #expect(second.phase == .confirmRepeat(previous: first))
        second.cancelRepeat()
        #expect(second.phase == .ready)
        #expect(try workspaceCount(store) == before)
        #expect(revision.value == 1)

        await second.start()
        await second.confirmRepeat()
        guard case .finished = second.phase else { Issue.record("phase was \(second.phase)"); return }
        #expect(try workspaceCount(store) > before)
        #expect(revision.value == 2)
    }

    @Test func laterStartOnTheSameFlowUsesTheNewDate() async throws {
        let store = try makeStore()
        let revision = StoreRevision()
        let flow = flow(store, revision, home: try makeHome())
        await flow.start()
        let date = try #require(try store.lastImport(source: .arc))
        #expect(flow.previousImport == date)
        await flow.start()
        #expect(flow.phase == .confirmRepeat(previous: date))
    }

    @Test func confirmRepeatOutsideConfirmationStillRuns() async throws {
        let store = try makeStore()
        let revision = StoreRevision()
        let flow = flow(store, revision, home: try makeHome())
        await flow.confirmRepeat()
        guard case .finished = flow.phase else { Issue.record("phase was \(flow.phase)"); return }
    }

    @Test func startWhileImportingIsIgnored() async throws {
        let store = try makeStore()
        let revision = StoreRevision()
        let flow = flow(store, revision, home: try makeHome())
        async let a: Void = flow.start()
        async let b: Void = flow.start()
        _ = await (a, b)
        // Whichever call ran first imported; the other either no-oped or asked to confirm. Never two imports.
        #expect(revision.value == 1)
        let profile = try #require(try store.profiles().first)
        #expect(try store.workspaces(profileID: profile.id).count == 3)
    }

    @Test func unpinnedOptionIsPassed() async throws {
        let store = try makeStore()
        let flow = flow(store, StoreRevision(), home: try makeHome())
        flow.includeUnpinnedTabs = true
        await flow.start()
        guard case .finished(let summary) = flow.phase else { Issue.record("phase was \(flow.phase)"); return }
        #expect(hasRegularTabs(summary))

        let off = try makeStore()
        let offFlow = self.flow(off, StoreRevision(), home: try makeHome())
        await offFlow.start()
        guard case .finished(let offSummary) = offFlow.phase else { Issue.record("phase was \(offFlow.phase)"); return }
        #expect(!hasRegularTabs(offSummary))
    }

    @Test func pickedFileImportsAndFailureLeavesNoRecord() async throws {
        let store = try makeStore()
        let revision = StoreRevision()
        let folder = try tempFolder()
        let bad = folder.appendingPathComponent("picked.json")
        try Data("{}".utf8).write(to: bad)
        let flow = ArcImportFlow(store: store, revision: revision, source: .pickedFile(bad))
        let before = try workspaceCount(store)
        await flow.start()
        #expect(flow.phase == .failed("This file doesn't contain an Arc sidebar."))
        #expect(try store.lastImport(source: .arc) == nil)
        #expect(revision.value == 0)
        #expect(try workspaceCount(store) == before)
    }

    @Test func missingFileFails() async throws {
        let store = try makeStore()
        let missing = try tempFolder().appendingPathComponent("nope.json")
        let flow = ArcImportFlow(store: store, revision: StoreRevision(), source: .pickedFile(missing))
        await flow.start()
        #expect(flow.phase == .failed("Stave couldn't read this file."))
    }

    @Test func offerRules() async throws {
        let home = try makeHome()
        let empty = try tempFolder()

        let store = try makeStore()
        #expect(try ArcImportFlow.shouldOfferOnFirstRun(arcHome: home, store: store))
        #expect(try !ArcImportFlow.shouldOfferOnFirstRun(arcHome: empty, store: store))

        try store.setSetting(SettingKeys.firstRunCompleted, true)
        #expect(try !ArcImportFlow.shouldOfferOnFirstRun(arcHome: home, store: store))

        let imported = try makeStore()
        await flow(imported, StoreRevision(), home: home).start()
        #expect(try !ArcImportFlow.shouldOfferOnFirstRun(arcHome: home, store: imported))
    }
}
