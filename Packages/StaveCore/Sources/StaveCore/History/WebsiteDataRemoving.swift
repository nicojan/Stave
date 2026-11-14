import Foundation

/// Removes website data (cookies, caches, local storage and the rest) from persistent website data stores, for Clear History's
/// "Also remove cookies and website data" (question 16, answered 2026-11-14). StaveWeb's `WebsiteDataRemover` does it with WebKit; tests
/// use a fake. StaveCore never sees WebKit.
@MainActor
public protocol WebsiteDataRemoving: AnyObject {
    /// Removes the data of every type modified at or after `since` from each store named by its `dataStoreID`. Throws when it could not.
    func removeWebsiteData(storeIDs: [UUID], since: Date) async throws
}
