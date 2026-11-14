import Foundation
import StaveCore
import WebKit

/// Clear History's "Also remove cookies and website data" (question 16, answered 2026-11-14): removes every data type modified since the
/// range's start from each listed persistent store, with `WKWebsiteDataStore.removeData(ofTypes:modifiedSince:)`. WebKit does the work in
/// its own processes; the main thread only asks. The list comes from `OrganizationStore.websiteDataStoreIDs(profileID:)`, so a private
/// session's store (never in it) is never touched.
@MainActor
public final class WebsiteDataRemover: WebsiteDataRemoving {
    private let store: (DataStoreKey) -> WKWebsiteDataStore

    /// `store` gives the store for a key: `WebDataStores.store(for:)` in the app, a non-persistent store in tests.
    public init(store: @escaping (DataStoreKey) -> WKWebsiteDataStore) {
        self.store = store
    }

    public convenience init(stores: WebDataStores) {
        self.init { [unowned stores] key in stores.store(for: key) }
    }

    /// The data store keys of `dataStoreID`s: each is a profile's or container's persistent store.
    public static func keys(forStoreIDs ids: [UUID]) -> [DataStoreKey] {
        ids.map { .persistent($0) }
    }

    /// WebKit's removal reports no error of its own; it finishes when the data is gone.
    public func removeWebsiteData(storeIDs: [UUID], since: Date) async throws {
        for key in Self.keys(forStoreIDs: storeIDs) {
            await store(key).removeData(ofTypes: WKWebsiteDataStore.allWebsiteDataTypes(), modifiedSince: since)
        }
    }
}
