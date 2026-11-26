import Foundation
import Testing
import WebKit

@testable import StaveWeb

/// Removes the persistent stores the WebKit tests open. WebKit fails a removal that overlaps another ("Failed to delete files on disk"), and
/// the suites run in parallel, so every removal from every suite goes through one queue (R2-M1). Removal itself is production's
/// `WebDataStores.remove`, with its own retry; nothing here polls.
@MainActor
enum StoreCleanup {
    private static var tail: Task<Void, Never>?

    /// Runs `work` after every earlier call has finished.
    static func serialized<T: Sendable>(_ work: @escaping @MainActor () async throws -> T) async throws -> T {
        let previous = tail
        let run = Task { @MainActor () async throws -> T in
            await previous?.value
            return try await work()
        }
        tail = Task { _ = await run.result }
        return try await run.value
    }

    /// Runs `body` with a fresh profile ID, then removes that profile's store. The test's pages and host are locals of `body`, so they are
    /// released when it returns; a local of the test itself would keep the store in use and make the removal fail (R2-M1).
    static func withProfile(_ body: (UUID) async throws -> Void) async throws {
        let profile = UUID()
        try await body(profile)
        await remove([profile])
    }

    /// Runs `body`, then removes the stores of `ids`, which `body` opened. Everything `body` made is released when it returns.
    static func scoped(_ ids: [UUID], _ body: () async throws -> Void) async throws {
        try await body()
        await remove(ids)
    }

    /// How many removals a store gets before it counts as left behind.
    private static let removalPasses = 3

    /// Removes each store and records an issue unless it really is gone afterwards. A store a test only created has no files yet, and WebKit
    /// can make them after a removal that came first (seen on macos-15), so the store is listed again; one more removal clears it, as the
    /// launch check (`StoreRemoval.verifyAtLaunch`) does in the app. The store must be gone after the last pass.
    static func remove(_ ids: [UUID]) async {
        for id in ids {
            var listed = true
            for _ in 0..<removalPasses where listed {
                do {
                    try await serialized { try await WebDataStores().remove(id, inUse: false) }
                } catch {
                    Issue.record("could not remove the test store \(id): \(error)")
                }
                listed = await isListed(id)
            }
            #expect(!listed, "the test store \(id) is still listed after its removal")
        }
    }

    private static func isListed(_ id: UUID) async -> Bool {
        await withCheckedContinuation { continuation in
            WKWebsiteDataStore.fetchAllDataStoreIdentifiers { continuation.resume(returning: $0.contains(id)) }
        }
    }
}
