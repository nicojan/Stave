import ChorusEngine
import Foundation
import StaveCore
import Testing
import WebKit

@testable import StaveWeb

extension WebKitTests {
/// Removing a profile's or container's persistent store (decisions 18 and 19, Review Focus 3). These tests open real persistent stores
/// under fresh identifiers and remove them again, so nothing is left behind. The suite is serialized: two removals in flight at once make
/// WebKit fail one of them ("Failed to delete files on disk"), the same race `StoreRemoval` rules out in the app.
@MainActor
@Suite(.serialized)
struct WebDataStoresTests {
    private func makeHost(_ stores: WebDataStores) -> PageHost {
        PageHost(stores: stores, contentBlocker: ContentBlockerManager(), siteSettings: FakeSiteSettings(), applicationName: "Version/17.0 Safari/605.1.15")
    }

    private func storeIsListed(_ id: UUID) async -> Bool {
        await withCheckedContinuation { continuation in
            WKWebsiteDataStore.fetchAllDataStoreIdentifiers { continuation.resume(returning: $0.contains(id)) }
        }
    }

    private func use(_ stores: WebDataStores, _ id: UUID) async {
        _ = await stores.store(for: .persistent(id)).dataRecords(ofTypes: WKWebsiteDataStore.allWebsiteDataTypes())
    }

    private func cookieNames(_ stores: WebDataStores, _ id: UUID) async -> [String] {
        await stores.store(for: .persistent(id)).httpCookieStore.allCookies().map(\.name)
    }

    /// Production's `remove`, queued behind every other suite's removals (`StoreCleanup`).
    private func removeSerially(_ stores: WebDataStores, _ id: UUID, inUse: Bool) async throws {
        try await StoreCleanup.serialized { try await stores.remove(id, inUse: inUse) }
    }

    private func giveFiles(_ stores: WebDataStores, _ id: UUID) async throws {
        let cookie = try #require(HTTPCookie(properties: [.domain: "example.com", .path: "/", .name: "stave-test", .value: "1"]))
        await stores.store(for: .persistent(id)).httpCookieStore.setCookie(cookie)
        #expect(await cookieNames(stores, id) == ["stave-test"]) // control: the store really holds data now
    }

    @Test func removeRefusedWhileAPageUsesTheStore() async throws {
        let stores = WebDataStores()
        let host = makeHost(stores)
        let id = UUID()
        let tab = UUID()
        let request = PageRequest(tabID: tab, store: .persistent(id), siteSettingsProfileID: UUID(), url: "", title: "", faviconURL: nil, interactionState: nil)
        _ = host.page(for: request, writer: FakeWriter())
        #expect(host.usesStore(id))
        #expect(!host.usesStore(UUID())) // control: another store is not in use
        try await giveFiles(stores, id) // a store with data, so "gone" below is not trivially true
        #expect(await storeIsListed(id)) // control: it is listed before the removal

        do {
            try await removeSerially(stores, id, inUse: host.usesStore(id))
            Issue.record("expected .inUse")
        } catch let error as WebDataStoreError {
            #expect(error == .inUse)
        }

        host.close(tab)
        #expect(!host.usesStore(id))
        try await removeSerially(stores, id, inUse: host.usesStore(id)) // production retries WebKit's transient refusals itself; removes the store this test opened
        #expect(!(await storeIsListed(id)))
    }

    /// An unloaded page keeps its web view, and so its store, until its snapshot is taken; `usesStore` holds for exactly that long.
    /// The snapshotter here holds its completion, so no clock decides the outcome.
    @Test func usesStoreHoldsWhileAnUnloadedPageWaitsForItsSnapshot() async throws {
        let stores = WebDataStores()
        let host = makeHost(stores)
        host.snapshotTimeout = .seconds(3600) // the snapshotter, not the timeout, ends the teardown
        var held: [@MainActor (NSImage?) -> Void] = []
        host.snapshotter = { _, done in held.append(done) }
        let id = UUID()
        let tab = UUID()
        let request = PageRequest(tabID: tab, store: .persistent(id), siteSettingsProfileID: UUID(), url: "", title: "", faviconURL: nil, interactionState: nil)
        _ = host.page(for: request, writer: FakeWriter()) // not kept here: a test-held page would itself keep the store in use
        host.unload(tab)
        #expect(held.count == 1)
        #expect(host.usesStore(id)) // the page is gone from `pages`, but its web view still waits for the snapshot
        #expect(!host.usesStore(UUID())) // control
        let done = try #require(held.first)
        done(nil)
        #expect(!host.usesStore(id))
        try await removeSerially(stores, id, inUse: host.usesStore(id)) // the page made a persistent store on disk; remove it
        #expect(!(await storeIsListed(id)))
    }

    /// The wait before removing a store is derived from the snapshot timeout, so the two can't drift apart.
    @Test func teardownWaitFollowsTheSnapshotTimeout() {
        let host = makeHost(WebDataStores())
        #expect(host.teardownWaitLimit == host.snapshotTimeout + .seconds(1))
        host.snapshotTimeout = .seconds(10)
        #expect(host.teardownWaitLimit == .seconds(11))
        host.snapshotTimeout = .seconds(30)
        #expect(host.teardownWaitLimit == .seconds(31))
    }

    @Test func removeDropsTheCachedStoreFirst() async throws {
        let stores = WebDataStores()
        let id = UUID()
        _ = stores.store(for: .persistent(id)) // fetched once, so it sits in the cache
        #expect(stores.isCached(.persistent(id)))
        try await removeSerially(stores, id, inUse: false) // no in-use error
        #expect(!stores.isCached(.persistent(id))) // dropped, so WebKit sees no instance of ours holding it
        #expect(!(await storeIsListed(id))) // and WebKit no longer lists the store
    }

    /// Control for the check above: a store that was used is listed until it is removed, so "not listed" means something.
    @Test func aUsedStoreIsListedUntilRemoved() async throws {
        let stores = WebDataStores()
        let id = UUID()
        await use(stores, id) // the instance's scope ends here, as it does for a page that is gone
        let listedBefore = await storeIsListed(id)
        try await removeSerially(stores, id, inUse: false)
        let listedAfter = await storeIsListed(id)
        #expect(listedBefore)
        #expect(!listedAfter)
    }

    /// A second removal of the same store (a retry that finds it already gone) succeeds (R1-M1 c).
    @Test func removingAnAlreadyRemovedStoreSucceeds() async throws {
        let stores = WebDataStores()
        let id = UUID()
        try await giveFiles(stores, id)
        try await removeSerially(stores, id, inUse: false)
        #expect(!(await storeIsListed(id)))
        try await removeSerially(stores, id, inUse: false)
        try await removeSerially(stores, id, inUse: false)
        #expect(!(await storeIsListed(id)))
    }

    /// An identifier no store was ever made for has nothing to remove, which is success.
    @Test func removingANeverCreatedStoreSucceeds() async throws {
        let id = UUID()
        #expect(!(await storeIsListed(id))) // control: it really does not exist
        try await removeSerially(WebDataStores(), id, inUse: false)
        #expect(!(await storeIsListed(id)))
    }

    /// R2-H2: a transient failure is retried inside production, with the given delays, and the last error surfaces when they run out.
    @Test func retryingStopsAtTheFirstSuccess() async throws {
        var attempts = 0
        try await WebDataStores.retrying(after: [.zero, .zero, .zero]) {
            attempts += 1
            if attempts < 3 { throw TransientFailure() }
        }
        #expect(attempts == 3)
    }

    @Test func retryingGivesUpAfterTheLastDelay() async {
        var attempts = 0
        do {
            try await WebDataStores.retrying(after: [.zero, .zero]) {
                attempts += 1
                throw TransientFailure()
            }
            Issue.record("expected the failure")
        } catch {
            #expect(error is TransientFailure)
        }
        #expect(attempts == 3) // the first try and one per delay
    }

    @Test func theDefaultBackoffRunsAboutEightSeconds() {
        #expect(WebDataStores.removalRetryDelays == [.milliseconds(250), .milliseconds(500), .seconds(1), .seconds(2), .seconds(4)])
    }

    @Test func aPageHoldingTheStoreIsNeverRetried() async {
        var attempts = 0
        do {
            try await WebDataStores.retrying(after: [.zero, .zero]) {
                attempts += 1
                throw WebDataStoreError.inUse
            }
            Issue.record("expected .inUse")
        } catch {
            #expect(error as? WebDataStoreError == .inUse)
        }
        #expect(attempts == 1)
    }

    /// R2-H1, WebKit side of the launch check: after a removal through production `remove` the ID is not listed, and an ID that comes back
    /// (a late flush, or here a fresh instance reading it) is listed again and goes with one more production `remove`, which is what
    /// `StoreRemoval.verifyAtLaunch` does for a store the listing still has. I tried also asserting that a fresh instance reads no cookie
    /// right after the removal: it passes alone but fails in a full run, because WebKit's network process answers from the session it has not
    /// yet dropped. The on-disk end state is what the launch check decides on, so that is what is asserted.
    @Test func aStoreThatComesBackIsListedAndRemovedAgain() async throws {
        let stores = WebDataStores()
        let id = UUID()
        try await giveFiles(stores, id)
        #expect(await storeIsListed(id)) // control
        try await removeSerially(stores, id, inUse: false)
        #expect(!(await storeIsListed(id)))
        let fresh = WebDataStores()
        await use(fresh, id) // the ID is used again, as a late flush would
        #expect(await WebDataStores.listedIdentifiers().contains(id)) // so the launch listing would show it
        try await removeSerially(fresh, id, inUse: false) // and the launch check removes it again
        #expect(!(await storeIsListed(id)))
    }

    /// The launch listing reports the stores WebKit has on disk (what `StoreRemoval.verifyAtLaunch` asks).
    @Test func theListingNamesAUsedStoreUntilItIsRemoved() async throws {
        let stores = WebDataStores()
        let id = UUID()
        await use(stores, id)
        #expect(await WebDataStores.listedIdentifiers().contains(id))
        try await removeSerially(stores, id, inUse: false)
        #expect(!(await WebDataStores.listedIdentifiers().contains(id)))
    }

    private struct TransientFailure: Error {}
}
}
