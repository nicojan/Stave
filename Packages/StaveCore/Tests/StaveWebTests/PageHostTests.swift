import AppKit
import ChorusEngine
import Foundation
import StaveCore
import Testing
import WebKit

@testable import StaveWeb

@MainActor
final class FakeWriter: PageWriter {
    enum Call: Equatable {
        case navigation(tabID: UUID, url: String, title: String, faviconURL: String?)
        case interactionState(tabID: UUID, hasData: Bool)
        case visit(profileID: UUID, url: String)
        case visitTitle(profileID: UUID, url: String, title: String)
    }

    var calls: [Call] = []
    var onNavigation: ((String) -> Void)?

    func writeNavigation(tabID: UUID, url: String, title: String, faviconURL: String?) {
        onNavigation?(url)
        calls.append(.navigation(tabID: tabID, url: url, title: title, faviconURL: faviconURL))
    }

    func writeInteractionState(tabID: UUID, _ state: Data?) {
        calls.append(.interactionState(tabID: tabID, hasData: state != nil))
    }

    func recordVisit(profileID: UUID, url: String, title: String, at: Date) {
        calls.append(.visit(profileID: profileID, url: url))
    }

    func updateVisitTitle(profileID: UUID, url: String, title: String) {
        calls.append(.visitTitle(profileID: profileID, url: url, title: title))
    }

    var visits: [Call] {
        calls.filter { if case .visit = $0 { true } else { false } }
    }

    var stateWrites: Int {
        calls.filter { if case .interactionState = $0 { true } else { false } }.count
    }
}

@MainActor
final class FakeSiteSettings: SiteSettingsSource {
    var values: [String: SiteDecision] = [:]

    func decision(profileID: UUID, host: String, key: SiteSettingKey) -> SiteDecision? {
        values["\(profileID)|\(host)|\(key.rawValue)"]
    }

    func setDecision(profileID: UUID, host: String, key: SiteSettingKey, _ d: SiteDecision?) {
        values["\(profileID)|\(host)|\(key.rawValue)"] = d
    }

    /// Site values as the store keeps them (JSON text), and every write in order (nil for a removal).
    var siteValues: [String: Data] = [:]
    var siteValueWrites: [(key: String, value: Data?)] = []

    func siteValue<V: Codable>(profileID: UUID, host: String, key: SiteValueKey, as type: V.Type) -> V? {
        siteValues["\(profileID)|\(host)|\(key.rawValue)"].flatMap { try? JSONDecoder().decode(V.self, from: $0) }
    }

    func setSiteValue<V: Codable>(profileID: UUID, host: String, key: SiteValueKey, _ value: V?) {
        let name = "\(profileID)|\(host)|\(key.rawValue)"
        let data = value.flatMap { try? JSONEncoder().encode($0) }
        siteValues[name] = data
        siteValueWrites.append((name, data))
    }

    /// Each `removeSite` call, as (profile, host), and what it takes: every decision and value under that profile and host.
    var removedSites: [String] = []

    func removeSite(profileID: UUID, host: String) {
        removedSites.append("\(profileID)|\(host)")
        let prefix = "\(profileID)|\(host)|"
        values = values.filter { !$0.key.hasPrefix(prefix) }
        siteValues = siteValues.filter { !$0.key.hasPrefix(prefix) }
    }

    func zoom(profileID: UUID, host: String) -> Double? {
        siteValue(profileID: profileID, host: host, key: .zoom, as: Double.self)
    }
}

@MainActor
final class TestClock {
    var date = Date(timeIntervalSinceReferenceDate: 800_000_000)
}

@MainActor
@Suite("Page host")
struct PageHostTests {
    let clock = TestClock()
    let writer = FakeWriter()
    let settings = FakeSiteSettings()
    /// The stores of every host made here unless a test passes its own; a private page's session is joined here (a `.privateSession` ID
    /// must name a joined session).
    let sharedStores = WebDataStores()

    func makeHost(stores: WebDataStores? = nil) -> PageHost {
        let clock = clock
        let stores = stores ?? sharedStores
        return PageHost(
            stores: stores,
            contentBlocker: ContentBlockerManager(),
            siteSettings: settings,
            applicationName: "Version/17.0 Safari/605.1.15",
            now: { clock.date }
        )
    }

    func request(_ tabID: UUID = UUID(), url: String, state: Data? = nil) -> PageRequest {
        PageRequest(tabID: tabID, store: .privateSession(sharedStores.joinPrivateSession(profileID: UUID())), siteSettingsProfileID: nil, url: url, title: "", faviconURL: nil, interactionState: state)
    }

    /// Polls on the main actor without blocking it.
    func waitUntil(seconds: Double = 20, _ condition: () -> Bool) async throws -> Bool {
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline {
            if condition() { return true }
            try await Task.sleep(for: .milliseconds(50))
        }
        // The main thread can stall past the deadline on a loaded CI runner; let the main-actor work queued meanwhile run before the last look.
        try await Task.sleep(for: .milliseconds(50))
        return condition()
    }

    func loadLocal(_ page: LivePage, html: String, base: String) async throws -> Bool {
        page.webView.loadHTMLString(html, baseURL: URL(string: base))
        return try await waitUntil {
            page.webView.url?.absoluteString == base && !page.webView.isLoading && !page.status.isLoading
        }
    }

    // MARK: Stores

    @Test func storesFollowProfileContainerAndPrivate() async throws {
        let a = UUID(), b = UUID(), w = UUID()
        try await StoreCleanup.scoped([a, b]) {
            let stores = WebDataStores()
            let storeA = stores.store(for: .persistent(a))
            #expect(storeA.isPersistent)
            #expect(storeA.identifier == a)
            let storeB = stores.store(for: .persistent(b))
            #expect(storeB !== storeA)
            #expect(storeB.identifier == b)
            #expect(stores.store(for: .persistent(a)) === storeA)
            #expect(!stores.store(for: .privateSession(stores.joinPrivateSession(profileID: w))).isPersistent)
        }
    }

    /// Private windows of a profile share one throwaway session, as in Chrome and Firefox, for as long as one of them is open.
    @Test func privateWindowsOfAProfileShareOneStoreWhileAnyIsOpen() {
        let stores = WebDataStores()
        let profile = UUID()
        let first = stores.joinPrivateSession(profileID: profile)
        let second = stores.joinPrivateSession(profileID: profile)
        #expect(first == second)
        let shared = stores.store(for: .privateSession(first))
        #expect(!shared.isPersistent)
        #expect(stores.store(for: .privateSession(second)) === shared)
        // One window closes: the other keeps the session.
        #expect(!stores.leavePrivateSession(profileID: profile))
        #expect(stores.store(for: .privateSession(first)) === shared)
    }

    @Test func afterTheLastPrivateWindowClosesTheNextOneGetsANewStore() {
        let stores = WebDataStores()
        let profile = UUID()
        let first = stores.joinPrivateSession(profileID: profile)
        let old = stores.store(for: .privateSession(first))
        #expect(stores.leavePrivateSession(profileID: profile))
        let next = stores.joinPrivateSession(profileID: profile)
        #expect(next != first)
        #expect(stores.store(for: .privateSession(next)) !== old)
        // A stray window that leaves a session nobody joined changes nothing.
        #expect(stores.leavePrivateSession(profileID: UUID()))
        #expect(stores.store(for: .privateSession(next)) !== old)
    }

    @Test func privateSessionsOfDifferentProfilesAreSeparate() {
        let stores = WebDataStores()
        let a = stores.joinPrivateSession(profileID: UUID())
        let b = stores.joinPrivateSession(profileID: UUID())
        #expect(a != b)
        #expect(stores.store(for: .privateSession(a)) !== stores.store(for: .privateSession(b)))
    }

    @Test func privateSessionNeverSharesAPersistentProfileOrContainerStore() async throws {
        let profile = UUID(), container = UUID()
        try await StoreCleanup.scoped([profile, container]) {
            let stores = WebDataStores()
            let session = stores.joinPrivateSession(profileID: profile)
            let shared = stores.store(for: .privateSession(session))
            for key in [DataStoreKey.persistent(profile), .persistent(container)] {
                let persistent = stores.store(for: key)
                #expect(persistent !== shared)
                #expect(persistent.isPersistent)
            }
            #expect(!shared.isPersistent)
        }
    }

    @Test func noDefaultStoreEver() async throws {
        let p = UUID()
        try await StoreCleanup.scoped([p]) {
            let stores = WebDataStores()
            let made = [stores.store(for: .persistent(p)), stores.store(for: .privateSession(stores.joinPrivateSession(profileID: UUID())))]
            let defaultStore = WKWebsiteDataStore.default()
            for store in made {
                #expect(store !== defaultStore)
                #expect(!(store.isPersistent && store.identifier == nil))
            }
        }
    }

    // MARK: Loading

    @Test func hostileStoredURLNeverLoads() async throws {
        let host = makeHost()
        let page = host.page(for: request(url: "javascript:alert(1)"), writer: writer)
        #expect(page.status.failure == .refused(url: "javascript:alert(1)"))
        try await Task.sleep(for: .milliseconds(500))
        #expect(page.webView.url == nil)
        #expect(writer.calls.isEmpty)
        host.close(page.tabID)
    }

    @Test func blankTabMakesNoLoad() async throws {
        let host = makeHost()
        let page = host.page(for: request(url: ""), writer: writer)
        try await Task.sleep(for: .milliseconds(500))
        #expect(page.webView.url == nil)
        #expect(page.status.failure == nil)
        #expect(!page.didRestoreState)
        host.close(page.tabID)
    }

    @Test func samePageForSameTab() {
        let host = makeHost()
        let tabID = UUID()
        let first = host.page(for: request(tabID, url: ""), writer: writer)
        #expect(host.page(for: request(tabID, url: ""), writer: writer) === first)
        #expect(host.existingPage(tabID) === first)
        host.close(tabID)
        #expect(host.existingPage(tabID) == nil)
    }

    /// A rule list that blocks every load, so a restored page never reaches the network.
    func blockAllRuleList() async throws -> WKContentRuleList {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("StaveRuleLists-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = try #require(WKContentRuleListStore(url: dir))
        let list = try await store.compileContentRuleList(forIdentifier: "blockAll", encodedContentRuleList: #"[{"trigger":{"url-filter":".*"},"action":{"type":"block"}}]"#)
        return try #require(list)
    }

    /// Page A's state, from a simulated (network-free) load, so it has a real back/forward item.
    func savedState(of host: PageHost, url: String, html: String) async throws -> Data {
        let a = host.page(for: request(url: ""), writer: writer)
        a.webView.loadSimulatedRequest(URLRequest(url: try #require(URL(string: url))), responseHTML: html)
        let loaded = try await waitUntil { a.webView.url?.absoluteString == url && !a.webView.isLoading }
        #expect(loaded)
        #expect(a.webView.backForwardList.currentItem?.url.absoluteString == url)
        let state = try #require(a.webView.interactionState as? Data)
        host.close(a.tabID)
        return state
    }

    @Test func restoreUsesInteractionState() async throws {
        let host = makeHost()
        host.testRuleLists = [try await blockAllRuleList()]
        let aURL = "https://example.com/a"
        let state = try await savedState(of: host, url: aURL, html: "<title>A</title>")
        writer.calls.removeAll()

        let b = host.page(for: request(url: "https://example.invalid", state: state), writer: writer)
        #expect(b.didRestoreState)
        #expect(b.status.failure == nil)
        #expect(b.webView.backForwardList.currentItem?.url.absoluteString == aURL)
        var seen: Set<String> = []
        let deadline = Date().addingTimeInterval(0.5)
        while Date() < deadline {
            if let host = b.webView.url?.host { seen.insert(host) }
            try await Task.sleep(for: .milliseconds(20))
        }
        #expect(!seen.contains("example.invalid"))
        #expect(!b.webView.backForwardList.backList.contains { $0.url.host == "example.invalid" })
        #expect(b.webView.backForwardList.currentItem?.url.absoluteString == aURL)
        host.close(b.tabID)
    }

    @Test func restoredHostileStateIsRefused() async throws {
        let host = makeHost()
        let a = host.page(for: request(url: ""), writer: writer)
        // A local `data:` page, the shape an imported or tampered state could carry. Stave's delegate
        // refuses a data: main frame, so the state is made without it.
        a.webView.navigationDelegate = nil
        let dataURL = "data:text/html,%3Ctitle%3EA%3C/title%3E"
        a.webView.load(URLRequest(url: try #require(URL(string: dataURL))))
        let loaded = try await waitUntil { a.webView.title == "A" && !a.webView.isLoading }
        #expect(loaded)
        let state = try #require(a.webView.interactionState as? Data)
        host.close(a.tabID)
        writer.calls.removeAll()

        let b = host.page(for: request(url: "https://example.com/", state: state), writer: writer)
        #expect(b.didRestoreState)
        #expect(b.status.failure == .refused(url: dataURL))
        // Waited for rather than slept for: on a loaded runner WebKit's `isLoading` change can take longer than a fixed pause.
        #expect(try await waitUntil { !b.webView.isLoading })
        #expect(b.webView.title != "A")
        #expect(b.status.failure == .refused(url: dataURL))
        #expect(writer.calls.isEmpty)
        host.close(b.tabID)
    }

    // MARK: Writes

    /// Also proves the favicon script runs in its own world and reaches the recorder.
    @Test func titleChangeIsWritten() async throws {
        let host = makeHost()
        let page = host.page(for: request(url: ""), writer: writer)
        let loaded = try await loadLocal(page, html: "<title>Hello</title>", base: "https://example.com/")
        #expect(loaded)
        // The title (and the favicon the page script reports) can arrive after loading ends.
        let written = FakeWriter.Call.navigation(tabID: page.tabID, url: "https://example.com/", title: "Hello", faviconURL: "https://example.com/favicon.ico")
        #expect(try await waitUntil { page.status.title == "Hello" && writer.calls.contains(written) })
        #expect(page.status.url == "https://example.com/")
        host.close(page.tabID)
    }

    // MARK: History

    /// Review Focus 4: a private page (no `siteSettingsProfileID`) commits and records no visit; the same page with a profile records one,
    /// and its title follows.
    @Test func privateVisitsNeverStored() async throws {
        let host = makeHost()
        let privatePage = host.page(for: request(url: ""), writer: writer)
        #expect(try await loadLocal(privatePage, html: "<title>Secret</title>", base: "https://example.com/"))
        #expect(try await waitUntil { privatePage.status.title == "Secret" })
        #expect(privatePage.commitCount == 1)
        #expect(!writer.calls.contains { if case .visit = $0 { true } else if case .visitTitle = $0 { true } else { false } })
        host.close(privatePage.tabID)

        let profile = UUID()
        var normal = request(url: "")
        normal.siteSettingsProfileID = profile
        let page = host.page(for: normal, writer: writer)
        #expect(try await loadLocal(page, html: "<title>Public</title>", base: "https://example.org/"))
        #expect(writer.visits == [.visit(profileID: profile, url: "https://example.org/")])
        #expect(try await waitUntil { writer.calls.contains(.visitTitle(profileID: profile, url: "https://example.org/", title: "Public")) })
        host.close(page.tabID)
    }

    /// A single-page site's in-page navigation (pushState, then a new document.title) never renames the visit the commit recorded: the
    /// title window of a visit ends at the document's first same-document URL change.
    @Test func sameDocumentChangeEndsVisitTitle() async throws {
        let host = makeHost()
        let profile = UUID()
        var normal = request(url: "")
        normal.siteSettingsProfileID = profile
        let page = host.page(for: normal, writer: writer)
        #expect(try await loadLocal(page, html: "<title>Home</title>", base: "https://example.com/"))
        #expect(try await waitUntil { writer.calls.contains(.visitTitle(profileID: profile, url: "https://example.com/", title: "Home")) })

        _ = try await page.webView.evaluateJavaScript("history.pushState({}, '', '/article/1'); 1")
        #expect(try await waitUntil { page.status.url == "https://example.com/article/1" })
        _ = try await page.webView.evaluateJavaScript("document.title = 'Article 1'; 1")
        // The new title reached the page (and the tab's own write), so a visit write, had there been one, has happened too.
        #expect(try await waitUntil { page.status.title == "Article 1" })
        try await Task.sleep(for: .milliseconds(200))
        let titles = writer.calls.compactMap { call -> String? in
            if case .visitTitle(_, "https://example.com/", let title) = call { title } else { nil }
        }
        #expect(titles == ["Home"])
        #expect(writer.visits == [.visit(profileID: profile, url: "https://example.com/")])
        host.close(page.tabID)
    }

    /// A tab Stave loads by itself (restored at launch, shown again after hibernation) records no visit until the user acts on it.
    @Test func restoredTabCommitNotRecorded() async throws {
        let host = makeHost()
        host.testRuleLists = [try await blockAllRuleList()] // the stored address never reaches the network
        let profile = UUID()
        var stored = request(url: "https://example.com/stored")
        stored.siteSettingsProfileID = profile
        let page = host.page(for: stored, writer: writer)
        #expect(page.awaitsUserAction)
        page.webView.loadSimulatedRequest(URLRequest(url: try #require(URL(string: "https://example.com/again"))), responseHTML: "<title>Again</title>")
        #expect(try await waitUntil { page.commitCount >= 1 && page.webView.url?.absoluteString == "https://example.com/again" && !page.webView.isLoading })
        #expect(writer.visits.isEmpty)

        page.userActed()
        page.webView.loadSimulatedRequest(URLRequest(url: try #require(URL(string: "https://example.net/clicked"))), responseHTML: "<title>Clicked</title>")
        #expect(try await waitUntil { writer.visits == [.visit(profileID: profile, url: "https://example.net/clicked")] })
        host.close(page.tabID)
    }

    /// Only http and https commits are visits: a local `about:blank` document is not.
    @Test func blankDocumentIsNoVisit() async throws {
        let host = makeHost()
        var normal = request(url: "")
        normal.siteSettingsProfileID = UUID()
        let page = host.page(for: normal, writer: writer)
        page.webView.loadHTMLString("<title>Blank</title>", baseURL: nil)
        #expect(try await waitUntil { page.commitCount >= 1 && !page.webView.isLoading })
        #expect(writer.visits.isEmpty)
        host.close(page.tabID)
    }

    @Test func writeAfterCloseIsDropped() async throws {
        let host = makeHost()
        let page = host.page(for: request(url: ""), writer: writer)
        page.webView.loadHTMLString("<title>Before</title>", baseURL: URL(string: "https://example.com/"))
        host.close(page.tabID)
        let callsAtClose = writer.calls.count
        // Push a title through the KVO path of the closed page's web view. (Its delegate cancels every
        // navigation of a closed page, so it is taken off to let this late load happen.)
        page.webView.navigationDelegate = nil
        page.webView.loadHTMLString("<title>Late</title>", baseURL: URL(string: "https://example.org/"))
        let titled = try await waitUntil { page.webView.title == "Late" && !page.webView.isLoading }
        #expect(titled)
        page.record(.stateChanged)
        page.flush()
        #expect(writer.calls.count == callsAtClose)
        #expect(host.existingPage(page.tabID) == nil)
    }

    @Test func unloadFlushesThenTearsDown() async throws {
        let host = makeHost()
        let page = host.page(for: request(url: ""), writer: writer)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 300, height: 200), styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = page.webView
        defer { window.close() }
        let loaded = try await loadLocal(page, html: "<body style='background:#c33'><title>T</title>drawn</body>", base: "https://example.com/")
        #expect(loaded)
        try await Task.sleep(for: .milliseconds(200))
        // The test clock never moves, so this state change is throttled and left pending.
        page.record(.stateChanged)
        writer.calls.removeAll()
        host.hasOwner = { _ in true } // another window shows the tab, so its snapshot is kept

        host.unload(page.tabID)
        #expect(writer.stateWrites == 1)
        #expect(host.existingPage(page.tabID) == nil)
        let snapped = try await waitUntil(seconds: 60) { host.snapshot(for: page.tabID) != nil }
        #expect(snapped)
        #expect(writer.stateWrites == 1)
    }

    /// Closing a tab whose page hibernation unloaded drops the snapshot `unload` kept (a private window's close goes through here).
    @Test func closeOfAnUnloadedPageDropsItsSnapshot() async throws {
        let host = makeHost()
        let page = host.page(for: request(url: ""), writer: writer)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 300, height: 200), styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = page.webView
        defer { window.close() }
        let loaded = try await loadLocal(page, html: "<body style='background:#3c3'>drawn</body>", base: "https://example.com/")
        #expect(loaded)
        try await Task.sleep(for: .milliseconds(200))
        host.hasOwner = { _ in true }
        host.unload(page.tabID)
        let snapped = try await waitUntil(seconds: 60) { host.snapshot(for: page.tabID) != nil }
        #expect(snapped)
        host.close(page.tabID)
        #expect(host.snapshot(for: page.tabID) == nil)
    }

    @Test func closeDropsPendingStateAndSnapshot() async throws {
        let host = makeHost()
        let page = host.page(for: request(url: ""), writer: writer)
        page.record(.stateChanged)
        page.record(.stateChanged)
        writer.calls.removeAll()
        host.close(page.tabID)
        host.flushAll()
        #expect(writer.calls.isEmpty)
        #expect(host.snapshot(for: page.tabID) == nil)
    }

    @Test func flushAllWritesPendingState() {
        let host = makeHost()
        let page = host.page(for: request(url: ""), writer: writer)
        page.record(.stateChanged)
        page.record(.stateChanged)
        writer.calls.removeAll()
        host.flushAll()
        #expect(writer.stateWrites == 1)
        host.close(page.tabID)
    }

    /// When the last browser window closes, Stave stays open (decision 31) and unloads every browser-window page, so a background tab's
    /// audio, camera or microphone stops as it does in Safari, Chrome and Firefox. Private pages are left to their own windows.
    @Test func persistentTabIDsNameOnlyBrowserWindowPages() async throws {
        try await StoreCleanup.withProfile { profile in
            let host = makeHost()
            host.snapshotter = { _, done in done(nil) } // the unloaded page's web view is released at once, so its store is free to remove
            let normal = host.page(for: PageRequest(tabID: UUID(), store: .persistent(profile), siteSettingsProfileID: profile, url: "", title: "", faviconURL: nil, interactionState: nil), writer: writer)
            let privatePage = host.page(for: request(url: ""), writer: writer)
            #expect(host.persistentTabIDs == [normal.tabID])
            normal.record(.stateChanged)
            normal.record(.stateChanged)
            writer.calls.removeAll()
            for id in host.persistentTabIDs { host.unload(id) }
            #expect(writer.stateWrites == 1)
            #expect(host.existingPage(normal.tabID) == nil)
            #expect(host.existingPage(privatePage.tabID) === privatePage)
            #expect(host.persistentTabIDs.isEmpty)
            host.close(privatePage.tabID)
        }
    }

    // MARK: Snapshot memory

    /// Snapshots are kept for at most `snapshotLimit` tabs, the least recently taken dropped first.
    @Test func snapshotsAreCapped() {
        let host = makeHost()
        host.hasOwner = { _ in true }
        let ids = (0..<(PageHost.snapshotLimit + 6)).map { _ in UUID() }
        for id in ids { host.storeSnapshot(NSImage(size: NSSize(width: 4, height: 4)), for: id) }
        #expect(ids.filter { host.snapshot(for: $0) != nil }.count == PageHost.snapshotLimit)
        #expect(host.snapshot(for: ids[0]) == nil)
        #expect(host.snapshot(for: ids[5]) == nil)
        #expect(host.snapshot(for: ids[6]) != nil)
        #expect(host.snapshot(for: ids[ids.count - 1]) != nil)
    }

    /// An unloaded page nobody shows keeps no snapshot: no window can show it.
    @Test func unloadedPageWithNoOwnerKeepsNoSnapshot() async throws {
        let host = makeHost()
        host.snapshotter = { _, done in done(NSImage(size: NSSize(width: 4, height: 4))) }
        let kept = host.page(for: request(url: ""), writer: writer)
        let dropped = host.page(for: request(url: ""), writer: writer)
        host.hasOwner = { $0 == kept.tabID }
        host.unload(kept.tabID)
        host.unload(dropped.tabID)
        #expect(host.snapshot(for: kept.tabID) != nil)
        #expect(host.snapshot(for: dropped.tabID) == nil)
        // A live page's snapshot (a deselected tab) stays while the page lives.
        let live = host.page(for: request(url: ""), writer: writer)
        host.captureSnapshot(live.tabID)
        #expect(host.snapshot(for: live.tabID) != nil)
        host.close(live.tabID)
        host.close(kept.tabID)
    }

    /// Snapshots are taken scaled down, never wider than `snapshotWidth`.
    @Test func snapshotsAreTakenScaledDown() async throws {
        let host = makeHost()
        let page = host.page(for: request(url: ""), writer: writer)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1200, height: 800), styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = page.webView
        defer { window.close() }
        let loaded = try await loadLocal(page, html: "<body style='background:#33c'>drawn</body>", base: "https://example.com/")
        #expect(loaded)
        try await Task.sleep(for: .milliseconds(200))
        host.captureSnapshot(page.tabID)
        let snapped = try await waitUntil(seconds: 60) { host.snapshot(for: page.tabID) != nil }
        #expect(snapped)
        let width = try #require(host.snapshot(for: page.tabID)).size.width
        #expect(width <= PageHost.snapshotWidth)
        host.close(page.tabID)
    }

    /// A snapshot that never comes doesn't keep an unloaded page alive: it is torn down after the timeout, and a late snapshot is dropped.
    @Test func hungSnapshotStillTearsDown() async throws {
        let host = makeHost()
        host.hasOwner = { _ in true }
        host.snapshotTimeout = .milliseconds(50)
        var late: [@MainActor (NSImage?) -> Void] = []
        host.snapshotter = { _, done in late.append(done) }
        let page = host.page(for: request(url: ""), writer: writer)
        let container = NSView(frame: NSRect(x: 0, y: 0, width: 100, height: 100))
        container.addSubview(page.webView)
        host.unload(page.tabID)
        #expect(page.webView.superview === container)
        let tornDown = try await waitUntil { page.webView.superview == nil }
        #expect(tornDown)
        let done = try #require(late.first)
        done(NSImage(size: NSSize(width: 4, height: 4)))
        #expect(host.snapshot(for: page.tabID) == nil)
    }

    // MARK: Held writes

    /// A crashed page writes nothing, not even a flush of state left pending from before the crash.
    @Test func crashedPageWritesNothing() {
        let host = makeHost()
        let page = host.page(for: request(url: ""), writer: writer)
        page.record(.stateChanged)
        page.record(.stateChanged) // throttled: left pending
        writer.calls.removeAll()
        page.processTerminated()
        page.record(.title("Late"))
        page.record(.stateChanged)
        page.flush()
        host.flushAll()
        #expect(writer.calls.isEmpty)
        host.close(page.tabID)
    }

    // MARK: Content blocking

    @Test func siteSettingTurnsBlockingOff() {
        let host = makeHost()
        let profile = UUID()
        settings.setDecision(profileID: profile, host: "example.com", key: .contentBlocking, .deny)
        let off = host.page(for: PageRequest(tabID: UUID(), store: .privateSession(sharedStores.joinPrivateSession(profileID: UUID())), siteSettingsProfileID: profile, url: "", title: "", faviconURL: nil, interactionState: nil), writer: writer)
        // A blank URL has no host, so the profile's other sites keep blocking on.
        #expect(off.isContentBlockingOn)
        let request = PageRequest(tabID: UUID(), store: .privateSession(sharedStores.joinPrivateSession(profileID: UUID())), siteSettingsProfileID: profile, url: "https://www.example.com/x", title: "", faviconURL: nil, interactionState: nil)
        #expect(!host.blockingWanted(for: request))
        host.close(off.tabID)
    }

    @Test func setContentBlockingStoresTheSiteChoice() {
        let host = makeHost()
        let profile = UUID()
        let page = host.page(for: PageRequest(tabID: UUID(), store: .privateSession(sharedStores.joinPrivateSession(profileID: UUID())), siteSettingsProfileID: profile, url: "", title: "", faviconURL: nil, interactionState: nil), writer: writer)
        page.status.url = "https://example.com/x"
        host.setContentBlocking(false, for: page.tabID)
        #expect(!page.isContentBlockingOn)
        #expect(settings.decision(profileID: profile, host: "example.com", key: .contentBlocking) == .deny)
        host.setContentBlocking(true, for: page.tabID)
        #expect(page.isContentBlockingOn)
        #expect(settings.decision(profileID: profile, host: "example.com", key: .contentBlocking) == nil)
        host.close(page.tabID)
    }

    // MARK: Developer tools (decision 14)

    /// Every page in a normal window gets `developerExtrasEnabled`, with no setting.
    @Test func developerExtrasOnEveryPage() {
        let host = makeHost()
        let page = profilePage(host, profile: UUID())
        #expect(PageTools.hasDeveloperExtras(page.webView))
        #expect(!page.webView.isInspectable)
        host.close(page.tabID)
    }

    /// Task 9's spike could not prove that the inspector never writes a private page's address to WebKit's default store (it was checked on
    /// macOS 27 only, and its breakpoints and local overrides keep URLs), so a private window's pages get no developer extras.
    @Test func privatePagesHaveNoDeveloperExtras() {
        let host = makeHost()
        let page = host.page(for: request(url: ""), writer: writer)
        #expect(!PageTools.hasDeveloperExtras(page.webView))
        #expect(!PageTools.canShowInspector(page.webView))
        host.close(page.tabID)
    }

    // MARK: Zoom (decision 12)

    func profilePage(_ host: PageHost, profile: UUID) -> LivePage {
        var normal = request(url: "")
        normal.siteSettingsProfileID = profile
        return host.page(for: normal, writer: writer)
    }

    /// Loads `url` as a committed main-frame navigation (no network) and waits for the commit to settle.
    func commit(_ page: LivePage, _ url: String) async throws -> Bool {
        let commits = page.commitCount
        page.webView.loadSimulatedRequest(URLRequest(url: try #require(URL(string: url))), responseHTML: "<title>Invented</title>")
        // WebKit lowercases the host it reports.
        return try await waitUntil { page.commitCount > commits && page.webView.url?.absoluteString.lowercased() == url.lowercased() && !page.webView.isLoading }
    }

    /// A page at a stored 150 % on one host that commits a host with nothing stored goes back to 100 %: the zoom never leaks to another site.
    @Test func zoomResetsOnHostWithoutValue() async throws {
        let host = makeHost()
        let profile = UUID()
        settings.setSiteValue(profileID: profile, host: "example.com", key: .zoom, 1.5)
        let page = profilePage(host, profile: profile)
        #expect(try await commit(page, "https://example.com/a"))
        #expect(try await waitUntil { page.webView.pageZoom == 1.5 })
        #expect(page.zoom == 1.5)
        #expect(try await commit(page, "https://example.org/b"))
        #expect(try await waitUntil { page.webView.pageZoom == 1.0 })
        #expect(page.zoom == 1.0)
        host.close(page.tabID)
    }

    /// Zoom is keyed by `SiteHost.normalized`, the key site settings use: `www.`, case and port don't make another site.
    @Test func zoomKeyMatchesSiteSettingKey() async throws {
        let host = makeHost()
        let profile = UUID()
        let first = profilePage(host, profile: profile)
        #expect(try await commit(first, "https://WWW.Example.com:8443/a"))
        host.zoomIn(first.tabID)
        #expect(first.webView.pageZoom == 1.15)
        #expect(settings.zoom(profileID: profile, host: "example.com") == 1.15)
        #expect(settings.siteValues.count == 1)
        let second = profilePage(host, profile: profile)
        #expect(try await commit(second, "https://example.com/b"))
        #expect(try await waitUntil { second.webView.pageZoom == 1.15 })
        // Another profile has its own zoom for the same host.
        let other = profilePage(host, profile: UUID())
        #expect(try await commit(other, "https://example.com/b"))
        #expect(other.webView.pageZoom == 1.0)
        for page in [first, second, other] { host.close(page.tabID) }
    }

    /// Zoom In and Zoom Out step through Safari's levels; Actual Size goes back to 100 % and removes the stored row.
    @Test func actualSizeRemovesTheStoredZoom() async throws {
        let host = makeHost()
        let profile = UUID()
        let page = profilePage(host, profile: profile)
        #expect(try await commit(page, "https://example.net/"))
        host.zoomIn(page.tabID)
        host.zoomIn(page.tabID)
        #expect(page.zoom == 1.25)
        host.zoomOut(page.tabID)
        #expect(page.zoom == 1.15)
        #expect(settings.zoom(profileID: profile, host: "example.net") == 1.15)
        host.resetZoom(page.tabID)
        #expect(page.zoom == 1.0)
        #expect(page.webView.pageZoom == 1.0)
        #expect(settings.siteValues.isEmpty)
        #expect(settings.siteValueWrites.last?.value == nil)
        // Zooming out to 100 % from above also stores nothing.
        host.zoomIn(page.tabID)
        host.zoomOut(page.tabID)
        #expect(settings.siteValues.isEmpty)
        host.close(page.tabID)
    }

    /// Other open pages of the same site and profile follow a zoom change at once, as in Chrome; other sites don't.
    @Test func zoomFollowsToOpenPagesOfTheSite() async throws {
        let host = makeHost()
        let profile = UUID()
        let first = profilePage(host, profile: profile)
        let second = profilePage(host, profile: profile)
        let elsewhere = profilePage(host, profile: profile)
        #expect(try await commit(first, "https://example.com/a"))
        #expect(try await commit(second, "https://www.example.com/b"))
        #expect(try await commit(elsewhere, "https://example.org/"))
        host.zoomIn(first.tabID)
        #expect(second.zoom == 1.15 && second.webView.pageZoom == 1.15)
        #expect(elsewhere.zoom == 1.0 && elsewhere.webView.pageZoom == 1.0)
        for page in [first, second, elsewhere] { host.close(page.tabID) }
    }

    /// A page with no web site (a blank tab, a local file) zooms but stores nothing.
    @Test func zoomWithoutAHostStoresNothing() async throws {
        let host = makeHost()
        let page = profilePage(host, profile: UUID())
        host.zoomIn(page.tabID)
        #expect(page.zoom == 1.15)
        #expect(settings.siteValueWrites.isEmpty)
        host.close(page.tabID)
    }

    /// A private window writes no site values (Global Constraint): its zoom is kept in memory for the private session, shared by its pages on
    /// the same host, and goes with the session (`leavePrivateSession`), as its camera answers do.
    @Test func privateZoomNotStored() async throws {
        let host = makeHost()
        let profile = UUID()
        let session = host.joinPrivateSession(profileID: profile)
        func privatePage() -> LivePage {
            host.page(for: PageRequest(tabID: UUID(), store: .privateSession(session), siteSettingsProfileID: nil, url: "", title: "", faviconURL: nil, interactionState: nil), writer: writer)
        }
        let first = privatePage()
        #expect(try await commit(first, "https://example.com/a"))
        host.zoomIn(first.tabID)
        #expect(first.webView.pageZoom == 1.15)
        #expect(settings.siteValueWrites.isEmpty)
        let second = privatePage()
        #expect(try await commit(second, "https://example.com/b"))
        #expect(try await waitUntil { second.webView.pageZoom == 1.15 })
        host.close(first.tabID)
        host.close(second.tabID)
        // The memory is read through the old session's own store key, before and after the session ends, so the check after
        // `leavePrivateSession` fails if the session's zoom were kept (a new session's key would miss it either way).
        #expect(host.siteValue(for: first, host: "example.com", key: .zoom, as: Double.self) == 1.15)

        host.leavePrivateSession(profileID: profile)
        #expect(host.siteValue(for: first, host: "example.com", key: .zoom, as: Double.self) == nil)
        let nextSession = host.joinPrivateSession(profileID: profile)
        #expect(nextSession != session)
        let later = host.page(for: PageRequest(tabID: UUID(), store: .privateSession(nextSession), siteSettingsProfileID: nil, url: "", title: "", faviconURL: nil, interactionState: nil), writer: writer)
        #expect(try await commit(later, "https://example.com/c"))
        #expect(later.webView.pageZoom == 1.0)
        #expect(settings.siteValueWrites.isEmpty)
        host.close(later.tabID)
        host.leavePrivateSession(profileID: profile)
    }

    // MARK: Hibernation

    @Test func hibernateIdleUnloadsIdlePagesButNotBusyOnes() async {
        let host = makeHost()
        let idle = host.page(for: request(url: ""), writer: writer)
        let busy = host.page(for: request(url: ""), writer: writer)
        let shown = host.page(for: request(url: ""), writer: writer)
        host.markShown(shown.tabID, true)
        host.mediaCheck = { webView in webView === busy.webView }
        clock.date += HibernationPolicy.idleLimit + 1
        await host.hibernateIdle()
        #expect(host.existingPage(idle.tabID) == nil)
        #expect(host.existingPage(busy.tabID) === busy)
        #expect(host.existingPage(shown.tabID) === shown)
        host.close(busy.tabID)
        host.close(shown.tabID)
    }

    @Test func hibernateIdleKeepsAnOpenerWithPopups() async {
        let host = makeHost()
        let opener = host.page(for: request(url: ""), writer: writer)
        let other = host.page(for: request(url: ""), writer: writer)
        host.mediaCheck = { _ in false }
        host.hasOpenPopups = { $0 == opener.tabID }
        clock.date += HibernationPolicy.idleLimit + 1
        await host.hibernateIdle()
        #expect(host.existingPage(opener.tabID) === opener)
        #expect(host.existingPage(other.tabID) == nil)
        host.close(opener.tabID)
    }

    // MARK: Quarantine

    @Test func finishedDownloadIsQuarantined() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("StaveQuarantine-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appendingPathComponent("f.txt")
        try Data("x".utf8).write(to: file)
        try Quarantine.mark(file, source: QuarantineSource(download: URL(string: "https://example.com/f")!, page: URL(string: "https://example.com/")))
        let fresh = URL(fileURLWithPath: file.path)
        let values = try fresh.resourceValues(forKeys: [.quarantinePropertiesKey])
        let properties = try #require(values.quarantineProperties)
        #expect(properties[kLSQuarantineAgentNameKey as String] as? String == "Stave")
    }
}
