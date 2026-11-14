import AppKit
import ChorusEngine
import Foundation
import StaveCore
import Testing
import WebKit

@testable import StaveWeb

/// An HTML file opened from Finder, dropped on a window or chosen with File ▸ Open File… (decision 6, question 13): it loads with read access
/// to its folder, a clicked link inside that folder opens, and nothing else on disk does. Uses a temp folder only; never the network.
@MainActor
@Suite("Opened files", .serialized)
struct OpenedFileTests {
    let writer = FakeWriter()
    let settings = FakeSiteSettings()
    let stores = WebDataStores()

    /// 1 × 1 PNG.
    static let png = Data(base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mNk+M9QDwADhgGAWjR9awAAAABJRU5ErkJggg==")!

    func makeHost() -> PageHost {
        let host = PageHost(stores: stores, contentBlocker: ContentBlockerManager(), siteSettings: settings, applicationName: "Version/17.0 Safari/605.1.15")
        // Never the real home: the temp folder must not count as home.
        host.homeDirectory = URL(fileURLWithPath: "/Users/test", isDirectory: true)
        return host
    }

    func request(_ tabID: UUID = UUID(), url: String = "", state: Data? = nil) -> PageRequest {
        PageRequest(tabID: tabID, store: .privateSession(stores.joinPrivateSession(profileID: UUID())), siteSettingsProfileID: nil, url: url, title: "", faviconURL: nil, interactionState: state, openedByUser: true)
    }

    func waitUntil(seconds: Double = 20, _ condition: () -> Bool) async throws -> Bool {
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline {
            if condition() { return true }
            try await Task.sleep(for: .milliseconds(50))
        }
        try await Task.sleep(for: .milliseconds(50))
        return condition()
    }

    /// A temp folder holding `a.html` (an image beside it and a link to `/etc/hosts`) and `b.png`. The caller removes it.
    func makeSite() throws -> URL {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("StaveOpenedFile-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let html = """
        <!doctype html><title>Invented page</title>
        <img id="sibling" src="b.png">
        <a id="outside" href="file:///etc/hosts">hosts</a>
        <a id="inside" href="c.html">c</a>
        """
        try html.write(to: folder.appendingPathComponent("a.html"), atomically: true, encoding: .utf8)
        try "<!doctype html><title>Invented sibling</title>".write(to: folder.appendingPathComponent("c.html"), atomically: true, encoding: .utf8)
        try Self.png.write(to: folder.appendingPathComponent("b.png"))
        return folder
    }

    @Test func openedFileReadsItsFolder() async throws {
        let site = try makeSite()
        defer { try? FileManager.default.removeItem(at: site) }
        let host = makeHost()
        var readAccess: [URL] = []
        let load = host.fileLoader
        host.fileLoader = { webView, file, access in
            readAccess.append(access)
            load(webView, file, access)
        }
        let page = host.page(for: request(), writer: writer)
        let file = site.appendingPathComponent("a.html")
        host.loadFile(file, in: page.tabID)

        let folder = OpenedFile.resolved(site)
        #expect(readAccess.map(\.path) == [folder.path])
        #expect(page.grantedFolder == folder.path)
        #expect(try await waitUntil { page.webView.url?.lastPathComponent == "a.html" && !page.webView.isLoading })
        #expect(page.status.failure == nil)

        // The sibling image loaded through the folder's read access.
        var width = 0
        #expect(try await waitUntil {
            page.webView.evaluateJavaScript("document.getElementById('sibling').naturalWidth") { value, _ in
                MainActor.assumeIsolated { width = (value as? Int) ?? 0 }
            }
            return width == 1
        })

        // A clicked link outside the folder is refused with the panel; inside, it opens.
        let delegate = try #require(page.webView.navigationDelegate as? PageDelegate)
        #expect(delegate.decide(NavigationRequest("file:///etc/hosts")) == .cancel)
        #expect(page.status.failure == .refused(url: "file:///etc/hosts"))
        let sibling = URL(fileURLWithPath: folder.path).appendingPathComponent("c.html").absoluteString
        #expect(delegate.decide(NavigationRequest(sibling)) == .allow)
        // A script-started file navigation is refused silently.
        page.status.failure = nil
        #expect(delegate.decide(NavigationRequest(sibling, type: .other)) == .cancel)
        #expect(page.status.failure == nil)
    }

    /// A tab whose stored address is a file shows the refused panel with "Open Again" and loads nothing; Open Again loads it through the
    /// opened-file path.
    @Test func restoredFileTabOpensAgain() async throws {
        let site = try makeSite()
        defer { try? FileManager.default.removeItem(at: site) }
        let host = makeHost()
        let file = OpenedFile.resolved(site.appendingPathComponent("a.html"))
        let page = host.page(for: request(url: file.absoluteString), writer: writer)
        #expect(page.status.failure == .fileNotReopened(url: file.absoluteString))
        #expect(PageText.offersOpenAgain(try #require(page.status.failure)))
        #expect(page.webView.url == nil)

        host.loadFile(file, in: page.tabID)
        #expect(try await waitUntil { page.webView.url?.lastPathComponent == "a.html" && !page.webView.isLoading })
        #expect(page.status.failure == nil)
    }

    /// A page with no grant (a web page) never opens a file link, with or without a click.
    @Test func webPageNeverOpensFiles() throws {
        let host = makeHost()
        let page = host.page(for: request(), writer: writer)
        let delegate = try #require(page.webView.navigationDelegate as? PageDelegate)
        #expect(page.grantedFolder == nil)
        #expect(delegate.decide(NavigationRequest("file:///etc/hosts")) == .cancel)
        #expect(page.status.failure == nil)
    }

    /// Step 1's `restoredFileTabIsRefused` at relaunch: a tab that had loaded a file comes back through its saved `interactionState`
    /// (`LivePage.restore`, then `PageDelegate.decideRestore`), not its stored address. It loads nothing and shows the refused panel with
    /// "Open Again", which loads it through the opened-file path.
    @Test func restoredFileStateOffersOpenAgain() async throws {
        let site = try makeSite()
        defer { try? FileManager.default.removeItem(at: site) }
        let host = makeHost()
        let file = OpenedFile.resolved(site.appendingPathComponent("a.html"))
        let first = host.page(for: request(), writer: writer)
        host.loadFile(file, in: first.tabID)
        #expect(try await waitUntil { first.webView.url?.lastPathComponent == "a.html" && !first.webView.isLoading })
        let state = try #require(first.webView.interactionState as? Data)
        let saved = try #require(first.webView.backForwardList.currentItem?.url.absoluteString)
        host.close(first.tabID)

        // The stored address is a web one, so only the state can bring the file back.
        let restored = host.page(for: request(url: "https://example.com/", state: state), writer: writer)
        #expect(restored.didRestoreState)
        #expect(restored.status.failure == .fileNotReopened(url: saved))
        let failure = try #require(restored.status.failure)
        #expect(PageText.offersOpenAgain(failure))
        #expect(PageText.title(failure) == PageText.title(.refused(url: saved)))
        #expect(restored.grantedFolder == nil)
        #expect(try await waitUntil { !restored.webView.isLoading })
        #expect(restored.webView.title != "Invented page")
        #expect(restored.status.failure == .fileNotReopened(url: saved))

        host.loadFile(file, in: restored.tabID)
        #expect(try await waitUntil { restored.webView.title == "Invented page" && !restored.webView.isLoading })
        #expect(restored.status.failure == nil)
    }

    /// A clicked file link inside the grant that opens a new tab (⌘-click, ⇧⌘-click, `target=_blank`) opens there through the opened-file
    /// path, as a same-tab click opens in place (decision 6). Outside the grant the refused panel shows; a script's never opens anything.
    @Test func newTabFileLinkInsideTheGrantOpens() async throws {
        let site = try makeSite()
        defer { try? FileManager.default.removeItem(at: site) }
        let host = makeHost()
        let events = FakeEvents()
        host.events = events
        let page = host.page(for: request(), writer: writer)
        host.loadFile(site.appendingPathComponent("a.html"), in: page.tabID)
        #expect(try await waitUntil { page.webView.url?.lastPathComponent == "a.html" && !page.webView.isLoading })
        let delegate = try #require(page.webView.navigationDelegate as? PageDelegate)
        let sibling = OpenedFile.resolved(site).appendingPathComponent("c.html")

        #expect(delegate.decide(NavigationRequest(sibling.absoluteString, modifiers: .command)) == .cancel)
        #expect(delegate.decide(NavigationRequest(sibling.absoluteString, modifiers: [.command, .shift])) == .cancel)
        #expect(delegate.decide(NavigationRequest(sibling.absoluteString, targetsNewWindow: true)) == .cancel)
        #expect(events.linkedFiles.map(\.select) == [false, true, true])
        #expect(events.linkedFiles.allSatisfy { $0.opener == page.tabID && $0.file.path == sibling.path })
        #expect(events.linkedTabs.isEmpty)
        #expect(page.status.failure == nil)

        // Outside the grant: the refused panel, no tab.
        #expect(delegate.decide(NavigationRequest("file:///etc/hosts", modifiers: .command)) == .cancel)
        #expect(page.status.failure == .refused(url: "file:///etc/hosts"))
        page.status.failure = nil
        #expect(delegate.decide(NavigationRequest("file:///etc/hosts", targetsNewWindow: true)) == .cancel)
        #expect(page.status.failure == .refused(url: "file:///etc/hosts"))
        // A script's new-window file navigation: silent, nothing opened.
        page.status.failure = nil
        #expect(delegate.decide(NavigationRequest(sibling.absoluteString, targetsNewWindow: true, type: .other)) == .cancel)
        #expect(page.status.failure == nil)
        #expect(events.linkedFiles.count == 3)
        #expect(events.linkedTabs.isEmpty)
    }

    /// A temp folder holding `site/a.html`, whose one link (`href`) covers the whole page, and `outside/x.html`. The caller removes it.
    func makeLinkSite(href: String) throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("StaveOpenedFile-\(UUID().uuidString)", isDirectory: true)
        let site = root.appendingPathComponent("site", isDirectory: true)
        let outside = root.appendingPathComponent("outside", isDirectory: true)
        try FileManager.default.createDirectory(at: site, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        let html = "<!doctype html><title>Invented page</title><a href=\"\(href)\" style=\"position:fixed;inset:0\">link</a>"
        try html.write(to: site.appendingPathComponent("a.html"), atomically: true, encoding: .utf8)
        try "<!doctype html><title>Invented outside</title>".write(to: outside.appendingPathComponent("x.html"), atomically: true, encoding: .utf8)
        return root
    }

    /// A page from `makeLinkSite` loaded through the opened-file path, in an on-screen window so it takes real mouse clicks.
    func openInWindow(_ root: URL, host: PageHost) async throws -> (LivePage, NSWindow) {
        let page = host.page(for: request(), writer: writer)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 400, height: 300), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = page.webView
        window.orderFrontRegardless()
        window.makeFirstResponder(page.webView)
        host.loadFile(root.appendingPathComponent("site/a.html"), in: page.tabID)
        let loaded = try await waitUntil { page.webView.url?.lastPathComponent == "a.html" && !page.webView.isLoading }
        if !loaded { close(page, window, host: host) }
        try #require(loaded, "the opened file never loaded, so no click below would mean anything")
        return (page, window)
    }

    /// Closes the page and its window at the end of a window test.
    func close(_ page: LivePage, _ window: NSWindow, host: PageHost) {
        host.close(page.tabID)
        window.contentView = nil
        window.close()
    }

    /// A real (trusted) left click in the middle of the page, as the user's mouse makes it.
    func click(_ page: LivePage, in window: NSWindow, modifiers: NSEvent.ModifierFlags = []) async throws {
        for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
            let event = try #require(NSEvent.mouseEvent(
                with: type, location: NSPoint(x: 200, y: 150), modifierFlags: modifiers, timestamp: ProcessInfo.processInfo.systemUptime,
                windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1
            ))
            if type == .leftMouseDown { page.webView.mouseDown(with: event) } else { page.webView.mouseUp(with: event) }
            try await Task.sleep(for: .milliseconds(100))
        }
    }

    /// Waits until WebKit has delivered a load failure after `before` earlier ones: the positive signal that the dropped navigation has
    /// fully played out, so a silence check after it proves the late failure was seen and showed nothing. WebKit drops a `file:` navigation
    /// outside the read access in the UI process (`WebPageProxy`, "outside the sandbox", WebKit r244670, 2019, so on macOS 15 and 26 too)
    /// and reports it as a failed provisional load. Whatever error code a runner's WebKit uses for it (`WebKitInternal`/0 on macOS 27; a
    /// policy-ignore 102 would be silent through `failure(for:)` anyway), the delivery itself is what this waits for. Returns the new failures;
    /// a runner that delivered none fails the test here instead of passing a silence check that observed nothing.
    func waitForLoadFailure(_ delegate: PageDelegate, after before: Int) async throws -> [NSError] {
        let delivered = try await waitUntil(seconds: 10) { delegate.deliveredLoadFailures.count > before }
        try #require(delivered, "WebKit delivered no load failure for the dropped navigation, so silence can't be checked")
        return Array(delegate.deliveredLoadFailures.dropFirst(before))
    }

    /// By-hand gap (fix round 2): WebKit drops a main-frame navigation to a `file:` URL outside the web process's read access before it
    /// asks the navigation delegate, so `decide` never sees the click. A user's click on such a link must still show the refused panel
    /// (decision 6), and the page stays where it was.
    @Test(arguments: ["../outside/x.html", "file:///etc/hosts"])
    func clickedLinkOutsideTheGrantShowsTheRefusedPanel(href: String) async throws {
        let root = try makeLinkSite(href: href)
        defer { try? FileManager.default.removeItem(at: root) }
        let host = makeHost()
        let (page, window) = try await openInWindow(root, host: host)
        defer { close(page, window, host: host) }
        let delegate = try #require(page.webView.navigationDelegate as? PageDelegate)
        let target = href == "file:///etc/hosts" ? href : OpenedFile.resolved(root).appendingPathComponent("outside/x.html").absoluteString
        let before = delegate.deliveredLoadFailures.count

        try await click(page, in: window)
        #expect(try await waitUntil(seconds: 5) { page.status.failure != nil })
        // Both the click report and WebKit's late failure have arrived, in whichever order: the panel is still the refused one.
        _ = try await waitForLoadFailure(delegate, after: before)
        #expect(page.status.failure == .refused(url: target))
        #expect(page.webView.url?.lastPathComponent == "a.html")
    }

    /// The click report never gets in the way of a link inside the grant: a real click on it opens it in place, with no panel.
    @Test func clickedLinkInsideTheGrantStillOpens() async throws {
        let root = try makeLinkSite(href: "b.html")
        defer { try? FileManager.default.removeItem(at: root) }
        try "<!doctype html><title>Invented sibling</title>".write(to: root.appendingPathComponent("site/b.html"), atomically: true, encoding: .utf8)
        let host = makeHost()
        let (page, window) = try await openInWindow(root, host: host)
        defer { close(page, window, host: host) }

        try await click(page, in: window)
        #expect(try await waitUntil(seconds: 5) { page.webView.title == "Invented sibling" && !page.webView.isLoading })
        #expect(page.status.failure == nil)
    }

    /// The silent side of the same gap: a script's `file:` navigation outside the grant, and a ⌘-click on such a link (report ruling: a
    /// new-tab file link outside the grant is refused silently), show no panel at all, not even WebKit's own load failure. Each silence
    /// check runs only after WebKit's failure for that navigation was delivered.
    @Test func scriptOrCommandClickOutsideTheGrantIsSilent() async throws {
        let root = try makeLinkSite(href: "../outside/x.html")
        defer { try? FileManager.default.removeItem(at: root) }
        let host = makeHost()
        let events = FakeEvents()
        host.events = events
        let (page, window) = try await openInWindow(root, host: host)
        defer { close(page, window, host: host) }
        let delegate = try #require(page.webView.navigationDelegate as? PageDelegate)

        var before = delegate.deliveredLoadFailures.count
        _ = try await page.webView.evaluateJavaScript("location.href = '../outside/x.html'; 1")
        _ = try await waitForLoadFailure(delegate, after: before)
        #expect(page.status.failure == nil)

        before = delegate.deliveredLoadFailures.count
        try await click(page, in: window, modifiers: .command)
        _ = try await waitForLoadFailure(delegate, after: before)
        #expect(page.status.failure == nil)
        #expect(events.linkedFiles.isEmpty)
        #expect(events.linkedTabs.isEmpty)
        #expect(page.webView.url?.lastPathComponent == "a.html")
    }

    /// Review fix round 3: WebKit's dropped-file failure is ignored only while a file page is committed in a tab with a grant, and only when
    /// the error names no URL. `WebKitInternal`/0 is WebKit's generic internal error: on a web page in a tab that once opened a file, or
    /// naming a URL, it still shows its panel.
    @Test func outsideReadAccessRuleIsNarrow() async throws {
        let generic = NSError(domain: "WebKitInternal", code: 0, userInfo: [NSLocalizedDescriptionKey: "Invented internal error"])
        let file = URL(fileURLWithPath: "/Users/test/site/a.html")
        let web = try #require(URL(string: "https://example.com/"))
        #expect(PageDelegate.isOutsideReadAccess(generic, grantedFolder: "/Users/test/site", currentURL: file))
        #expect(!PageDelegate.isOutsideReadAccess(generic, grantedFolder: "/Users/test/site", currentURL: web))
        #expect(!PageDelegate.isOutsideReadAccess(generic, grantedFolder: "/Users/test/site", currentURL: nil))
        #expect(!PageDelegate.isOutsideReadAccess(generic, grantedFolder: nil, currentURL: file))
        let named = NSError(domain: "WebKitInternal", code: 0, userInfo: [NSURLErrorFailingURLErrorKey: file])
        #expect(!PageDelegate.isOutsideReadAccess(named, grantedFolder: "/Users/test/site", currentURL: file))
        let namedString = NSError(domain: "WebKitInternal", code: 0, userInfo: [NSURLErrorFailingURLStringErrorKey: file.absoluteString])
        #expect(!PageDelegate.isOutsideReadAccess(namedString, grantedFolder: "/Users/test/site", currentURL: file))
        #expect(!PageDelegate.isOutsideReadAccess(NSError(domain: "WebKitInternal", code: 1), grantedFolder: "/Users/test/site", currentURL: file))

        // Through the delegate: the tab kept its grant, but its committed page is now a web one (no network: the HTML is given).
        let host = makeHost()
        let page = host.page(for: request(), writer: writer)
        defer { host.close(page.tabID) }
        let delegate = try #require(page.webView.navigationDelegate as? PageDelegate)
        page.grantedFolder = "/Users/test/site"
        page.webView.loadHTMLString("<!doctype html><title>Invented web page</title>", baseURL: web)
        try #require(try await waitUntil { page.webView.url == web && !page.webView.isLoading })
        delegate.webView(page.webView, didFailProvisionalNavigation: nil, withError: generic)
        #expect(page.status.failure == .loadFailed(host: "example.com", message: "Invented internal error"))
    }

    /// A web page (no grant) gets nothing from a new-tab file link, as before.
    @Test func newTabFileLinkFromAWebPageIsRefused() throws {
        let host = makeHost()
        let events = FakeEvents()
        host.events = events
        let page = host.page(for: request(), writer: writer)
        let delegate = try #require(page.webView.navigationDelegate as? PageDelegate)
        #expect(delegate.decide(NavigationRequest("file:///etc/hosts", modifiers: .command)) == .cancel)
        #expect(delegate.decide(NavigationRequest("file:///etc/hosts", targetsNewWindow: true)) == .cancel)
        #expect(events.linkedFiles.isEmpty)
        #expect(events.linkedTabs.isEmpty)
        #expect(page.status.failure == nil)
    }
}
