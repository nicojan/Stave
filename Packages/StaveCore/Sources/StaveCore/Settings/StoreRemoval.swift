import Foundation

/// Some website data stores could not be removed, or the list of pending removals could not be kept. The rows they belonged to are already
/// gone; the stores stay in the pending list and are retried at the next launch or deletion. Only a failure after the rows are gone is this
/// error type, so a failure to delete rows is never reported as "deleted, but…" (H1, R1-L2).
public struct StoreRemovalError: Error {
    /// Each store of the reported deletion that stayed, with why.
    public let failures: [UUID: any Error]
    /// Set when the pending list itself could not be read or updated after the deletion.
    public let bookkeeping: (any Error)?
    /// True when the stores went from disk and only noting that down failed (R2-L4); false when the list could not be read, so nothing ran.
    public let storesWereRemoved: Bool

    public init(failures: [UUID: any Error], bookkeeping: (any Error)? = nil, storesWereRemoved: Bool = false) {
        self.failures = failures
        self.bookkeeping = bookkeeping
        self.storesWereRemoved = storesWereRemoved
    }

    /// The failure came only from the pending list after every store was removed.
    public var isBookkeepingOnly: Bool { failures.isEmpty && bookkeeping != nil && storesWereRemoved }
}

/// A removal run that did not answer within its limit (R2-L5).
struct StoreRemovalTimedOut: Error {}

/// Resumes a continuation once, whichever of the work and its timer comes first.
@MainActor
private final class FirstAnswer {
    private var continuation: CheckedContinuation<[UUID: any Error], Never>?
    var timer: Task<Void, Never>?
    init(_ continuation: CheckedContinuation<[UUID: any Error], Never>) { self.continuation = continuation }
    func finish(_ result: [UUID: any Error]) {
        guard let continuation else { return }
        self.continuation = nil
        timer?.cancel()
        continuation.resume(returning: result)
    }
}

/// Removing the website data stores of deleted profiles and containers, and keeping the promise to do so (H2). The IDs are recorded in
/// the transaction that deletes the rows (`OrganizationStore.pendingStoreRemovals`); a store that was busy is retried by the next deletion or
/// the next launch. A removal WebKit calls successful is not yet trusted (a late cookie flush can recreate files): the ID moves to a "to
/// verify" list, and the next launch (`verifyAtLaunch`) forgets it only when WebKit no longer lists the store, removing it again otherwise.
/// It never sweeps stores against rows, only IDs it recorded: restoring an older backup would otherwise delete the store of a newer profile.
///
/// One instance serves the whole app, and its runs are serialized: a second run waits for the first, so two removals never race on one
/// store (R1-M1).
@MainActor
public final class StoreRemoval {
    private let store: OrganizationStore
    private let remove: @MainActor ([UUID]) async -> [UUID: any Error]
    /// The most recently queued run; the next one waits for it.
    private var tail: Task<Void, Never>?
    private let timeout: Duration

    /// `remove` tries to remove every store it is given and returns the failures only, by ID (empty when all went). A run that has not
    /// answered after `timeout` counts as failed for every store it was given, which stay pending, so one callback that never returns can't
    /// stall every later deletion.
    public init(store: OrganizationStore, timeout: Duration = .seconds(120), remove: @escaping @MainActor ([UUID]) async -> [UUID: any Error]) {
        self.store = store
        self.timeout = timeout
        self.remove = remove
    }

    /// Removes every pending store and clears each one that went. Older pending stores are retried quietly (a failure is logged, never
    /// blamed on this run); only a failure of a store in `reporting`, the IDs the calling deletion just recorded, throws `StoreRemovalError`,
    /// as does a failure to read or update the pending list itself.
    public func runPending(reporting: Set<UUID> = []) async throws {
        try await queued { [self] in await runNow(reporting: reporting) }
    }

    /// The launch check: every store on the "to verify" list that WebKit still lists is removed again (it goes back to pending, and stays
    /// there if that fails); every one it no longer lists is forgotten. Then what is pending is retried, as `runPending` does. `listing`
    /// is asked only when something is recorded, and only recorded IDs are acted on, whatever else it lists. Reports nothing but a failure
    /// to read or update the lists.
    public func verifyAtLaunch(listing: @escaping @MainActor () async -> Set<UUID>) async throws {
        try await queued { [self] in
            if let error = await verifyNow(listing: listing) { return error }
            return await runNow(reporting: [])
        }
    }

    private func queued(_ work: @escaping @MainActor () async -> StoreRemovalError?) async throws {
        let previous = tail
        let run = Task { @MainActor () -> StoreRemovalError? in
            await previous?.value
            return await work()
        }
        tail = Task { _ = await run.value }
        if let error = await run.value { throw error }
    }

    private func verifyNow(listing: @MainActor () async -> Set<UUID>) async -> StoreRemovalError? {
        do {
            let recorded = try store.storesToVerify()
            guard !recorded.isEmpty else { return nil }
            let listed = await listing()
            let again = recorded.filter { listed.contains($0) }
            if !again.isEmpty { NSLog("Stave: \(again.count) removed website data store(s) are still listed by WebKit; removing again") }
            try store.storesVerified(clear: recorded.filter { !listed.contains($0) }, again: again)
            return nil
        } catch {
            return StoreRemovalError(failures: [:], bookkeeping: error)
        }
    }

    private func runNow(reporting: Set<UUID>) async -> StoreRemovalError? {
        let ids: [UUID]
        do { ids = try store.pendingStoreRemovals() } catch { return StoreRemovalError(failures: [:], bookkeeping: error) }
        guard !ids.isEmpty else { return nil }
        let failures = await removeWithinLimit(ids)
        let quiet = failures.filter { !reporting.contains($0.key) }
        if !quiet.isEmpty { NSLog("Stave: \(quiet.count) older website data store(s) are still on disk and stay pending: \(quiet.values)") }
        let reported = failures.filter { reporting.contains($0.key) }
        do {
            try store.storesRemoved(ids.filter { failures[$0] == nil })
        } catch {
            return StoreRemovalError(failures: reported, bookkeeping: error, storesWereRemoved: true)
        }
        return reported.isEmpty ? nil : StoreRemovalError(failures: reported)
    }

    /// `remove`'s failures, or a timeout for every ID when it doesn't answer within the limit (the late answer is then ignored).
    private func removeWithinLimit(_ ids: [UUID]) async -> [UUID: any Error] {
        await withCheckedContinuation { (continuation: CheckedContinuation<[UUID: any Error], Never>) in
            let answer = FirstAnswer(continuation)
            let limit = timeout
            let timedOut = Dictionary(uniqueKeysWithValues: ids.map { ($0, StoreRemovalTimedOut() as any Error) })
            answer.timer = Task { @MainActor in
                try? await Task.sleep(for: limit)
                answer.finish(timedOut)
            }
            let work = remove
            Task { @MainActor in answer.finish(await work(ids)) }
        }
    }
}
