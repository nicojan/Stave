import AppKit
import ChorusEngine
import Foundation
import StaveCore
import Testing
import WebKit

@testable import StaveWeb

/// Records what the launcher seam was asked, so no test opens another app.
@MainActor
final class LauncherLog {
    var opened: [(url: URL, bundleID: String)] = []
}

/// Per-site user agent and Open in Safari / Chrome (plan 5, Task 16, decisions 24 and 25).
extension WebKitTests.PageHostTests {
    private static let applicationName = "Version/17.0 Safari/605.1.15"
    /// Chrome's string as the host builds it, on the host's test clock (so no result depends on today's date).
    private var chromeString: String { UserAgent.string(for: .chrome, applicationName: Self.applicationName, now: clock.date) ?? "" }

    private func delegate(of page: LivePage) throws -> PageDelegate {
        try #require(page.webView.navigationDelegate as? PageDelegate)
    }

    /// The stored agent goes on before the navigation to that host, and the next site gets its own (or WebKit's string): no leak.
    @Test func agentFollowsTheDestinationSite() async throws {
        let host = makeHost()
        let profile = UUID()
        settings.setSiteValue(profileID: profile, host: "example.com", key: .userAgent, "chrome")
        let page = profilePage(host, profile: profile)
        let delegate = try delegate(of: page)
        #expect(page.customUserAgent == nil)

        #expect(delegate.decide(NavigationRequest("https://example.com/a", type: .backForward)) == .allow)
        #expect(page.customUserAgent == chromeString)
        // The same key as every other site value: case, `www.` and a port are the same site.
        #expect(delegate.decide(NavigationRequest("https://WWW.Example.com:8443/b", type: .backForward)) == .allow)
        #expect(page.customUserAgent == chromeString)
        #expect(delegate.decide(NavigationRequest("https://example.org/", type: .backForward)) == .allow)
        #expect(page.customUserAgent == nil)
        // A subframe navigation never changes the page's agent.
        #expect(delegate.decide(NavigationRequest("https://example.com/frame", isMainFrame: false, type: .other)) == .allow)
        #expect(page.customUserAgent == nil)
        host.close(page.tabID)
    }

    /// A stored value no agent has (an old or hostile row) is the default.
    @Test func unknownStoredAgentIsTheDefault() async throws {
        let host = makeHost()
        let profile = UUID()
        settings.setSiteValue(profileID: profile, host: "example.com", key: .userAgent, "Netscape/1.0")
        let page = profilePage(host, profile: profile)
        #expect(try delegate(of: page).decide(NavigationRequest("https://example.com/", type: .backForward)) == .allow)
        #expect(page.customUserAgent == nil)
        host.close(page.tabID)
    }

    /// The page really reports it: `navigator.userAgent` after the commit names Chrome.
    @Test func pageReportsTheStoredAgent() async throws {
        let host = makeHost()
        let profile = UUID()
        settings.setSiteValue(profileID: profile, host: "example.com", key: .userAgent, "chrome")
        let page = profilePage(host, profile: profile)
        host.updateUserAgent(for: page, navigatingTo: "https://example.com/")
        #expect(try await commit(page, "https://example.com/"))
        let reported = try await page.webView.evaluateJavaScript("navigator.userAgent") as? String
        #expect(reported == chromeString)
        #expect(reported?.contains("Chrome/\(UserAgent.chromeMajorVersion(on: clock.date)).") == true)
        host.close(page.tabID)
    }

    /// The panel's change reaches the panel's own page at once, and Reset puts it back; the site's other pages and other sites are untouched.
    @Test func panelAgentAppliesToTheSiteAndResetClearsIt() async throws {
        let host = makeHost()
        let profile = UUID()
        let first = profilePage(host, profile: profile)
        let second = profilePage(host, profile: profile)
        let elsewhere = profilePage(host, profile: profile)
        #expect(try await commit(first, "https://example.com/a"))
        #expect(try await commit(second, "https://www.example.com/b"))
        #expect(try await commit(elsewhere, "https://example.org/"))
        let source = try #require(host.siteSource(for: first.tabID))

        source.setValue(.userAgent, "chrome")
        #expect(settings.siteValue(profileID: profile, host: "example.com", key: .userAgent, as: String.self) == "chrome")
        #expect(first.customUserAgent == chromeString)
        // Other pages of the site are left alone (their header and `navigator.userAgent` stay together); they take it on their next navigation.
        #expect(second.customUserAgent == nil)
        #expect(elsewhere.customUserAgent == nil)

        source.resetSite()
        #expect(settings.removedSites == ["\(profile)|example.com"])
        #expect(first.customUserAgent == nil)
        #expect(second.customUserAgent == nil)
        #expect(source.value(.userAgent, as: String.self) == nil)
        for page in [first, second, elsewhere] { host.close(page.tabID) }
    }

    /// A private window keeps its agent in memory and writes nothing.
    @Test func privateAgentStaysInMemory() async throws {
        let host = makeHost()
        let page = host.page(for: request(url: ""), writer: writer)
        #expect(try await commit(page, "https://example.com/"))
        let source = try #require(host.privateSiteSource(for: page.tabID))
        let model = SitePanelModel(source: source, host: "example.com", isPrivate: true)
        model.choose(.userAgent, optionID: "chrome")
        #expect(page.customUserAgent == chromeString)
        #expect(settings.siteValueWrites.isEmpty && settings.siteValues.isEmpty)
        // The next navigation in the session keeps it, another site doesn't.
        let delegate = try delegate(of: page)
        #expect(delegate.decide(NavigationRequest("https://example.com/c", type: .backForward)) == .allow)
        #expect(page.customUserAgent == chromeString)
        #expect(delegate.decide(NavigationRequest("https://example.net/", type: .backForward)) == .allow)
        #expect(page.customUserAgent == nil)
        host.close(page.tabID)
    }

    // MARK: Open in Safari / Chrome

    private func launcher(installed: Set<String>, log: LauncherLog) -> BrowserLauncher {
        BrowserLauncher(
            isInstalled: { installed.contains($0) },
            open: { url, bundleID in MainActor.assumeIsolated { log.opened.append((url, bundleID)) } }
        )
    }

    @Test func openElsewhereOffersOnlyInstalledApps() async throws {
        let host = makeHost()
        let log = LauncherLog()
        host.browserLauncher = launcher(installed: ["com.google.Chrome", "org.mozilla.firefox"], log: log)
        #expect(host.installedBrowsers() == [.chrome])
        host.browserLauncher = launcher(installed: [], log: log)
        #expect(host.installedBrowsers().isEmpty)
        host.browserLauncher = launcher(installed: ["com.apple.Safari", "com.google.Chrome"], log: log)
        #expect(host.installedBrowsers() == [.safari, .chrome])
    }

    /// Only the page's current web address goes to the app; a missing app, a blank tab and a file do nothing.
    @Test func openElsewherePassesOnlyTheCurrentAddress() async throws {
        let host = makeHost()
        let log = LauncherLog()
        host.browserLauncher = launcher(installed: ["com.google.Chrome"], log: log)
        let page = profilePage(host, profile: UUID())
        host.openElsewhere(.chrome, tabID: page.tabID) // blank tab
        #expect(log.opened.isEmpty)
        #expect(try await commit(page, "https://example.com/a?b=1"))
        host.openElsewhere(.safari, tabID: page.tabID) // not installed
        #expect(log.opened.isEmpty)
        host.openElsewhere(.chrome, tabID: page.tabID)
        #expect(log.opened.count == 1)
        #expect(log.opened.first?.url.absoluteString == "https://example.com/a?b=1")
        #expect(log.opened.first?.bundleID == "com.google.Chrome")
        host.openElsewhere(.chrome, tabID: UUID()) // unknown tab
        #expect(log.opened.count == 1)

        // The panel offers the installed app and opens through the same path.
        let model = try #require(host.sitePanelModel(for: page.tabID))
        #expect(model.openElsewhere == [.chrome])
        model.open(in: .chrome)
        #expect(log.opened.count == 2)
        model.open(in: .safari)
        #expect(log.opened.count == 2)

        let file = host.page(for: request(url: ""), writer: writer)
        host.openElsewhere(.chrome, tabID: file.tabID)
        #expect(log.opened.count == 2)
        for each in [page, file] { host.close(each.tabID) }
    }
}
