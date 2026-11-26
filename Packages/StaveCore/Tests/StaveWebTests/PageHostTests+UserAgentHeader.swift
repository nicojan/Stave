import AppKit
import ChorusEngine
import Foundation
import StaveCore
import Testing
import WebKit

@testable import StaveWeb

/// Task 16 fix round 1: the HTTP User-Agent header a real listener sees (H1), the agent put back when a navigation doesn't commit (M2),
/// and what Open in Safari / Chrome hands over (M3, M4). On macOS 27 WebKit builds the header after the navigation policy runs, so the
/// header checks pass there even without the fix; the checks that read `customUserAgent` right after a Stave-started load fail without it
/// on any system. A page-started navigation into a configured site carries the previous agent in its first request on macOS 15 and 26
/// (WebKit bug 313542, accepted), so its header is asserted from macOS 27 only.
extension WebKitTests.PageHostTests {
    private var chrome: String { UserAgent.string(for: .chrome, applicationName: "Version/17.0 Safari/605.1.15", now: clock.date) ?? "" }

    private func storedChrome(_ host: String) -> UUID {
        let profile = UUID()
        settings.setSiteValue(profileID: profile, host: host, key: .userAgent, "chrome")
        return profile
    }

    private func waitForRequest(_ server: LoopbackServer, _ path: String) async throws -> LoopbackServer.Request? {
        _ = try await waitUntil { !server.requests(for: path).isEmpty }
        return server.requests(for: path).first
    }

    private func recordingLauncher(_ log: LauncherLog) -> BrowserLauncher {
        BrowserLauncher(isInstalled: { _ in true }, open: { url, bundleID in MainActor.assumeIsolated { log.opened.append((url, bundleID)) } })
    }

    // MARK: H1, loads Stave starts

    @Test func typedLoadCarriesTheSitesAgent() async throws {
        let server = try await LoopbackServer()
        defer { server.stop() }
        let host = makeHost()
        let page = profilePage(host, profile: storedChrome("127.0.0.1"))
        host.loadTyped(server.url("/typed"), in: page.tabID)
        // Set before the load starts, not by the policy check.
        #expect(page.customUserAgent == chrome)
        let request = try await waitForRequest(server, "/typed")
        #expect(request?.userAgent == chrome)
        host.close(page.tabID)
    }

    @Test func storedAddressLoadCarriesTheSitesAgent() async throws {
        let server = try await LoopbackServer()
        defer { server.stop() }
        let host = makeHost()
        var stored = request(url: server.url("/stored"))
        stored.siteSettingsProfileID = storedChrome("127.0.0.1")
        let page = host.page(for: stored, writer: writer)
        #expect(page.customUserAgent == chrome)
        let seen = try await waitForRequest(server, "/stored")
        #expect(seen?.userAgent == chrome)
        host.close(page.tabID)
    }

    // MARK: H1, loads a page starts

    /// A link from one host to another whose agent differs: the request that reaches the listener carries the destination's agent.
    @Test func crossHostLinkCarriesTheDestinationsAgent() async throws {
        let server = try await LoopbackServer()
        defer { server.stop() }
        let host = makeHost()
        let page = profilePage(host, profile: storedChrome("localhost"))
        host.loadTyped(server.url("/link"), in: page.tabID)
        _ = try await waitUntil { page.commitCount > 0 && !page.webView.isLoading }
        #expect(server.requests(for: "/link").first?.userAgent != chrome)
        _ = try await page.webView.evaluateJavaScript("document.getElementById('go').click()")
        let next = try await waitForRequest(server, "/next")
        #expect(next?.host == "localhost:\(server.port)")
        // The first request of a page-started navigation is built before the policy sets the agent on macOS 15 and 26 (bug 313542, fixed in
        // 27), so its header is only asserted where the fix is.
        if ProcessInfo.processInfo.isOperatingSystemAtLeast(OperatingSystemVersion(majorVersion: 27, minorVersion: 0, patchVersion: 0)) {
            #expect(next?.userAgent == chrome)
        }
        // The page itself reports the destination's agent on every system.
        _ = try await waitUntil { page.commitCount > 1 && !page.webView.isLoading }
        let reported = try await page.webView.evaluateJavaScript("navigator.userAgent") as? String
        #expect(reported == chrome)
        host.close(page.tabID)
    }

    /// Back, reload and resubmission are allowed and set the destination's agent like any main-frame navigation; a destination with no stored
    /// agent goes back to the default.
    @Test func otherNavigationsSetTheAgentToo() async throws {
        let host = makeHost()
        let page = profilePage(host, profile: storedChrome("example.com"))
        let delegate = try #require(page.webView.navigationDelegate as? PageDelegate)
        for type in [WKNavigationType.backForward, .reload, .formResubmitted] {
            page.setUserAgent(nil)
            #expect(delegate.decide(NavigationRequest("https://example.com/h", type: type)) == .allow)
            #expect(page.customUserAgent == chrome)
        }
        #expect(delegate.decide(NavigationRequest("https://example.org/", type: .linkActivated)) == .allow)
        #expect(page.customUserAgent == nil)
        host.close(page.tabID)
    }

    /// A `#fragment` click on the page already shown loads nothing, so it leaves the agent alone; the same address without one is a real
    /// navigation again.
    @Test func fragmentLinkLeavesTheAgentAlone() async throws {
        let server = try await LoopbackServer()
        defer { server.stop() }
        let host = makeHost()
        let page = profilePage(host, profile: storedChrome("localhost"))
        let address = server.url(host: "localhost", "/ok")
        host.loadTyped(address, in: page.tabID)
        _ = try await waitUntil { page.commitCount > 0 && !page.webView.isLoading }
        page.setUserAgent(nil)
        let delegate = try #require(page.webView.navigationDelegate as? PageDelegate)
        #expect(delegate.decide(NavigationRequest(address + "#section", type: .linkActivated)) == .allow)
        #expect(page.customUserAgent == nil)
        #expect(delegate.decide(NavigationRequest(address, type: .linkActivated)) == .allow)
        #expect(page.customUserAgent == chrome)
        host.close(page.tabID)
    }

    // MARK: M2

    /// The page keeps showing its site when a navigation to another is stopped or fails: its agent goes back on.
    @Test func agentGoesBackWhenANavigationDoesNotCommit() async throws {
        let host = makeHost()
        let page = profilePage(host, profile: storedChrome("example.org"))
        let delegate = try #require(page.webView.navigationDelegate as? PageDelegate)
        #expect(try await commit(page, "https://example.com/"))
        #expect(delegate.decide(NavigationRequest("https://example.org/", type: .backForward)) == .allow)
        #expect(page.customUserAgent == chrome)
        delegate.provisionalNavigationFailed(nil, error: NSError(domain: NSURLErrorDomain, code: NSURLErrorCannotConnectToHost))
        #expect(page.customUserAgent == nil)

        // A stop (a cancel of the current navigation) too.
        #expect(delegate.decide(NavigationRequest("https://example.org/", type: .backForward)) == .allow)
        #expect(page.customUserAgent == chrome)
        let navigation = ObjectIdentifier(page)
        delegate.navigationStarted(navigation)
        delegate.provisionalNavigationFailed(navigation, error: NSError(domain: NSURLErrorDomain, code: NSURLErrorCancelled))
        #expect(page.customUserAgent == nil)
        host.close(page.tabID)
    }

    /// The shown page's address, not the pending typed one the web view reports, decides the agent put back when that load is stopped.
    @Test func stoppedLoadPutsBackTheShownPagesAgent() async throws {
        let server = try await LoopbackServer()
        defer { server.stop() }
        let host = makeHost()
        let page = profilePage(host, profile: storedChrome("localhost"))
        host.loadTyped(server.url(host: "localhost", "/ok"), in: page.tabID)
        _ = try await waitUntil { page.commitCount > 0 && !page.webView.isLoading }
        #expect(page.customUserAgent == chrome)
        host.loadTyped(server.url("/hang"), in: page.tabID)
        _ = try await waitForRequest(server, "/hang")
        #expect(page.customUserAgent == nil)
        // While the typed load is really pending the web view reports it as its address; the failure still names the committed page's site.
        #expect(page.webView.url?.absoluteString == server.url("/hang"))
        let delegate = try #require(page.webView.navigationDelegate as? PageDelegate)
        delegate.provisionalNavigationFailed(nil, error: NSError(domain: NSURLErrorDomain, code: NSURLErrorNetworkConnectionLost))
        #expect(page.customUserAgent == chrome)
        // And a real stop ends the pending load the same way.
        host.loadTyped(server.url("/hang2"), in: page.tabID)
        _ = try await waitForRequest(server, "/hang2")
        #expect(page.customUserAgent == nil)
        page.webView.stopLoading()
        #expect(try await waitUntil { page.customUserAgent == chrome })
        host.close(page.tabID)
    }

    // MARK: M3

    @Test func privateWindowsOfferNoOpenElsewhere() async throws {
        let host = makeHost()
        let log = LauncherLog()
        host.browserLauncher = recordingLauncher(log)
        let page = host.page(for: request(url: ""), writer: writer)
        #expect(try await commit(page, "https://example.com/a"))
        host.openElsewhere(.chrome, tabID: page.tabID)
        #expect(log.opened.isEmpty)
        #expect(host.privateSiteSource(for: page.tabID) != nil)
        let model = try #require(host.privateSiteSource(for: page.tabID).map {
            SitePanelModel(source: $0, host: "example.com", isPrivate: true, openElsewhere: [.chrome], openIn: { _ in log.opened.append((URL(fileURLWithPath: "/"), "")) })
        })
        #expect(model.openElsewhere.isEmpty)
        model.open(in: .chrome)
        #expect(log.opened.isEmpty)
        host.close(page.tabID)
    }

    // MARK: M4

    /// A typed address still loading is never what Open in hands over: the committed page's address is.
    @Test func openElsewhereIgnoresAPendingTypedAddress() async throws {
        let server = try await LoopbackServer()
        defer { server.stop() }
        let host = makeHost()
        let log = LauncherLog()
        host.browserLauncher = recordingLauncher(log)
        let page = profilePage(host, profile: UUID())
        #expect(try await commit(page, "https://example.com/committed"))
        host.loadTyped(server.url("/hang"), in: page.tabID)
        _ = try await waitForRequest(server, "/hang")
        host.openElsewhere(.chrome, tabID: page.tabID)
        #expect(log.opened.map(\.url.absoluteString) == ["https://example.com/committed"])
        host.close(page.tabID)
    }
}
