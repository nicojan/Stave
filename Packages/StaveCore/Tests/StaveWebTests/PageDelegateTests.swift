import AppKit
import ChorusEngine
import Foundation
import StaveCore
import Testing
import WebKit

@testable import StaveWeb

// MARK: Fakes

@MainActor
final class FakeEvents: PageEvents {
    struct LinkedTab: Equatable {
        var opener: UUID
        var url: String
        var select: Bool
        var hasWebView: Bool
    }

    var linkedTabs: [LinkedTab] = []
    var popups: [WKWebView] = []
    var closed: [UUID] = []
    var externalQuestions: [(URL, String)] = []
    var externalAnswer = false
    var mediaQuestions: [(host: String, camera: Bool, microphone: Bool)] = []
    var mediaAnswer: (allow: Bool, remember: Bool) = (false, false)
    var alerts: [String] = []
    /// The asking frame's host passed with each alert, confirm and prompt.
    var dialogOrigins: [String?] = []
    var confirmAnswer = false
    var promptAnswer: String?
    var chosenFiles: [URL]?
    let downloads = DownloadList()
    var downloadsDirectory: URL
    /// Set by tests that want WebKit-made views adopted the way the app will (`host.adopt`).
    weak var host: PageHost?
    let writer = FakeWriter()

    init(downloadsDirectory: URL = FileManager.default.temporaryDirectory) {
        self.downloadsDirectory = downloadsDirectory
    }

    func openLinkedTab(opener: UUID, url: String, select: Bool, webView: WKWebView?) -> UUID? {
        linkedTabs.append(LinkedTab(opener: opener, url: url, select: select, hasWebView: webView != nil))
        let id = UUID()
        if let webView, let host {
            _ = host.adopt(webView, as: PageRequest(tabID: id, store: .privateWindow(UUID()), siteSettingsProfileID: nil, url: url, title: "", faviconURL: nil, interactionState: nil), writer: writer)
        }
        return id
    }

    func openPopup(opener: UUID, webView: WKWebView, features: WKWindowFeatures) {
        popups.append(webView)
        _ = host?.adopt(webView, as: PageRequest(tabID: UUID(), store: .privateWindow(UUID()), siteSettingsProfileID: nil, url: "", title: "", faviconURL: nil, interactionState: nil), writer: writer)
    }

    func closePage(_ tabID: UUID) { closed.append(tabID) }

    /// Runs while the question is "up" (before the answer returns).
    var whileConfirming: (() -> Void)?

    func confirmExternalApp(url: URL, appName: String) async -> Bool {
        externalQuestions.append((url, appName))
        whileConfirming?()
        return externalAnswer
    }

    func askMedia(tabID: UUID, host: String, camera: Bool, microphone: Bool) async -> (allow: Bool, remember: Bool) {
        mediaQuestions.append((host, camera, microphone))
        return mediaAnswer
    }

    func alert(tabID: UUID, origin: String?, message: String) async { alerts.append(message); dialogOrigins.append(origin) }
    func confirm(tabID: UUID, origin: String?, message: String) async -> Bool { dialogOrigins.append(origin); return confirmAnswer }
    func prompt(tabID: UUID, origin: String?, message: String, defaultText: String?) async -> String? { dialogOrigins.append(origin); return promptAnswer }
    func chooseFiles(tabID: UUID, allowsMultiple: Bool, allowsDirectories: Bool) async -> [URL]? { chosenFiles }
    /// False: no owner can be found for the page, so its downloads are refused.
    var hasOwner = true
    func downloadOwner(tabID: UUID) -> DownloadOwner? { hasOwner ? .profile(tabID) : nil }
}

/// A new-window action for `createWebViewWith`. (A `WKFrameInfo` subclass crashes outside WebKit, so
/// policy tests use `NavigationRequest` instead.)
final class FakeAction: WKNavigationAction {
    private let fakeRequest: URLRequest
    private let fakeType: WKNavigationType
    private let fakeModifiers: NSEvent.ModifierFlags

    init(_ url: String, type: WKNavigationType = .linkActivated, modifiers: NSEvent.ModifierFlags = []) {
        fakeRequest = URLRequest(url: URL(string: url)!)
        fakeType = type
        fakeModifiers = modifiers
        super.init()
    }

    override var request: URLRequest { fakeRequest }
    override var targetFrame: WKFrameInfo? { nil }
    override var navigationType: WKNavigationType { fakeType }
    override var modifierFlags: NSEvent.ModifierFlags { fakeModifiers }
}

final class FakeFeatures: WKWindowFeatures {
    private let fakeWidth: NSNumber?
    init(width: NSNumber? = nil) {
        fakeWidth = width
        super.init()
    }

    override var width: NSNumber? { fakeWidth }
    override var height: NSNumber? { nil }
}

@MainActor
final class FakeExternalApps {
    var app: URL?
    var opened: [URL] = []

    var seam: ExternalApps {
        ExternalApps(appFor: { [unowned self] _ in self.app }, open: { [unowned self] url in self.opened.append(url) })
    }
}

// MARK: Tests

@MainActor
@Suite("Page delegate")
struct PageDelegateTests {
    let clock = TestClock()
    let writer = FakeWriter()
    let settings = FakeSiteSettings()
    let events = FakeEvents()

    func makeHost() -> PageHost {
        let clock = clock
        let host = PageHost(
            stores: WebDataStores(),
            contentBlocker: ContentBlockerManager(),
            siteSettings: settings,
            applicationName: "Version/17.0 Safari/605.1.15",
            now: { clock.date }
        )
        host.events = events
        events.host = host
        return host
    }

    func request(_ tabID: UUID = UUID(), url: String = "", profile: UUID? = nil, title: String = "", state: Data? = nil) -> PageRequest {
        PageRequest(tabID: tabID, store: profile.map { .persistent($0) } ?? .privateWindow(UUID()), siteSettingsProfileID: profile, url: url, title: title, faviconURL: nil, interactionState: state)
    }

    func delegate(of page: LivePage) throws -> PageDelegate {
        try #require(page.webView.navigationDelegate as? PageDelegate)
    }

    func waitUntil(seconds: Double = 20, _ condition: () -> Bool) async throws -> Bool {
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline {
            if condition() { return true }
            try await Task.sleep(for: .milliseconds(50))
        }
        return condition()
    }

    func blockAllRuleList() async throws -> WKContentRuleList {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("StaveRuleLists-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = try #require(WKContentRuleListStore(url: dir))
        let list = try await store.compileContentRuleList(forIdentifier: "blockAll", encodedContentRuleList: #"[{"trigger":{"url-filter":".*"},"action":{"type":"block"}}]"#)
        return try #require(list)
    }

    func tempDirectory() throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("StaveDownloads-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    // MARK: Navigation

    @Test func mainFramePolicyFollowsNavigationPolicy() async throws {
        let (allow, here) = PageDelegate.decision(for: "https://example.com", isMainFrame: true, userGesture: true, modifiers: [], targetsNewWindow: false)
        #expect(allow == .allow)
        #expect(here == .current)
        // Ruling R2: a page's own navigation to a refused scheme is refused silently.
        let (refused, _) = PageDelegate.decision(for: "file:///x", isMainFrame: true, userGesture: true, modifiers: [], targetsNewWindow: false)
        #expect(refused == .refuse(nil))

        let host = makeHost()
        let page = host.page(for: request(), writer: writer)
        let delegate = try delegate(of: page)
        #expect(delegate.decide(NavigationRequest("https://example.com")) == .allow)
        #expect(delegate.decide(NavigationRequest("file:///x")) == .cancel)
        #expect(delegate.decide(NavigationRequest("data:text/html,x", type: .other)) == .cancel)
        #expect(page.status.failure == nil)
        // A subframe may be data:, the main frame never.
        #expect(delegate.decide(NavigationRequest("data:text/html,x", isMainFrame: false, type: .other)) == .allow)

        // A typed address is the app's; a refused one shows the panel.
        host.loadTyped("file:///x", in: page.tabID)
        #expect(page.status.failure == .refused(url: "file:///x"))
        host.close(page.tabID)
    }

    @Test func commandClickOpensBackgroundTabBelowOpener() async throws {
        let (_, background) = PageDelegate.decision(for: "https://example.com", isMainFrame: true, userGesture: true, modifiers: .command, targetsNewWindow: false)
        #expect(background == .newTab(select: false))
        let (_, selected) = PageDelegate.decision(for: "https://example.com", isMainFrame: true, userGesture: true, modifiers: [.command, .shift], targetsNewWindow: false)
        #expect(selected == .newTab(select: true))

        let host = makeHost()
        let page = host.page(for: request(), writer: writer)
        let delegate = try delegate(of: page)
        let policy = delegate.decide(NavigationRequest("https://example.com/b", modifiers: .command))
        #expect(policy == .cancel)
        #expect(events.linkedTabs == [.init(opener: page.tabID, url: "https://example.com/b", select: false, hasWebView: false)])
        host.close(page.tabID)
    }

    @Test func blankTargetBecomesLinkedTab() throws {
        let host = makeHost()
        let page = host.page(for: request(), writer: writer)
        let delegate = try delegate(of: page)
        let configuration = page.webView.configuration
        let made = delegate.webView(page.webView, createWebViewWith: configuration, for: FakeAction("https://example.com/new"), windowFeatures: FakeFeatures())
        let child = try #require(made)
        #expect(events.linkedTabs == [.init(opener: page.tabID, url: "https://example.com/new", select: true, hasWebView: true)])
        #expect(events.popups.isEmpty)
        #expect(child.configuration.websiteDataStore === configuration.websiteDataStore)
        #expect(child.configuration.userContentController === configuration.userContentController)
        // The adopted page is gated by its own delegate.
        #expect(child.navigationDelegate is PageDelegate)
        #expect(child.navigationDelegate !== delegate)
        host.close(page.tabID)
    }

    @Test func viewNotAdoptedByTheAppIsRefused() throws {
        let host = makeHost()
        events.host = nil
        let page = host.page(for: request(), writer: writer)
        let delegate = try delegate(of: page)
        let made = delegate.webView(page.webView, createWebViewWith: page.webView.configuration, for: FakeAction("https://example.com/new"), windowFeatures: FakeFeatures())
        #expect(made == nil)
        host.close(page.tabID)
    }

    @Test func sizedWindowOpenBecomesPopup() throws {
        let host = makeHost()
        let page = host.page(for: request(), writer: writer)
        let delegate = try delegate(of: page)
        let made = delegate.webView(page.webView, createWebViewWith: page.webView.configuration, for: FakeAction("https://example.com/p", type: .other), windowFeatures: FakeFeatures(width: 500))
        let popup = try #require(made)
        #expect(events.popups.count == 1)
        #expect(events.popups.first === popup)
        #expect(events.linkedTabs.isEmpty)
        host.close(page.tabID)
    }

    @Test func windowCloseClosesThePage() throws {
        let host = makeHost()
        let page = host.page(for: request(), writer: writer)
        try delegate(of: page).webViewDidClose(page.webView)
        #expect(events.closed == [page.tabID])
        host.close(page.tabID)
    }

    @Test func processTerminationShowsCrashedNotReload() async throws {
        let host = makeHost()
        let page = host.page(for: request(), writer: writer)
        page.webView.loadHTMLString("<title>T</title>", baseURL: URL(string: "https://example.com/"))
        let loaded = try await waitUntil { page.status.title == "T" && !page.webView.isLoading }
        #expect(loaded)
        writer.calls.removeAll()
        try delegate(of: page).webViewWebContentProcessDidTerminate(page.webView)
        #expect(page.status.failure == .crashed)
        try await Task.sleep(for: .milliseconds(500))
        #expect(!page.webView.isLoading)
        #expect(!page.status.isLoading)
        #expect(page.status.failure == .crashed)
        #expect(writer.calls.isEmpty)
        host.close(page.tabID)
    }

    @Test func tlsFailureIsInsecure() throws {
        let host = makeHost()
        let page = host.page(for: request(), writer: writer)
        let delegate = try delegate(of: page)
        let failing = URL(string: "https://bad.example.com/x")!
        let cancelled = NSError(domain: NSURLErrorDomain, code: NSURLErrorCancelled, userInfo: [NSURLErrorFailingURLErrorKey: failing])
        delegate.webView(page.webView, didFailProvisionalNavigation: nil, withError: cancelled)
        #expect(page.status.failure == nil)
        let interrupted = NSError(domain: "WebKitErrorDomain", code: 102, userInfo: [NSURLErrorFailingURLErrorKey: failing])
        delegate.webView(page.webView, didFailProvisionalNavigation: nil, withError: interrupted)
        #expect(page.status.failure == nil)
        let untrusted = NSError(domain: NSURLErrorDomain, code: NSURLErrorServerCertificateUntrusted, userInfo: [NSURLErrorFailingURLErrorKey: failing])
        delegate.webView(page.webView, didFailProvisionalNavigation: nil, withError: untrusted)
        #expect(page.status.failure == .insecure(host: "bad.example.com"))
        let offline = NSError(domain: NSURLErrorDomain, code: NSURLErrorNotConnectedToInternet, userInfo: [NSURLErrorFailingURLErrorKey: failing, NSLocalizedDescriptionKey: "Offline."])
        delegate.webView(page.webView, didFail: nil, withError: offline)
        #expect(page.status.failure == .loadFailed(host: "bad.example.com", message: "Offline."))
        for code in [-1200, -1201, -1203, -1204, -1205, -1206] {
            #expect(PageDelegate.failure(for: NSError(domain: NSURLErrorDomain, code: code), fallbackURL: failing) == .insecure(host: "bad.example.com"))
        }
        host.close(page.tabID)
    }

    // MARK: R5: commits come from didCommit

    @Test func failedLoadKeepsStoredTitle() async throws {
        let host = makeHost()
        host.testRuleLists = [try await blockAllRuleList()]
        let page = host.page(for: request(url: "https://example.com/", title: "Stored"), writer: writer)
        _ = try await waitUntil(seconds: 5) { page.status.failure != nil }
        try await Task.sleep(for: .milliseconds(300))
        #expect(page.status.failure != nil)
        #expect(writer.calls.isEmpty)
        host.close(page.tabID)
    }

    @Test func sameDocumentChangeKeepsTitle() async throws {
        let host = makeHost()
        let page = host.page(for: request(), writer: writer)
        page.webView.loadHTMLString("<title>T</title>", baseURL: URL(string: "https://example.com/"))
        let loaded = try await waitUntil { page.status.title == "T" && !page.webView.isLoading }
        #expect(loaded)
        writer.calls.removeAll()
        _ = try await page.webView.evaluateJavaScript("history.pushState({}, '', '/b'); 1")
        let moved = try await waitUntil { page.status.url == "https://example.com/b" }
        #expect(moved)
        _ = try await waitUntil(seconds: 2) { !writer.calls.isEmpty }
        #expect(writer.calls.contains(.navigation(tabID: page.tabID, url: "https://example.com/b", title: "T", faviconURL: "https://example.com/favicon.ico")))
        #expect(!writer.calls.contains { if case .navigation(_, _, "", _) = $0 { true } else { false } })
        host.close(page.tabID)
    }

    @Test func laterAllowedNavigationClearsFailure() async throws {
        let host = makeHost()
        let page = host.page(for: request(), writer: writer)
        page.status.failure = .loadFailed(host: "example.com", message: "x")
        page.webView.loadHTMLString("<title>T</title>", baseURL: URL(string: "https://example.com/"))
        let loaded = try await waitUntil { page.status.failure == nil && page.status.url == "https://example.com/" && !page.status.isLoading }
        #expect(loaded)
        host.close(page.tabID)
    }

    // MARK: R6: content blocking per site

    @Test func blockingFollowsTheSiteOnEachNavigation() async throws {
        let host = makeHost()
        let profile = UUID()
        settings.setDecision(profileID: profile, host: "example.com", key: .contentBlocking, .deny)
        let page = host.page(for: request(profile: profile), writer: writer)
        let delegate = try delegate(of: page)
        #expect(page.isContentBlockingOn)
        #expect(delegate.decide(NavigationRequest("https://www.example.com/a")) == .allow)
        #expect(!page.isContentBlockingOn)
        #expect(delegate.decide(NavigationRequest("https://example.com/b")) == .allow)
        #expect(!page.isContentBlockingOn)
        #expect(delegate.decide(NavigationRequest("https://example.org/")) == .allow)
        #expect(page.isContentBlockingOn)
        // A subframe doesn't change the page's site.
        #expect(delegate.decide(NavigationRequest("https://example.com/f", isMainFrame: false)) == .allow)
        #expect(page.isContentBlockingOn)

        // A real load reaches the delegate too.
        page.webView.loadSimulatedRequest(URLRequest(url: URL(string: "https://example.com/real")!), responseHTML: "<title>R</title>")
        let switched = try await waitUntil { page.status.title == "R" }
        #expect(switched)
        #expect(!page.isContentBlockingOn)
        host.close(page.tabID)
        await removeStore(profile)
    }

    @Test func sharedControllerIsLeftAlone() async throws {
        let host = makeHost()
        let profile = UUID()
        settings.setDecision(profileID: profile, host: "example.com", key: .contentBlocking, .deny)
        let opener = host.page(for: request(profile: profile), writer: writer)
        let openerDelegate = try delegate(of: opener)
        _ = openerDelegate.webView(opener.webView, createWebViewWith: opener.webView.configuration, for: FakeAction("https://example.com/new"), windowFeatures: FakeFeatures())
        // The opener and its linked tab share one content controller (ruling R10): switching lists
        // for one would switch them for both, so neither switches on its own.
        #expect(openerDelegate.decide(NavigationRequest("https://example.com/")) == .allow)
        #expect(opener.isContentBlockingOn)
        host.close(opener.tabID)
        await removeStore(profile)
    }

    func removeStore(_ id: UUID) async {
        try? await WKWebsiteDataStore.remove(forIdentifier: id)
    }

    // MARK: External apps

    @Test func externalAppAsksThenOpens() async throws {
        let host = makeHost()
        let apps = FakeExternalApps()
        host.externalApps = apps.seam
        let page = host.page(for: request(), writer: writer)
        let delegate = try delegate(of: page)

        // A page link with no app does nothing visible.
        #expect(delegate.decide(NavigationRequest("zoommtg://x")) == .cancel)
        await delegate.externalTask?.value
        #expect(page.status.failure == nil)
        #expect(events.externalQuestions.isEmpty)

        // Without a user gesture nothing is asked.
        apps.app = URL(fileURLWithPath: "/System/Applications/Mail.app")
        #expect(delegate.decide(NavigationRequest("mailto:a@example.com", type: .other)) == .cancel)
        #expect(events.externalQuestions.isEmpty)

        // Declined: nothing opens.
        #expect(delegate.decide(NavigationRequest("mailto:a@example.com")) == .cancel)
        await delegate.externalTask?.value
        #expect(events.externalQuestions.count == 1)
        #expect(events.externalQuestions.first?.1 == "Mail")
        #expect(apps.opened.isEmpty)

        // Within a second of a decline, a new request is dropped.
        _ = delegate.decide(NavigationRequest("mailto:a@example.com"))
        await delegate.externalTask?.value
        #expect(events.externalQuestions.count == 1)
        clock.date += PageDelegate.externalCooldown + 0.1

        // Accepted: it opens.
        events.externalAnswer = true
        _ = delegate.decide(NavigationRequest("mailto:a@example.com"))
        await delegate.externalTask?.value
        #expect(apps.opened == [URL(string: "mailto:a@example.com")!])

        // Typed, with no app: the panel says so.
        apps.app = nil
        host.loadTyped("zoommtg://x", in: page.tabID)
        await delegate.externalTask?.value
        #expect(page.status.failure == .noAppForLink(url: "zoommtg://x"))
        host.close(page.tabID)
    }

    @Test func externalPromptsAreSingleFlight() async throws {
        let host = makeHost()
        let apps = FakeExternalApps()
        apps.app = URL(fileURLWithPath: "/System/Applications/Mail.app")
        host.externalApps = apps.seam
        events.externalAnswer = true
        let page = host.page(for: request(), writer: writer)
        let delegate = try delegate(of: page)
        // A script clicking a mailto: link in a loop: only the first request asks.
        #expect(delegate.decide(NavigationRequest("mailto:a@example.com")) == .cancel)
        #expect(delegate.decide(NavigationRequest("mailto:b@example.com")) == .cancel)
        await delegate.externalTask?.value
        #expect(events.externalQuestions.count == 1)
        #expect(apps.opened == [URL(string: "mailto:a@example.com")!])
        // Once answered (yes), the next request asks again.
        _ = delegate.decide(NavigationRequest("mailto:c@example.com"))
        await delegate.externalTask?.value
        #expect(events.externalQuestions.count == 2)
        host.close(page.tabID)
    }

    @Test func externalAppNotOpenedForAClosedTab() async throws {
        let host = makeHost()
        let apps = FakeExternalApps()
        apps.app = URL(fileURLWithPath: "/System/Applications/Mail.app")
        host.externalApps = apps.seam
        events.externalAnswer = true
        let page = host.page(for: request(), writer: writer)
        let delegate = try delegate(of: page)
        events.whileConfirming = { host.close(page.tabID) }
        _ = delegate.decide(NavigationRequest("mailto:a@example.com"))
        await delegate.externalTask?.value
        #expect(events.externalQuestions.count == 1)
        #expect(apps.opened.isEmpty)
    }

    // MARK: Download links

    @Test func downloadLinkDownloads() throws {
        let host = makeHost()
        let page = host.page(for: request(), writer: writer)
        let delegate = try delegate(of: page)
        #expect(delegate.decide(NavigationRequest("https://example.com/f.txt", shouldDownload: true)) == .download)
        #expect(delegate.decide(NavigationRequest("https://example.com/f.txt", isMainFrame: false, shouldDownload: true)) == .download)
        #expect(delegate.decide(NavigationRequest("blob:https://example.com/x", type: .other, shouldDownload: true)) == .download)
        // The policy still comes first.
        #expect(delegate.decide(NavigationRequest("file:///etc/hosts", shouldDownload: true)) == .cancel)
        // Ruling R11: a data: link marked as a download downloads; without the flag it stays refused.
        #expect(delegate.decide(NavigationRequest("data:text/csv,a,b", shouldDownload: true)) == .download)
        #expect(delegate.decide(NavigationRequest("data:text/csv,a,b", isMainFrame: false, type: .other, shouldDownload: true)) == .download)
        #expect(delegate.decide(NavigationRequest("data:text/csv,a,b")) == .cancel)
        #expect(delegate.decide(NavigationRequest("data:text/html,x", type: .other)) == .cancel)
        host.close(page.tabID)
    }

    /// A real `<a download>` blob link clicked by script lands in the downloads directory; the page stays.
    @Test func downloadLinkLandsInTheDirectory() async throws {
        let dir = try tempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        events.downloadsDirectory = dir
        let host = makeHost()
        let page = host.page(for: request(), writer: writer)
        page.webView.loadHTMLString("<title>T</title>", baseURL: URL(string: "https://example.com/"))
        let loaded = try await waitUntil { page.status.title == "T" && !page.webView.isLoading }
        #expect(loaded)
        let script = "const a = document.createElement('a'); a.href = URL.createObjectURL(new Blob(['hello'], {type: 'text/plain'})); a.download = 'note.txt'; document.body.appendChild(a); a.click(); 1"
        _ = try await page.webView.evaluateJavaScript(script)
        let finished = try await waitUntil {
            events.downloads.items(for: .profile(page.tabID)).contains { if case .finished = $0.state { true } else { false } }
        }
        #expect(finished)
        let item = try #require(events.downloads.items(for: .profile(page.tabID)).first)
        #expect(item.filename == "note.txt")
        #expect(try Data(contentsOf: dir.appendingPathComponent("note.txt")) == Data("hello".utf8))
        #expect(page.status.url == "https://example.com/")
        #expect(page.webView.title == "T")
        host.close(page.tabID)
    }

    /// Ruling R11: a real `<a download href="data:…">` clicked by script is saved, and the page stays.
    @Test func dataDownloadLinkLandsInTheDirectory() async throws {
        let dir = try tempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        events.downloadsDirectory = dir
        let host = makeHost()
        let page = host.page(for: request(), writer: writer)
        page.webView.loadHTMLString("<title>T</title>", baseURL: URL(string: "https://example.com/"))
        let loaded = try await waitUntil { page.status.title == "T" && !page.webView.isLoading }
        #expect(loaded)
        let script = "const a = document.createElement('a'); a.href = 'data:text/csv,a,b'; a.download = 'table.csv'; document.body.appendChild(a); a.click(); 1"
        _ = try await page.webView.evaluateJavaScript(script)
        let finished = try await waitUntil {
            events.downloads.items(for: .profile(page.tabID)).contains { if case .finished = $0.state { true } else { false } }
        }
        #expect(finished)
        let item = try #require(events.downloads.items(for: .profile(page.tabID)).first)
        #expect(item.filename == "table.csv")
        #expect(try Data(contentsOf: dir.appendingPathComponent("table.csv")) == Data("a,b".utf8))
        #expect(page.status.url == "https://example.com/")
        #expect(page.webView.title == "T")
        #expect(page.status.failure == nil)
        host.close(page.tabID)
    }

    // MARK: R5: a new document's URL is written on commit only

    @Test func crossDocumentURLIsWrittenOnlyOnCommit() async throws {
        let host = makeHost()
        let page = host.page(for: request(), writer: writer)
        // Each load's URL may be written only after the commit counter moved past where it was when
        // the load started; a write from the provisional url KVO would come before.
        var commitsAtStart = 0
        var newURL = ""
        var writtenEarly: [String] = []
        writer.onNavigation = { url in
            if url == newURL, page.commitCount == commitsAtStart { writtenEarly.append(url) }
        }
        let loads: [(String, () -> Void)] = [
            ("https://example.com/a", { page.webView.loadSimulatedRequest(URLRequest(url: URL(string: "https://example.com/a")!), responseHTML: "<title>A</title>") }),
            ("https://example.com/b", { page.webView.loadSimulatedRequest(URLRequest(url: URL(string: "https://example.com/b")!), responseHTML: "<title>B</title>") }),
            ("https://example.org/c", { page.webView.loadHTMLString("<title>C</title>", baseURL: URL(string: "https://example.org/c")) }),
        ]
        for (url, load) in loads {
            commitsAtStart = page.commitCount
            newURL = url
            load()
            let done = try await waitUntil { page.webView.url?.absoluteString == url && page.commitCount > commitsAtStart && !page.webView.isLoading }
            #expect(done)
            #expect(writer.calls.contains { if case .navigation(_, url, _, _) = $0 { true } else { false } })
        }
        #expect(writtenEarly.isEmpty)
        host.close(page.tabID)
    }

    // MARK: Panels

    /// Real JavaScript dialogs reach the delegate and then `events`.
    @Test func panelsGoToEvents() async throws {
        let host = makeHost()
        let page = host.page(for: request(), writer: writer)
        page.webView.loadHTMLString("<title>T</title>", baseURL: URL(string: "https://example.com/"))
        let loaded = try await waitUntil { page.status.title == "T" && !page.webView.isLoading }
        #expect(loaded)
        _ = try await page.webView.evaluateJavaScript("alert('hi'); 1")
        #expect(events.alerts == ["hi"])
        events.confirmAnswer = true
        #expect(try await page.webView.evaluateJavaScript("confirm('ok?')") as? Bool == true)
        events.promptAnswer = "x"
        #expect(try await page.webView.evaluateJavaScript("prompt('name?')") as? String == "x")
        #expect(events.dialogOrigins == ["example.com", "example.com", "example.com"])
        host.close(page.tabID)
    }

    /// A dialog from a frame is attributed to that frame, never to the top page: an opaque-origin (sandboxed srcdoc) frame names no site.
    @Test func dialogsNameTheAskingFrame() async throws {
        let host = makeHost()
        let page = host.page(for: request(), writer: writer)
        let html = "<title>T</title><iframe sandbox='allow-scripts allow-modals' srcdoc=\"<script>alert('from frame')</script>\"></iframe>"
        page.webView.loadHTMLString(html, baseURL: URL(string: "https://example.com/"))
        let asked = try await waitUntil { events.alerts.contains("from frame") }
        #expect(asked)
        #expect(events.dialogOrigins.last == .some(nil))
        host.close(page.tabID)
    }

    @Test func dialogOriginPrefersTheSecurityOrigin() {
        #expect(PageDelegate.dialogOrigin(securityHost: "ads.example.net", requestURL: URL(string: "https://example.com/")) == "ads.example.net")
        #expect(PageDelegate.dialogOrigin(securityHost: "", requestURL: URL(string: "https://frame.example.org/x")) == "frame.example.org")
        #expect(PageDelegate.dialogOrigin(securityHost: "", requestURL: URL(string: "about:srcdoc")) == nil)
        #expect(PageDelegate.dialogOrigin(securityHost: "", requestURL: nil) == nil)
    }

    // MARK: Media

    @Test func mediaUsesRememberedDecision() async throws {
        let host = makeHost()
        let profile = UUID()
        settings.setDecision(profileID: profile, host: "example.com", key: .camera, .allow)
        let page = host.page(for: request(profile: profile), writer: writer)
        let delegate = try delegate(of: page)

        #expect(await delegate.mediaDecision(originHost: "www.example.com", camera: true, microphone: false) == .grant)
        #expect(events.mediaQuestions.isEmpty)

        // Camera and microphone together need both remembered.
        events.mediaAnswer = (true, true)
        #expect(await delegate.mediaDecision(originHost: "example.com", camera: true, microphone: true) == .grant)
        #expect(events.mediaQuestions.count == 1)
        #expect(events.mediaQuestions.first?.host == "example.com")
        #expect(settings.decision(profileID: profile, host: "example.com", key: .microphone) == .allow)

        // Nothing stored: ask, and remember.
        #expect(await delegate.mediaDecision(originHost: "example.org", camera: true, microphone: false) == .grant)
        #expect(events.mediaQuestions.count == 2)
        #expect(settings.decision(profileID: profile, host: "example.org", key: .camera) == .allow)

        // Not remembered: asked again next time.
        events.mediaAnswer = (false, false)
        #expect(await delegate.mediaDecision(originHost: "example.net", camera: false, microphone: true) == .deny)
        #expect(settings.decision(profileID: profile, host: "example.net", key: .microphone) == nil)

        // Any remembered deny denies without asking.
        settings.setDecision(profileID: profile, host: "deny.example", key: .microphone, .deny)
        settings.setDecision(profileID: profile, host: "deny.example", key: .camera, .allow)
        let asked = events.mediaQuestions.count
        #expect(await delegate.mediaDecision(originHost: "deny.example", camera: true, microphone: true) == .deny)
        #expect(events.mediaQuestions.count == asked)
        host.close(page.tabID)
        await removeStore(profile)
    }

    @Test func privateWindowMediaAnswersStayInMemory() async throws {
        let host = makeHost()
        let page = host.page(for: request(), writer: writer)
        let delegate = try delegate(of: page)
        events.mediaAnswer = (true, true)
        #expect(await delegate.mediaDecision(originHost: "example.com", camera: true, microphone: false) == .grant)
        #expect(await delegate.mediaDecision(originHost: "example.com", camera: true, microphone: false) == .grant)
        #expect(events.mediaQuestions.count == 1)
        #expect(settings.values.isEmpty)
        // Another private window doesn't share the answer.
        let other = host.page(for: request(), writer: writer)
        let otherDelegate = try self.delegate(of: other)
        #expect(await otherDelegate.mediaDecision(originHost: "example.com", camera: true, microphone: false) == .grant)
        #expect(events.mediaQuestions.count == 2)
        host.close(page.tabID)
        host.close(other.tabID)
    }

    /// A closed private window's answers go: a later page on the same store key asks again.
    @Test func forgettingAPrivateWindowDropsItsMediaAnswers() async throws {
        let host = makeHost()
        let windowID = UUID()
        let make = { PageRequest(tabID: UUID(), store: .privateWindow(windowID), siteSettingsProfileID: nil, url: "", title: "", faviconURL: nil, interactionState: nil) }
        let page = host.page(for: make(), writer: writer)
        events.mediaAnswer = (true, true)
        #expect(await (try delegate(of: page)).mediaDecision(originHost: "example.com", camera: true, microphone: false) == .grant)
        #expect(await (try delegate(of: page)).mediaDecision(originHost: "example.com", camera: true, microphone: false) == .grant)
        #expect(events.mediaQuestions.count == 1)
        host.close(page.tabID)
        host.forgetPrivate(windowID: windowID)
        let again = host.page(for: make(), writer: writer)
        #expect(await (try delegate(of: again)).mediaDecision(originHost: "example.com", camera: true, microphone: false) == .grant)
        #expect(events.mediaQuestions.count == 2)
        host.close(again.tabID)
    }

    // MARK: Downloads

    @Test func downloadNamesAreSafe() throws {
        let dir = try tempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let first = PageDelegate.destination(for: "../../.zshrc", in: dir)
        #expect(first.deletingLastPathComponent().standardizedFileURL == dir.standardizedFileURL)
        #expect(first.lastPathComponent == "zshrc")
        try Data("x".utf8).write(to: first)
        let second = PageDelegate.destination(for: "../../.zshrc", in: dir)
        #expect(second.lastPathComponent == "zshrc (2)")
        #expect(second.deletingLastPathComponent().standardizedFileURL == dir.standardizedFileURL)
    }

    @Test func downloadLandsQuarantinedInTheDirectory() async throws {
        let dir = try tempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        events.downloadsDirectory = dir
        let host = makeHost()
        let page = host.page(for: request(), writer: writer)
        let delegate = try delegate(of: page)
        let source = URL(string: "data:application/octet-stream;base64,aGVsbG8=")!
        page.webView.startDownload(using: URLRequest(url: source)) { download in
            host.trackDownload(download, delegate: delegate)
        }
        let finished = try await waitUntil {
            events.downloads.items(for: .profile(page.tabID)).contains { if case .finished = $0.state { true } else { false } }
        }
        #expect(finished)
        let item = try #require(events.downloads.items(for: .profile(page.tabID)).first)
        guard case .finished(let file) = item.state else { return }
        #expect(file.deletingLastPathComponent().standardizedFileURL == dir.standardizedFileURL)
        #expect(try Data(contentsOf: file) == Data("hello".utf8))
        let values = try URL(fileURLWithPath: file.path).resourceValues(forKeys: [.quarantinePropertiesKey])
        #expect(values.quarantineProperties?[kLSQuarantineAgentNameKey as String] as? String == "Stave")
        host.close(page.tabID)
    }

    /// With no owner to file it under, the download is refused: no destination, no row.
    @Test func downloadWithNoOwnerIsRefused() async throws {
        let dir = try tempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        events.downloadsDirectory = dir
        events.hasOwner = false
        let host = makeHost()
        let page = host.page(for: request(), writer: writer)
        let delegate = try delegate(of: page)
        let download = await page.webView.startDownload(using: URLRequest(url: URL(string: "data:text/plain,abc")!))
        let destination = await delegate.download(download, decideDestinationUsing: URLResponse(), suggestedFilename: "a.txt")
        #expect(destination == nil)
        #expect(events.downloads.items(for: .profile(page.tabID)).isEmpty)
        #expect(try FileManager.default.contentsOfDirectory(atPath: dir.path).isEmpty)
        host.close(page.tabID)
    }

    /// Starts an untracked download and drives the delegate by hand, so WebKit never writes; the test writes "WebKit's" bytes itself.
    private func handDrivenDownload(_ host: PageHost, _ page: LivePage, name: String) async throws -> (row: UUID, destination: URL) {
        let delegate = try delegate(of: page)
        let download = await page.webView.startDownload(using: URLRequest(url: URL(string: "data:text/plain,abc")!))
        let destination = try #require(await delegate.download(download, decideDestinationUsing: URLResponse(), suggestedFilename: name))
        let row = try #require(events.downloads.items(for: .profile(page.tabID)).first { $0.filename == destination.lastPathComponent && $0.state == .running(fraction: nil) })
        return (row.id, destination)
    }

    /// WebKit leaves the bytes it wrote at the destination when a download is cancelled (checked against a slow local server): cancelling a
    /// row removes that exact file once WebKit's first bytes made it ours, and nothing else in the folder.
    @Test func cancellingARowRemovesItsPartialFile() async throws {
        let dir = try tempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        events.downloadsDirectory = dir
        let host = makeHost()
        let page = host.page(for: request(), writer: writer)
        let (row, destination) = try await handDrivenDownload(host, page, name: "partial.bin")
        try Data("half".utf8).write(to: destination) // what WebKit had written so far
        host.claimDownloadFile(row) // as on WebKit's first progress report
        let neighbour = dir.appendingPathComponent("keep.bin")
        try Data("keep".utf8).write(to: neighbour)
        events.downloads.cancel(row)
        #expect(!FileManager.default.fileExists(atPath: destination.path))
        #expect(FileManager.default.fileExists(atPath: neighbour.path))
        host.close(page.tabID)
    }

    /// The name a cancel freed can go to the next download of the same file; nothing left over from the cancel ever deletes that one.
    @Test func aLaterDownloadOfTheSameNameKeepsItsFile() async throws {
        let dir = try tempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        events.downloadsDirectory = dir
        let host = makeHost()
        let page = host.page(for: request(), writer: writer)
        let first = try await handDrivenDownload(host, page, name: "same.bin")
        try Data("half".utf8).write(to: first.destination)
        host.claimDownloadFile(first.row)
        events.downloads.cancel(first.row)
        let second = try await handDrivenDownload(host, page, name: "same.bin")
        #expect(second.destination == first.destination)
        try Data("second".utf8).write(to: second.destination)
        try await Task.sleep(for: .seconds(1)) // room for any late cancel completion
        #expect(try Data(contentsOf: second.destination) == Data("second".utf8))
        events.downloads.cancel(first.row) // a repeat cancel of the ended row does nothing
        #expect(FileManager.default.fileExists(atPath: second.destination.path))
        host.close(page.tabID)
    }

    /// A file at the destination that was never this download's (no bytes from WebKit seen), or that was swapped for another file after, is
    /// never deleted by a cancel.
    @Test func cancelNeverDeletesAForeignFile() async throws {
        let dir = try tempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        events.downloadsDirectory = dir
        let host = makeHost()
        let page = host.page(for: request(), writer: writer)
        let unclaimed = try await handDrivenDownload(host, page, name: "foreign.bin")
        try Data("someone else's".utf8).write(to: unclaimed.destination)
        events.downloads.cancel(unclaimed.row)
        #expect(FileManager.default.fileExists(atPath: unclaimed.destination.path))

        let swapped = try await handDrivenDownload(host, page, name: "swapped.bin")
        try Data("half".utf8).write(to: swapped.destination)
        host.claimDownloadFile(swapped.row)
        // Another file takes the path (made while the old one still exists, so it is a different file).
        let other = dir.appendingPathComponent("incoming.tmp")
        try Data("replacement".utf8).write(to: other)
        try FileManager.default.removeItem(at: swapped.destination)
        try FileManager.default.moveItem(at: other, to: swapped.destination)
        events.downloads.cancel(swapped.row)
        #expect(try Data(contentsOf: swapped.destination) == Data("replacement".utf8))
        host.close(page.tabID)
    }

    @Test func cancellingARowCancelsItsDownloadAndKeepsOtherHandlers() async throws {
        let dir = try tempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        events.downloadsDirectory = dir
        var otherCancels: [UUID] = []
        events.downloads.onCancel = { otherCancels.append($0) }
        let host = makeHost()
        let page = host.page(for: request(), writer: writer)
        let delegate = try delegate(of: page)
        // Not tracked, so WebKit never asks for a destination; the delegate is driven by hand.
        let download = await page.webView.startDownload(using: URLRequest(url: URL(string: "data:text/plain,abc")!))
        let destination = await delegate.download(download, decideDestinationUsing: URLResponse(), suggestedFilename: "a.txt")
        #expect(destination?.lastPathComponent == "a.txt")
        let row = try #require(events.downloads.items(for: .profile(page.tabID)).first)
        #expect(host.activeDownload(row.id) === download)
        events.downloads.cancel(row.id)
        #expect(otherCancels == [row.id])
        #expect(host.activeDownload(row.id) == nil)
        host.close(page.tabID)
    }
}
