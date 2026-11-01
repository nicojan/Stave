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

    func makeHost(stores: WebDataStores = WebDataStores()) -> PageHost {
        let clock = clock
        return PageHost(
            stores: stores,
            contentBlocker: ContentBlockerManager(),
            siteSettings: settings,
            applicationName: "Version/17.0 Safari/605.1.15",
            now: { clock.date }
        )
    }

    func request(_ tabID: UUID = UUID(), url: String, state: Data? = nil) -> PageRequest {
        PageRequest(tabID: tabID, store: .privateWindow(UUID()), siteSettingsProfileID: nil, url: url, title: "", faviconURL: nil, interactionState: state)
    }

    /// Polls on the main actor without blocking it.
    func waitUntil(seconds: Double = 20, _ condition: () -> Bool) async throws -> Bool {
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline {
            if condition() { return true }
            try await Task.sleep(for: .milliseconds(50))
        }
        return condition()
    }

    func loadLocal(_ page: LivePage, html: String, base: String) async throws -> Bool {
        page.webView.loadHTMLString(html, baseURL: URL(string: base))
        return try await waitUntil {
            page.webView.url?.absoluteString == base && !page.webView.isLoading && !page.status.isLoading
        }
    }

    func removePersistentStores(_ ids: [UUID]) async {
        for id in ids { try? await WKWebsiteDataStore.remove(forIdentifier: id) }
    }

    // MARK: Stores

    @Test func storesFollowProfileContainerAndPrivate() async {
        let stores = WebDataStores()
        let a = UUID(), b = UUID(), w = UUID()
        let storeA = stores.store(for: .persistent(a))
        #expect(storeA.isPersistent)
        #expect(storeA.identifier == a)
        let storeB = stores.store(for: .persistent(b))
        #expect(storeB !== storeA)
        #expect(storeB.identifier == b)
        #expect(stores.store(for: .persistent(a)) === storeA)
        #expect(!stores.store(for: .privateWindow(w)).isPersistent)
        await removePersistentStores([a, b])
    }

    @Test func twoPrivateWindowsNeverShare() {
        let stores = WebDataStores()
        let w1 = UUID(), w2 = UUID()
        let first = stores.store(for: .privateWindow(w1))
        let second = stores.store(for: .privateWindow(w2))
        #expect(first !== second)
        #expect(stores.store(for: .privateWindow(w1)) === first)
        stores.releasePrivate(w1)
        #expect(stores.store(for: .privateWindow(w1)) !== first)
        #expect(stores.store(for: .privateWindow(w2)) === second)
    }

    @Test func noDefaultStoreEver() async {
        let stores = WebDataStores()
        let p = UUID()
        let made = [stores.store(for: .persistent(p)), stores.store(for: .privateWindow(UUID()))]
        let defaultStore = WKWebsiteDataStore.default()
        for store in made {
            #expect(store !== defaultStore)
            #expect(!(store.isPersistent && store.identifier == nil))
        }
        await removePersistentStores([p])
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
        try await Task.sleep(for: .milliseconds(500))
        #expect(b.webView.title != "A")
        #expect(!b.webView.isLoading)
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
        #expect(page.status.title == "Hello")
        #expect(page.status.url == "https://example.com/")
        #expect(writer.calls.contains(.navigation(tabID: page.tabID, url: "https://example.com/", title: "Hello", faviconURL: "https://example.com/favicon.ico")))
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
        let snapped = try await waitUntil(seconds: 10) { host.snapshot(for: page.tabID) != nil }
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
        let snapped = try await waitUntil(seconds: 10) { host.snapshot(for: page.tabID) != nil }
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
        let snapped = try await waitUntil(seconds: 10) { host.snapshot(for: page.tabID) != nil }
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
        let tornDown = try await waitUntil(seconds: 5) { page.webView.superview == nil }
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
        let off = host.page(for: PageRequest(tabID: UUID(), store: .privateWindow(UUID()), siteSettingsProfileID: profile, url: "", title: "", faviconURL: nil, interactionState: nil), writer: writer)
        // A blank URL has no host, so the profile's other sites keep blocking on.
        #expect(off.isContentBlockingOn)
        let request = PageRequest(tabID: UUID(), store: .privateWindow(UUID()), siteSettingsProfileID: profile, url: "https://www.example.com/x", title: "", faviconURL: nil, interactionState: nil)
        #expect(!host.blockingWanted(for: request))
        host.close(off.tabID)
    }

    @Test func setContentBlockingStoresTheSiteChoice() {
        let host = makeHost()
        let profile = UUID()
        let page = host.page(for: PageRequest(tabID: UUID(), store: .privateWindow(UUID()), siteSettingsProfileID: profile, url: "", title: "", faviconURL: nil, interactionState: nil), writer: writer)
        page.status.url = "https://example.com/x"
        host.setContentBlocking(false, for: page.tabID)
        #expect(!page.isContentBlockingOn)
        #expect(settings.decision(profileID: profile, host: "example.com", key: .contentBlocking) == .deny)
        host.setContentBlocking(true, for: page.tabID)
        #expect(page.isContentBlockingOn)
        #expect(settings.decision(profileID: profile, host: "example.com", key: .contentBlocking) == nil)
        host.close(page.tabID)
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
        try Quarantine.mark(file, source: URL(string: "https://example.com/f")!)
        let fresh = URL(fileURLWithPath: file.path)
        let values = try fresh.resourceValues(forKeys: [.quarantinePropertiesKey])
        let properties = try #require(values.quarantineProperties)
        #expect(properties[kLSQuarantineAgentNameKey as String] as? String == "Stave")
    }
}
