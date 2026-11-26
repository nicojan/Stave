import Foundation
import GRDB
import Testing
@testable import StaveCore

/// Round 2 of Task 12: who a failed store removal is blamed on, one removal run at a time, post-delete bookkeeping failures, the pending
/// list's one transaction, an unreadable pending list, and the Settings window's small state rules.
@MainActor
struct StoreRemovalTests {
    private struct Refused: Error {}

    @MainActor final class Log {
        var removed: [[UUID]] = []
        var failing: Set<UUID> = []
        var active = 0
        var mostActive = 0
        /// How many times a removal suspends, so a second run has the chance to overlap the first.
        var suspensions = 0
    }

    private func removal(_ store: OrganizationStore, _ log: Log, timeout: Duration = .seconds(120)) -> StoreRemoval {
        StoreRemoval(store: store, timeout: timeout) { ids in
            log.removed.append(ids)
            log.active += 1
            log.mostActive = max(log.mostActive, log.active)
            for _ in 0..<log.suspensions { await Task.yield() }
            log.active -= 1
            var failures: [UUID: any Error] = [:]
            for id in ids where log.failing.contains(id) { failures[id] = Refused() }
            return failures
        }
    }

    private func makeModel(_ store: OrganizationStore, _ log: Log, revision: StoreRevision = StoreRevision()) -> SettingsModel {
        let removal = removal(store, log)
        let deletion = ProfileDeletion(
            store: store, closePrivateSession: { _ in }, switchWindows: { _ in }, removal: removal, session: nil, revision: revision
        )
        return SettingsModel(store: store, revision: revision, profileDeletion: deletion, removal: removal)
    }

    private func fixture() throws -> (OrganizationStore, StaveDatabase, Profile, Profile) {
        let (store, database, _) = try makeTempStore()
        let keep = try store.ensureDefaultProfile()
        let other = try store.createProfile(name: "Work")
        return (store, database, keep, other)
    }

    // MARK: - R1-M1 (a): blame only this deletion's stores

    @Test func anOlderStuckStoreIsNotBlamedOnALaterContainerDeletion() async throws {
        let (store, _, keep, doomed) = try fixture()
        let log = Log()
        log.failing = [doomed.dataStoreID]
        let model = makeModel(store, log)
        await model.deleteProfile(doomed.id)
        #expect(model.message == DeletionCopy.websiteDataNotRemoved) // control: its own failure is reported
        let container = try store.createContainer(profileID: keep.id, name: "Free", colorHex: "#FF3B30")
        await model.deleteContainer(container)
        #expect(model.message == nil) // the older store still fails, but it is not this deletion's
        #expect(try store.pendingStoreRemovals() == [doomed.dataStoreID]) // and it is still retried later, quietly
        #expect(Set(try #require(log.removed.last)) == [doomed.dataStoreID, container.dataStoreID])
    }

    @Test func anOlderStuckStoreIsNotBlamedOnALaterProfileDeletion() async throws {
        let (store, _, _, doomed) = try fixture()
        let second = try store.createProfile(name: "Second")
        let log = Log()
        log.failing = [doomed.dataStoreID]
        let model = makeModel(store, log)
        await model.deleteProfile(doomed.id)
        await model.deleteProfile(second.id)
        #expect(model.message == nil)
        #expect(try store.pendingStoreRemovals() == [doomed.dataStoreID])
    }

    @Test func aLaunchRetryNeverThrowsForStoresItDidNotRecord() async throws {
        let (store, _, _, doomed) = try fixture()
        let log = Log()
        log.failing = [doomed.dataStoreID]
        _ = try store.deleteProfile(doomed.id)
        try await removal(store, log).runPending() // reports nothing: it recorded nothing
        #expect(try store.pendingStoreRemovals() == [doomed.dataStoreID])
    }

    // MARK: - R1-M1 (b): one removal run at a time

    @Test func removalRunsOneAtATime() async throws {
        let (store, _, _, doomed) = try fixture()
        let log = Log()
        log.suspensions = 5
        let removal = removal(store, log)
        _ = try store.deleteProfile(doomed.id)
        async let first: Void = removal.runPending()
        async let second: Void = removal.runPending()
        _ = try await (first, second)
        #expect(log.mostActive == 1) // the second run waited for the first
        #expect(log.removed == [[doomed.dataStoreID]]) // and then found nothing left pending
        #expect(try store.pendingStoreRemovals().isEmpty)
    }

    // MARK: - R1-L2: failures after the rows are gone

    @Test func bookkeepingFailureAfterTheRowsAreGoneSaysDeleted() async throws {
        let (store, database, _, doomed) = try fixture()
        try await database.writer.write { db in
            try db.execute(sql: """
                CREATE TRIGGER refusePendingUpdate BEFORE UPDATE ON setting WHEN OLD.key = 'pendingStoreRemovals'
                BEGIN SELECT RAISE(ABORT, 'refused'); END
                """)
        }
        let model = makeModel(store, Log())
        await model.deleteProfile(doomed.id)
        #expect(try !store.profiles().contains { $0.id == doomed.id }) // the rows are gone
        #expect(model.message == DeletionCopy.websiteDataRemovedButNotNoted) // not "nothing was deleted", and not "the data stayed" either (R2-L4)
        #expect(model.message != DeletionCopy.websiteDataNotRemoved)
        #expect(model.message != StoreErrorText.fallback)
        #expect(try store.pendingStoreRemovals() == [doomed.dataStoreID]) // and the store is still promised for later
    }

    // MARK: - R1-L3: an unreadable pending list is kept

    @Test func anUnreadablePendingListIsPreservedNotOverwritten() async throws {
        let (store, database, keep, _) = try fixture()
        try await database.writer.write { db in
            try db.execute(sql: "INSERT INTO setting (key, value, modifiedAt) VALUES ('pendingStoreRemovals', 'not json', ?)", arguments: [Date()])
        }
        let container = try store.createContainer(profileID: keep.id, name: "C", colorHex: "#FF3B30")
        _ = try store.deleteContainer(container.id)
        #expect(try store.pendingStoreRemovals() == [container.dataStoreID])
        let kept = try await database.writer.read { db in
            try String.fetchOne(db, sql: "SELECT value FROM setting WHERE key = 'pendingStoreRemovals.unreadable'")
        }
        #expect(kept == "not json")
    }

    // MARK: - R1-L4: the promise and the row delete are one transaction

    @Test func aFailedPendingWriteRollsTheProfileDeleteBack() async throws {
        let (store, database, _, doomed) = try fixture()
        try await database.writer.write { db in
            try db.execute(sql: """
                CREATE TRIGGER refusePendingInsert BEFORE INSERT ON setting WHEN NEW.key = 'pendingStoreRemovals'
                BEGIN SELECT RAISE(ABORT, 'refused'); END
                """)
        }
        #expect(throws: (any Error).self) { try store.deleteProfile(doomed.id) }
        #expect(try store.profiles().contains { $0.id == doomed.id }) // control: the delete did not happen without its promise
        #expect(try store.pendingStoreRemovals().isEmpty)
    }

    @Test func aFailedPendingWriteRollsTheContainerDeleteBack() async throws {
        let (store, database, keep, _) = try fixture()
        let container = try store.createContainer(profileID: keep.id, name: "C", colorHex: "#FF3B30")
        try await database.writer.write { db in
            try db.execute(sql: """
                CREATE TRIGGER refusePendingInsert BEFORE INSERT ON setting WHEN NEW.key = 'pendingStoreRemovals'
                BEGIN SELECT RAISE(ABORT, 'refused'); END
                """)
        }
        #expect(throws: (any Error).self) { try store.deleteContainer(container.id) }
        #expect(try store.containers(profileID: keep.id).map(\.id) == [container.id])
    }

    // MARK: - R1-L1: a site write makes the listing re-read

    final class Flag: @unchecked Sendable { var fired = false }

    @Test func aSiteWriteInvalidatesTheWebsitesListing() throws {
        let (store, _, keep, _) = try fixture()
        let revision = StoreRevision()
        let model = makeModel(store, Log(), revision: revision)
        let writes = SiteSettingWrites(store: store, revision: revision)

        // Control: a write that does not go through `SiteSettingWrites` does not invalidate, so the checks below mean something.
        let quiet = Flag()
        withObservationTracking { _ = model.siteEntries(profileID: keep.id) } onChange: { quiet.fired = true }
        try store.setSiteValue(profileID: keep.id, host: "a.example", key: .zoom, 1.25)
        #expect(!quiet.fired)

        let zoom = Flag()
        withObservationTracking { _ = model.siteEntries(profileID: keep.id) } onChange: { zoom.fired = true }
        try writes.setValue(profileID: keep.id, host: "b.example", key: .zoom, 1.5)
        #expect(zoom.fired)

        let camera = Flag()
        withObservationTracking { _ = model.siteEntries(profileID: keep.id) } onChange: { camera.fired = true }
        try writes.setDecision(profileID: keep.id, host: "c.example", key: .camera, .deny)
        #expect(camera.fired)
        #expect(model.siteEntries(profileID: keep.id).map(\.host).sorted() == ["a.example", "b.example", "c.example"])
    }

    // MARK: - R1-BH5 and R1-BH6

    @Test func clearingTheMessageForgetsAnOlderPanesFailure() throws {
        let (store, _, keep, _) = try fixture()
        let model = makeModel(store, Log())
        model.renameProfile(keep.id, to: " ")
        #expect(model.message == StoreErrorText.message(for: StoreError.blankName))
        model.clearMessage(for: .profiles)
        #expect(model.message == nil)
    }

    @Test func websitesPickerStartsOnTheFrontWindowsProfile() throws {
        let (_, _, keep, work) = try fixture()
        let profiles = [keep, work]
        #expect(WebsiteProfileChoice.shown(chosen: nil, front: work.id, in: profiles) == work.id)
        #expect(WebsiteProfileChoice.shown(chosen: keep.id, front: work.id, in: profiles) == keep.id) // the user's own pick wins
        #expect(WebsiteProfileChoice.shown(chosen: nil, front: nil, in: profiles) == keep.id) // no browser window: the first
        #expect(WebsiteProfileChoice.shown(chosen: UUID(), front: UUID(), in: profiles) == keep.id) // stale IDs fall back too
        #expect(WebsiteProfileChoice.shown(chosen: nil, front: work.id, in: []) == nil)
    }

    // MARK: - R2-H1: a removed store is verified at the next launch

    @Test func aRemovedStoreMovesFromPendingToVerify() async throws {
        let (store, _, _, doomed) = try fixture()
        _ = try store.deleteProfile(doomed.id)
        try await removal(store, Log()).runPending()
        #expect(try store.pendingStoreRemovals().isEmpty)
        #expect(try store.storesToVerify() == [doomed.dataStoreID]) // not forgotten yet: the next launch checks the end state
    }

    @Test func aFailedStoreStaysPendingAndIsNotYetVerified() async throws {
        let (store, _, _, doomed) = try fixture()
        let log = Log()
        log.failing = [doomed.dataStoreID]
        _ = try store.deleteProfile(doomed.id)
        try await removal(store, log).runPending()
        #expect(try store.pendingStoreRemovals() == [doomed.dataStoreID])
        #expect(try store.storesToVerify().isEmpty)
    }

    @Test func verifyClearsWhatTheListingNoLongerHas() async throws {
        let (store, _, _, doomed) = try fixture()
        let log = Log()
        _ = try store.deleteProfile(doomed.id)
        let removal = removal(store, log)
        try await removal.runPending()
        log.removed = []
        try await removal.verifyAtLaunch(listing: { [] })
        #expect(try store.storesToVerify().isEmpty)
        #expect(try store.pendingStoreRemovals().isEmpty)
        #expect(log.removed.isEmpty) // nothing to remove again
    }

    @Test func verifyRemovesAgainWhatTheListingStillHas() async throws {
        let (store, _, _, doomed) = try fixture()
        let log = Log()
        _ = try store.deleteProfile(doomed.id)
        let removal = removal(store, log)
        try await removal.runPending()
        log.removed = []
        let id = doomed.dataStoreID
        try await removal.verifyAtLaunch(listing: { [id] })
        #expect(log.removed == [[id]]) // removed again
        #expect(try store.pendingStoreRemovals().isEmpty)
        #expect(try store.storesToVerify() == [id]) // and checked once more at the launch after
    }

    @Test func verifyKeepsAStillListedStorePendingWhenItsRemovalFails() async throws {
        let (store, _, _, doomed) = try fixture()
        let log = Log()
        _ = try store.deleteProfile(doomed.id)
        let removal = removal(store, log)
        try await removal.runPending()
        log.failing = [doomed.dataStoreID]
        let id = doomed.dataStoreID
        try await removal.verifyAtLaunch(listing: { [id] })
        #expect(try store.pendingStoreRemovals() == [id])
        #expect(try store.storesToVerify().isEmpty)
    }

    @Test func verifyNeverTouchesAStoreStaveDidNotRecord() async throws {
        let (store, _, keep, doomed) = try fixture()
        let log = Log()
        _ = try store.deleteProfile(doomed.id)
        let removal = removal(store, log)
        try await removal.runPending()
        log.removed = []
        let strangers = [UUID(), keep.dataStoreID] // a store nobody recorded, and a live profile's store
        try await removal.verifyAtLaunch(listing: { Set(strangers) })
        #expect(log.removed.isEmpty)
        #expect(try store.pendingStoreRemovals().isEmpty)
        #expect(try store.storesToVerify().isEmpty) // only the recorded one was cleared
    }

    @Test func verifyWithNothingRecordedNeverAsksTheListing() async throws {
        let (store, _, _, _) = try fixture()
        let log = Log()
        let asked = Flag()
        try await removal(store, log).verifyAtLaunch(listing: { asked.fired = true; return [] })
        #expect(!asked.fired)
        #expect(log.removed.isEmpty)
    }

    // MARK: - R2-L5: a removal that never answers

    @Test func aRemovalThatNeverAnswersTimesOutAndStaysPending() async throws {
        let (store, _, _, doomed) = try fixture()
        _ = try store.deleteProfile(doomed.id)
        let hanging = StoreRemoval(store: store, timeout: .milliseconds(50)) { _ in
            try? await Task.sleep(for: .seconds(3600))
            return [:]
        }
        var thrown: StoreRemovalError?
        do { try await hanging.runPending(reporting: [doomed.dataStoreID]) } catch let error as StoreRemovalError { thrown = error }
        #expect(thrown?.failures.keys.contains(doomed.dataStoreID) == true)
        #expect(try store.pendingStoreRemovals() == [doomed.dataStoreID]) // never forgotten
        #expect(try store.storesToVerify().isEmpty)
        // The next run is not stuck behind the hung one.
        try await removal(store, Log()).runPending()
        #expect(try store.storesToVerify() == [doomed.dataStoreID])
    }

    // MARK: - R2-L2: a late message stays on its own pane

    @Test func aQueuedDeletionsLateMessageLandsOnItsOwnPane() async throws {
        let (store, _, keep, doomed) = try fixture()
        let log = Log()
        log.failing = [doomed.dataStoreID]
        let model = makeModel(store, log)
        model.createContainer(profileID: keep.id, name: " ", colorHex: "#FF3B30") // a Containers failure first
        #expect(model.message(for: .containers) != nil)
        model.clearMessage(for: .containers) // the user moves on from Containers
        await model.deleteProfile(doomed.id) // the Profiles deletion answers after that
        #expect(model.message(for: .profiles) == DeletionCopy.websiteDataNotRemoved)
        #expect(model.message(for: .containers) == nil)
        #expect(model.message(for: .websites) == nil)
        model.clearMessage(for: .profiles) // leaving Profiles clears its own
        #expect(model.message(for: .profiles) == nil)
    }
}
