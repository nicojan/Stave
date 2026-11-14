import Foundation
import StaveCore
import Testing
import WebKit

@testable import StaveWeb

/// Clear History's "Also remove cookies and website data" through WebKit (question 16, answered 2026-11-14). Only non-persistent stores are
/// used here, so no test opens a store on disk.
@MainActor
struct WebsiteDataRemoverTests {
    private func cookie(_ name: String) throws -> HTTPCookie {
        try #require(HTTPCookie(properties: [
            .name: name, .value: "1", .domain: "example.com", .path: "/",
            .expires: Date().addingTimeInterval(86_400),
        ]))
    }

    private func names(in store: WKWebsiteDataStore) async -> [String] {
        await store.httpCookieStore.allCookies().map(\.name).sorted()
    }

    /// The listed store loses its cookies; a store not in the list keeps its own. Each store is asked for as a persistent key, never a
    /// private session's.
    @Test func removesOnlyTheListedStores() async throws {
        let listedID = UUID()
        let otherID = UUID()
        let listed = WKWebsiteDataStore.nonPersistent()
        let other = WKWebsiteDataStore.nonPersistent()
        await listed.httpCookieStore.setCookie(try cookie("listed"))
        await other.httpCookieStore.setCookie(try cookie("other"))
        #expect(await names(in: listed) == ["listed"]) // the control: the cookie is really there before the removal
        #expect(await names(in: other) == ["other"])

        var asked: [DataStoreKey] = []
        let stores: [DataStoreKey: WKWebsiteDataStore] = [.persistent(listedID): listed, .persistent(otherID): other]
        let remover = WebsiteDataRemover { key in
            asked.append(key)
            return stores[key] ?? .nonPersistent()
        }
        try await remover.removeWebsiteData(storeIDs: [listedID], since: .distantPast)

        #expect(asked == [.persistent(listedID)])
        #expect(await names(in: listed).isEmpty)
        #expect(await names(in: other) == ["other"])
    }

    @Test func keysArePersistent() {
        let ids = [UUID(), UUID()]
        #expect(WebsiteDataRemover.keys(forStoreIDs: ids) == ids.map { DataStoreKey.persistent($0) })
    }
}
