import Foundation
import GRDB
import Testing
@testable import StaveCore

/// Deleting a profile or container (decisions 18 and 19, Review Focus 3): what the question names, the order of the steps, what is refused.
@MainActor
struct ProfileDeletionTests {
    private func fixture() throws -> (OrganizationStore, StaveDatabase, Profile, Profile) {
        let (store, database, _) = try makeTempStore()
        let keep = try store.ensureDefaultProfile()
        let doomed = try store.createProfile(name: "Work")
        return (store, database, keep, doomed)
    }

    private func open(_ store: OrganizationStore, _ workspace: Workspace, container: UUID? = nil) throws -> Tab {
        try store.openTab(url: "https://a.example", title: "a", workspaceID: workspace.id, origin: .commandBar, containerID: container, edge: .bottom)
    }

    private struct Refused: Error {}

    @MainActor final class Recorder {
        var events: [String] = []
        var removed: [[UUID]] = []
        /// Store IDs whose removal fails.
        var failing: Set<UUID> = []
        /// Runs when the stores are asked for, before the answer.
        var onRemove: (@MainActor ([UUID]) -> Void)?
    }

    private func removal(_ store: OrganizationStore, log: Recorder) -> StoreRemoval {
        StoreRemoval(store: store) { ids in
            log.removed.append(ids)
            log.onRemove?(ids)
            var failures: [UUID: any Error] = [:]
            for id in ids where log.failing.contains(id) { failures[id] = Refused() }
            return failures
        }
    }

    private func deletion(
        _ store: OrganizationStore, log: Recorder, session: WindowSession? = nil, revision: StoreRevision? = nil
    ) -> ProfileDeletion {
        ProfileDeletion(
            store: store,
            closePrivateSession: { log.events.append("private:\($0)") },
            switchWindows: { log.events.append("switch:\($0)") },
            removal: removal(store, log: log),
            session: session,
            revision: revision
        )
    }

    // MARK: - The question

    @Test func profileDeletionNamesWhatGoes() throws {
        let (store, _, _, doomed) = try fixture()
        let home = try #require(try store.workspaces(profileID: doomed.id).first)
        let second = try store.createWorkspace(profileID: doomed.id, name: "Second", icon: "", colorHex: "#FF3B30")
        _ = try open(store, home)
        _ = try open(store, second)
        let closed = try open(store, second)
        _ = try store.closeTab(closed.id)
        try store.recordVisit(profileID: doomed.id, url: "https://a.example/", title: "a", at: Date())

        let summary = try store.profileSummary(doomed.id)
        #expect(summary == ProfileSummary(workspaces: 2, tabs: 2, archived: 1, history: 1))
        let question = DeletionCopy.profileQuestion(summary, name: "Work")
        #expect(question == "Delete the profile “Work”? Its 2 workspaces, 2 tabs, its archive, history, downloads list and website data (cookies, sign-ins) will be deleted. This can't be undone. Stave's backups keep a copy for up to 3 days.")
    }

    @Test func questionUsesSingularForOne() {
        let question = DeletionCopy.profileQuestion(ProfileSummary(workspaces: 1, tabs: 1, archived: 0, history: 0), name: "P")
        #expect(question.contains("Its 1 workspace, 1 tab, its archive"))
    }

    @Test func summaryCountsOnlyThatProfile() throws {
        let (store, _, keep, doomed) = try fixture()
        let keepHome = try #require(try store.workspaces(profileID: keep.id).first)
        _ = try open(store, keepHome)
        #expect(try store.profileSummary(doomed.id) == ProfileSummary(workspaces: 1, tabs: 0, archived: 0, history: 0))
    }

    // MARK: - The order

    @Test func storesRemovedOnlyAfterRows() async throws {
        let (store, _, _, doomed) = try fixture()
        let container = try store.createContainer(profileID: doomed.id, name: "C", colorHex: "#FF3B30")
        let log = Recorder()
        var rowGoneWhenAsked: Bool?
        var pendingWhenAsked: [UUID] = []
        log.onRemove = { _ in
            rowGoneWhenAsked = !((try? store.profiles().contains { $0.id == doomed.id }) ?? true)
            pendingWhenAsked = (try? store.pendingStoreRemovals()) ?? []
        }
        try await deletion(store, log: log).run(profileID: doomed.id)
        #expect(rowGoneWhenAsked == true)
        #expect(log.removed == [[doomed.dataStoreID, container.dataStoreID]])
        #expect(pendingWhenAsked == [doomed.dataStoreID, container.dataStoreID]) // recorded before any removal began
        #expect(try store.pendingStoreRemovals().isEmpty) // and cleared once they succeeded
        #expect(log.events == ["private:\(doomed.id)", "switch:\(doomed.id)"])
    }

    // MARK: - Pending store removals (H2)

    @Test func idsRecordedInTheDeleteTransaction() throws {
        let (store, _, keep, doomed) = try fixture()
        let container = try store.createContainer(profileID: doomed.id, name: "C", colorHex: "#FF3B30")
        let spare = try store.createContainer(profileID: keep.id, name: "Spare", colorHex: "#FF3B30")
        #expect(try store.pendingStoreRemovals().isEmpty)
        let ids = try store.deleteProfile(doomed.id)
        #expect(try store.pendingStoreRemovals() == ids)
        #expect(ids == [doomed.dataStoreID, container.dataStoreID])
        let storeID = try store.deleteContainer(spare.id)
        #expect(try store.pendingStoreRemovals() == ids + [storeID])
    }

    @Test func aRefusedDeletionRecordsNothing() throws {
        let (store, _, keep, _) = try fixture()
        let home = try #require(try store.workspaces(profileID: keep.id).first)
        let used = try store.createContainer(profileID: keep.id, name: "Used", colorHex: "#FF3B30")
        _ = try open(store, home, container: used.id)
        #expect(throws: StoreError.containerInUse) { try store.deleteContainer(used.id) }
        #expect(try store.pendingStoreRemovals().isEmpty)
    }

    @Test func pendingClearedPerSuccessAndKeptOnFailure() async throws {
        let (store, _, _, doomed) = try fixture()
        let container = try store.createContainer(profileID: doomed.id, name: "C", colorHex: "#FF3B30")
        let log = Recorder()
        log.failing = [container.dataStoreID]
        do {
            try await deletion(store, log: log).run(profileID: doomed.id)
            Issue.record("expected the store removal to be reported")
        } catch let error as StoreRemovalError {
            #expect(Set(error.failures.keys) == [container.dataStoreID])
        }
        #expect(try store.pendingStoreRemovals() == [container.dataStoreID]) // the profile's own store went, the container's stays

        // A later run (the next launch) retries it and clears it.
        log.failing = []
        try await removal(store, log: log).runPending()
        #expect(log.removed.last == [container.dataStoreID])
        #expect(try store.pendingStoreRemovals().isEmpty)
    }

    @Test func nothingPendingAsksForNothing() async throws {
        let (store, _, _, _) = try fixture()
        let log = Recorder()
        try await removal(store, log: log).runPending()
        #expect(log.removed.isEmpty)
    }

    @Test func aLaterDeletionRetriesEarlierFailures() async throws {
        let (store, _, _, doomed) = try fixture()
        let second = try store.createProfile(name: "Second")
        let log = Recorder()
        log.failing = [doomed.dataStoreID]
        _ = try? await deletion(store, log: log).run(profileID: doomed.id)
        log.failing = []
        try await deletion(store, log: log).run(profileID: second.id)
        #expect(Set(try #require(log.removed.last)) == [doomed.dataStoreID, second.dataStoreID])
        #expect(try store.pendingStoreRemovals().isEmpty)
    }

    // MARK: - Windows and the revision

    @Test func sessionStatesNamingTheProfileAreDropped() async throws {
        let (store, _, keep, doomed) = try fixture()
        let keepHome = try #require(try store.workspaces(profileID: keep.id).first)
        let doomedHome = try #require(try store.workspaces(profileID: doomed.id).first)
        let session = WindowSession(store: store)
        session.enableSaving()
        // The only window on "Work" was closed (Stave stays open), so nothing switches its saved state.
        let stale = WindowState(profileID: doomed.id, workspaceID: doomedHome.id, frame: "0 0 800 600", sortIndex: 0)
        let other = WindowState(profileID: keep.id, workspaceID: keepHome.id, frame: "0 0 800 600", sortIndex: 1)
        session.update(stale)
        session.update(other)
        try await deletion(store, log: Recorder(), session: session).run(profileID: doomed.id)
        #expect(session.states.map(\.id) == [other.id])
        try session.saveNow() // quit would otherwise fail on the deleted profile's foreign key
        #expect(try store.restoredWindows().map(\.id) == [other.id])
    }

    @Test func revisionBumpsOnceRowsAreGoneBeforeStoresAreRemoved() async throws {
        let (store, _, _, doomed) = try fixture()
        let revision = StoreRevision()
        let log = Recorder()
        var revisionWhenAsked: Int?
        log.onRemove = { _ in revisionWhenAsked = revision.value }
        try await deletion(store, log: log, revision: revision).run(profileID: doomed.id)
        #expect(revisionWhenAsked == 1)
    }

    @Test func lastProfileRefused() async throws {
        let (store, _, _, doomed) = try fixture()
        let keep = try #require(try store.profiles().first { $0.id != doomed.id })
        let log = Recorder()
        _ = try store.deleteProfile(doomed.id)
        do {
            try await deletion(store, log: log).run(profileID: keep.id)
            Issue.record("expected .lastProfile")
        } catch let error as StoreError {
            #expect(error == .lastProfile)
        }
        #expect(log.events.isEmpty && log.removed.isEmpty) // no window was touched
        #expect(try store.profiles().map(\.id) == [keep.id])
    }

    @Test func unknownProfileTouchesNothing() async throws {
        let (store, _, _, _) = try fixture()
        let log = Recorder()
        do {
            try await deletion(store, log: log).run(profileID: UUID())
            Issue.record("expected .notFound")
        } catch let error as StoreError {
            #expect(error == .notFound)
        }
        #expect(log.events.isEmpty)
    }

    @Test func failedStoreRemovalIsReportedAfterRowsAreGone() async throws {
        let (store, _, _, doomed) = try fixture()
        let log = Recorder()
        log.failing = [doomed.dataStoreID]
        do {
            try await deletion(store, log: log).run(profileID: doomed.id)
            Issue.record("expected the store removal to be reported")
        } catch is StoreRemovalError {
            // Only a store failure is this error type.
        }
        #expect(try !store.profiles().contains { $0.id == doomed.id })
    }

    // MARK: - The external-link setting

    @Test func deletedTargetResetsExternalLinkSetting() throws {
        let (store, _, keep, doomed) = try fixture()
        let doomedHome = try #require(try store.workspaces(profileID: doomed.id).first)
        try store.setSetting(SettingKeys.externalLinkTarget, .workspace(profileID: doomed.id, workspaceID: doomedHome.id))
        _ = try store.deleteProfile(doomed.id)
        #expect(try store.setting(SettingKeys.externalLinkTarget) == .lastUsed)

        // A workspace the setting names.
        let extra = try store.createWorkspace(profileID: keep.id, name: "Extra", icon: "", colorHex: "#FF3B30")
        try store.setSetting(SettingKeys.externalLinkTarget, .workspace(profileID: keep.id, workspaceID: extra.id))
        try store.deleteWorkspace(extra.id)
        #expect(try store.setting(SettingKeys.externalLinkTarget) == .lastUsed)

        // A different workspace, or a different profile, leaves it alone.
        let other = try store.createWorkspace(profileID: keep.id, name: "Other", icon: "", colorHex: "#FF3B30")
        let gone = try store.createWorkspace(profileID: keep.id, name: "Gone", icon: "", colorHex: "#FF3B30")
        let target = ExternalLinkTarget.workspace(profileID: keep.id, workspaceID: other.id)
        try store.setSetting(SettingKeys.externalLinkTarget, target)
        try store.deleteWorkspace(gone.id)
        #expect(try store.setting(SettingKeys.externalLinkTarget) == target)
        let third = try store.createProfile(name: "Third")
        _ = try store.deleteProfile(third.id)
        #expect(try store.setting(SettingKeys.externalLinkTarget) == target)
    }

    // MARK: - Containers

    @Test func containerInUseRefusedWithCount() throws {
        let (store, _, keep, _) = try fixture()
        let home = try #require(try store.workspaces(profileID: keep.id).first)
        let container = try store.createContainer(profileID: keep.id, name: "Work Google", colorHex: "#FF3B30")
        _ = try open(store, home, container: container.id)
        let archivedOne = try open(store, home, container: container.id)
        _ = try store.closeTab(archivedOne.id)

        let usage = try store.containerUsage(container.id)
        #expect(usage.open == 1 && usage.archived == 1)
        #expect(DeletionCopy.containerInUse(count: 2, name: "Work Google") == "2 tabs still use “Work Google”. Close them or move them out first.")
        #expect(DeletionCopy.containerInUse(count: 1, name: "Work Google") == "1 tab still uses “Work Google”. Close it or move it out first.")
        #expect(throws: StoreError.containerInUse) { try store.deleteContainer(container.id) }
        #expect(try store.containers(profileID: keep.id).count == 1)
    }

    @Test func modelRefusesAUsedContainerAndAsksForAFreeOne() throws {
        let (store, _, keep, _) = try fixture()
        let home = try #require(try store.workspaces(profileID: keep.id).first)
        let used = try store.createContainer(profileID: keep.id, name: "Used", colorHex: "#FF3B30")
        let free = try store.createContainer(profileID: keep.id, name: "Free", colorHex: "#FF3B30")
        _ = try open(store, home, container: used.id)
        let model = makeModel(store)
        #expect(model.containerDeletion(used) == .refused(DeletionCopy.containerInUse(count: 1, name: "Used")))
        #expect(model.containerDeletion(free) == .ask(DeletionCopy.containerQuestion(name: "Free")))
    }

    @Test func modelDeletesContainerRowBeforeItsStore() async throws {
        let (store, _, keep, _) = try fixture()
        let container = try store.createContainer(profileID: keep.id, name: "Free", colorHex: "#FF3B30")
        let log = Recorder()
        var rowGoneWhenAsked: Bool?
        log.onRemove = { _ in rowGoneWhenAsked = (try? store.containers(profileID: keep.id).isEmpty) }
        let model = makeModel(store, log: log)
        await model.deleteContainer(container)
        #expect(rowGoneWhenAsked == true)
        #expect(log.removed == [[container.dataStoreID]])
        #expect(model.message == nil)
        #expect(try store.pendingStoreRemovals().isEmpty)
    }

    @Test func storeFailureIsReportedAsDeletedButDataRemains() async throws {
        let (store, _, _, doomed) = try fixture()
        let log = Recorder()
        log.failing = [doomed.dataStoreID]
        let model = makeModel(store, log: log)
        await model.deleteProfile(doomed.id)
        #expect(model.message == DeletionCopy.websiteDataNotRemoved)
        #expect(try !store.profiles().contains { $0.id == doomed.id })
    }

    /// A database failure while the rows are being deleted must not say the profile was deleted (H1).
    @Test func databaseFailureIsNotReportedAsDeleted() async throws {
        let (store, database, _, doomed) = try fixture()
        try await database.writer.write { db in
            try db.execute(sql: "CREATE TRIGGER refuseDelete BEFORE DELETE ON profile BEGIN SELECT RAISE(ABORT, 'refused'); END")
        }
        let log = Recorder()
        let model = makeModel(store, log: log)
        await model.deleteProfile(doomed.id)
        #expect(model.message == StoreErrorText.fallback)
        #expect(model.message != DeletionCopy.websiteDataNotRemoved)
        #expect(try store.profiles().contains { $0.id == doomed.id }) // control: the row really is still there
        #expect(log.removed.isEmpty)
    }

    @Test func databaseFailureDeletingAContainerIsNotReportedAsDeleted() async throws {
        let (store, database, keep, _) = try fixture()
        let container = try store.createContainer(profileID: keep.id, name: "Free", colorHex: "#FF3B30")
        try await database.writer.write { db in
            try db.execute(sql: "CREATE TRIGGER refuseDelete BEFORE DELETE ON container BEGIN SELECT RAISE(ABORT, 'refused'); END")
        }
        let model = makeModel(store, log: Recorder())
        await model.deleteContainer(container)
        #expect(model.message == StoreErrorText.fallback)
        #expect(try store.pendingStoreRemovals().isEmpty)
    }

    /// A successful deletion clears an older failure message (L5).
    @Test func successfulDeleteClearsAnOlderMessage() async throws {
        let (store, _, keep, doomed) = try fixture()
        let model = makeModel(store, log: Recorder())
        model.renameProfile(keep.id, to: "  ")
        #expect(model.message == StoreErrorText.message(for: StoreError.blankName))
        await model.deleteProfile(doomed.id)
        #expect(model.message == nil)

        model.renameProfile(keep.id, to: "")
        let container = try store.createContainer(profileID: keep.id, name: "Free", colorHex: "#FF3B30")
        #expect(model.message != nil)
        await model.deleteContainer(container)
        #expect(model.message == nil)
    }

    private func makeModel(_ store: OrganizationStore, log: Recorder) -> SettingsModel {
        let revision = StoreRevision()
        let removal = removal(store, log: log)
        let deletion = ProfileDeletion(
            store: store, closePrivateSession: { _ in }, switchWindows: { _ in }, removal: removal, session: nil, revision: revision
        )
        return SettingsModel(store: store, revision: revision, profileDeletion: deletion, removal: removal)
    }

    private func makeModel(_ store: OrganizationStore) -> SettingsModel { makeModel(store, log: Recorder()) }

    // MARK: - Names and colours

    @Test func blankProfileNameRefused() throws {
        let (store, _, keep, _) = try fixture()
        #expect(throws: StoreError.blankName) { try store.renameProfile(keep.id, to: "   \n") }
        #expect(try store.profiles().first { $0.id == keep.id }?.name == keep.name)
        try store.renameProfile(keep.id, to: "  Home  ")
        #expect(try store.profiles().first { $0.id == keep.id }?.name == "Home")
        #expect(throws: StoreError.notFound) { try store.renameProfile(UUID(), to: "X") }
        #expect(StoreErrorText.message(for: StoreError.blankName) == "Give it a name.")
    }

    @Test func blankContainerNameRefused() throws {
        let (store, _, keep, _) = try fixture()
        let container = try store.createContainer(profileID: keep.id, name: "Work", colorHex: "#FF3B30")
        #expect(throws: StoreError.blankName) { try store.updateContainer(container.id, name: " ", colorHex: "#FF3B30") }
        #expect(try store.containers(profileID: keep.id).first?.name == "Work")
    }

    @Test func containerColourFromPalette() throws {
        let (store, _, keep, _) = try fixture()
        let container = try store.createContainer(profileID: keep.id, name: "Work", colorHex: "#FF3B30")
        let updated = try store.updateContainer(container.id, name: "Work", colorHex: "#3478f6") // case-insensitive, stored as the palette's
        #expect(updated.colorHex == "#3478F6")
        #expect(throws: StoreError.invalidColour) { try store.updateContainer(container.id, name: "Work", colorHex: "#123456") }
        #expect(try store.containers(profileID: keep.id).first?.colorHex == "#3478F6")
    }

    @Test func containerKeepsItsOwnColourOnRename() throws {
        let (store, _, keep, _) = try fixture()
        let imported = try store.createContainer(profileID: keep.id, name: "Imported", colorHex: "#123456")
        let renamed = try store.updateContainer(imported.id, name: "Renamed", colorHex: "#123456")
        #expect(renamed.name == "Renamed" && renamed.colorHex == "#123456")
        #expect(throws: StoreError.invalidColour) { try store.updateContainer(imported.id, name: "Renamed", colorHex: "#654321") }
        #expect(throws: StoreError.notFound) { try store.updateContainer(UUID(), name: "X", colorHex: "#FF3B30") }
    }
}
