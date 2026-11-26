import AppKit
import ChorusEngine
import Foundation
import StaveCore
import Testing
import WebKit

@testable import StaveWeb

/// The per-site panel's sources (plan 5, Task 13): a profile's wraps the settings source, a private session's keeps memory only; both apply
/// a change to the host's live pages at once.
extension WebKitTests.PageHostTests {
    private func panelHost() -> (PageHost, FakeEvents) {
        let host = makeHost()
        let events = FakeEvents()
        host.events = events
        events.host = host
        return (host, events)
    }

    private func committedPrivatePage(_ host: PageHost, _ url: String) async throws -> LivePage {
        let page = host.page(for: request(url: ""), writer: writer)
        #expect(try await commit(page, url))
        return page
    }

    /// Review Focus: a private panel edits memory only. A Block set there shows in the panel and is honoured by the next camera request
    /// from that host, and nothing reaches the settings source (the store's `siteSetting` and `siteValue` tables).
    @Test func privatePanelEditsMemoryOnly() async throws {
        let (host, events) = panelHost()
        let page = try await committedPrivatePage(host, "https://example.com/a")
        let delegate = try #require(page.webView.navigationDelegate as? PageDelegate)
        let source = try #require(host.privateSiteSource(for: page.tabID))
        let model = SitePanelModel(source: source, host: "example.com")

        model.set(.camera, .block)
        #expect(model.rows.first { $0.kind == .permission(.camera) }?.selectedID == "block")
        events.mediaAnswer = (true, true)
        #expect(await delegate.decideMedia(originHost: "example.com", camera: true, microphone: false) == .deny)
        #expect(events.mediaQuestions.isEmpty)

        model.setZoom(1.5)
        #expect(page.zoom == 1.5 && page.webView.pageZoom == 1.5)
        model.set(.contentBlocking, .block)
        #expect(!page.isContentBlockingOn)
        #expect(settings.values.isEmpty)
        #expect(settings.siteValues.isEmpty && settings.siteValueWrites.isEmpty)
        host.close(page.tabID)
    }

    private func sessionPage(_ host: PageHost, profile: UUID, _ url: String) async throws -> LivePage {
        let session = host.joinPrivateSession(profileID: profile)
        let page = host.page(for: PageRequest(tabID: UUID(), store: .privateSession(session), siteSettingsProfileID: nil, url: "", title: "", faviconURL: nil, interactionState: nil), writer: writer)
        #expect(try await commit(page, url))
        return page
    }

    /// A private panel's answers belong to its session: another private session never sees them, and the session's end drops them (read
    /// back through the same source after `leavePrivateSession`, so a kept answer would show).
    @Test func privatePanelAnswersStayInTheirSession() async throws {
        let (host, _) = panelHost()
        let profileA = UUID()
        let profileB = UUID()
        let page = try await sessionPage(host, profile: profileA, "https://example.com/a")
        let other = try await sessionPage(host, profile: profileB, "https://example.com/b")
        let source = try #require(host.privateSiteSource(for: page.tabID))
        let otherSource = try #require(host.privateSiteSource(for: other.tabID))
        source.set(.microphone, .allow)
        source.set(.contentBlocking, .block)
        source.setValue(.zoom, 1.5)
        #expect(source.choice(.microphone) == .allow && source.choice(.contentBlocking) == .block)
        #expect(source.value(.zoom, as: Double.self) == 1.5)
        #expect(otherSource.choice(.microphone) == .ask && otherSource.choice(.contentBlocking) == .ask)
        #expect(otherSource.value(.zoom, as: Double.self) == nil)
        #expect(other.zoom == 1.0 && other.isContentBlockingOn)

        for each in [page, other] { host.close(each.tabID) }
        host.leavePrivateSession(profileID: profileA)
        #expect(source.choice(.microphone) == .ask)
        #expect(source.choice(.contentBlocking) == .ask)
        #expect(source.value(.zoom, as: Double.self) == nil)
        host.leavePrivateSession(profileID: profileB)
    }

    /// Decision 32: a Block set in the panel is remembered, and the page's next camera or microphone request is denied with no question,
    /// even though the user would now say yes. Ask puts the question back.
    @Test func blockIsRemembered() async throws {
        let (host, events) = panelHost()
        let profile = UUID()
        let page = profilePage(host, profile: profile)
        #expect(try await commit(page, "https://example.com/meet"))
        let delegate = try #require(page.webView.navigationDelegate as? PageDelegate)
        let source = try #require(host.siteSource(for: page.tabID))
        let model = SitePanelModel(source: source, host: "example.com")
        model.set(.camera, .block)
        model.set(.microphone, .block)
        #expect(settings.decision(profileID: profile, host: "example.com", key: .camera) == .deny)
        events.mediaAnswer = (true, true)
        #expect(await delegate.decideMedia(originHost: "example.com", camera: true, microphone: true) == .deny)
        #expect(events.mediaQuestions.isEmpty)
        model.set(.camera, .ask)
        model.set(.microphone, .ask)
        #expect(await delegate.decideMedia(originHost: "example.com", camera: true, microphone: true) == WKPermissionDecision.grant)
        #expect(events.mediaQuestions.count == 1)
        host.close(page.tabID)
    }

    /// The panel's site is the address the page shows (`status.url`), the same field the menu and the button read.
    @Test func panelSiteFollowsTheShownAddress() async throws {
        let (host, _) = panelHost()
        let page = profilePage(host, profile: UUID())
        #expect(try await commit(page, "https://example.com/a"))
        #expect(host.sitePanelModel(for: page.tabID)?.host == "example.com")
        #expect(try await commit(page, "https://example.org/b"))
        #expect(page.panelSiteKey == SitePanelSite.host(forPageURL: page.status.url))
        #expect(host.sitePanelModel(for: page.tabID)?.host == "example.org")
        host.close(page.tabID)
    }

    /// R1-H2: the panel's host and the pages a change applies to both come from the address the page shows (`status.url`), even when the
    /// web view's own document differs (a crashed or refused-restore page). Here the web view holds example.com, the page shows example.org.
    @Test func panelAppliesToThePagesItShows() async throws {
        let (host, _) = panelHost()
        let profile = UUID()
        let page = profilePage(host, profile: profile)
        #expect(try await commit(page, "https://example.com/a"))
        page.status.url = "https://example.org/shown"
        #expect(page.siteKey == "example.com")
        let model = try #require(host.sitePanelModel(for: page.tabID))
        #expect(model.host == "example.org")
        model.setZoom(1.5)
        #expect(page.zoom == 1.5)
        model.set(.contentBlocking, .block)
        #expect(!page.isContentBlockingOn)
        model.set(.contentBlocking, .ask)
        #expect(page.isContentBlockingOn)
        host.close(page.tabID)
    }

    /// The panel's own page switches blocking as the View menu does, even when it shares its opener's content controller; other pages that
    /// share a controller keep their lists (ruling R10, R1-H1): the lists would switch for the other page too, which may be on another site.
    @Test func panelBlockingSkipsPagesSharingAController() async throws {
        let (host, _) = panelHost()
        let profile = UUID()
        let opener = profilePage(host, profile: profile)
        #expect(try await commit(opener, "https://example.com/a"))
        let linkedView = WKWebView(frame: .zero, configuration: opener.webView.configuration)
        let linked = host.adopt(linkedView, as: PageRequest(tabID: UUID(), store: opener.store, siteSettingsProfileID: profile, url: "", title: "", faviconURL: nil, interactionState: nil), writer: writer)
        #expect(try await commit(linked, "https://example.org/b"))
        // Control: the two really share one controller, and a page of its own would switch.
        #expect(linked.webView.configuration.userContentController === opener.webView.configuration.userContentController)
        let alone = profilePage(host, profile: profile)
        #expect(try await commit(alone, "https://example.net/c"))

        let openerSource = try #require(host.siteSource(for: opener.tabID))
        let aloneSource = try #require(host.siteSource(for: alone.tabID))
        openerSource.set(.contentBlocking, .block)
        #expect(settings.decision(profileID: profile, host: "example.com", key: .contentBlocking) == .deny)
        // R1-H1: the panel's own page switches exactly as the View menu does, even sharing a controller; the other sharer keeps a stale flag (the shared controller lost its lists).
        #expect(!opener.isContentBlockingOn)
        #expect(linked.isContentBlockingOn)
        aloneSource.set(.contentBlocking, .block)
        #expect(!alone.isContentBlockingOn)
        for each in [opener, linked, alone] { host.close(each.tabID) }
    }

    /// R2-M1: a second page on the SAME site sharing the controller is in `sitePages`, so only the R10 skip leaves it unchanged.
    @Test func panelBlockingSkipsSameSitePageSharingAController() async throws {
        let (host, _) = panelHost()
        let profile = UUID()
        let opener = profilePage(host, profile: profile)
        #expect(try await commit(opener, "https://example.com/a"))
        let linkedView = WKWebView(frame: .zero, configuration: opener.webView.configuration)
        let linked = host.adopt(linkedView, as: PageRequest(tabID: UUID(), store: opener.store, siteSettingsProfileID: profile, url: "", title: "", faviconURL: nil, interactionState: nil), writer: writer)
        #expect(try await commit(linked, "https://example.com/b"))
        #expect(linked.webView.configuration.userContentController === opener.webView.configuration.userContentController)
        let before = linked.isContentBlockingOn

        let openerSource = try #require(host.siteSource(for: opener.tabID))
        openerSource.set(.contentBlocking, .block)
        #expect(!opener.isContentBlockingOn)
        #expect(linked.isContentBlockingOn == before)
        for each in [opener, linked] { host.close(each.tabID) }
    }

    @Test func panelSourcesFollowTheKindOfPage() async throws {
        let (host, _) = panelHost()
        let profile = UUID()
        let normal = profilePage(host, profile: profile)
        #expect(try await commit(normal, "https://example.com/"))
        // A profile page has no private source; a page with no web site has none of either.
        #expect(host.privateSiteSource(for: normal.tabID) == nil)
        #expect(host.siteSource(for: normal.tabID) != nil)
        let blank = host.page(for: request(url: ""), writer: writer)
        #expect(host.siteSource(for: blank.tabID) == nil)
        #expect(host.privateSiteSource(for: blank.tabID) == nil)
        #expect(host.siteSource(for: UUID()) == nil)
        for page in [normal, blank] { host.close(page.tabID) }
    }

    /// A profile's panel writes through the settings source; Ask removes the row again.
    @Test func profilePanelWritesAndAskRemovesTheRow() async throws {
        let (host, _) = panelHost()
        let profile = UUID()
        let page = profilePage(host, profile: profile)
        #expect(try await commit(page, "https://www.example.com/"))
        let source = try #require(host.siteSource(for: page.tabID))
        source.set(.camera, .block)
        #expect(settings.decision(profileID: profile, host: "example.com", key: .camera) == .deny)
        #expect(source.choice(.camera) == .block)
        source.set(.camera, .allow)
        #expect(settings.decision(profileID: profile, host: "example.com", key: .camera) == .allow)
        source.set(.camera, .ask)
        #expect(settings.decision(profileID: profile, host: "example.com", key: .camera) == nil)
        #expect(source.choice(.camera) == .ask)
        host.close(page.tabID)
    }

    /// Zoom from the panel applies to every open page of the site and profile at once, and is stored; 100 % removes the row.
    @Test func panelZoomAppliesAtOnce() async throws {
        let (host, _) = panelHost()
        let profile = UUID()
        let first = profilePage(host, profile: profile)
        let second = profilePage(host, profile: profile)
        let elsewhere = profilePage(host, profile: profile)
        #expect(try await commit(first, "https://example.com/a"))
        #expect(try await commit(second, "https://example.com/b"))
        #expect(try await commit(elsewhere, "https://example.org/"))
        let model = SitePanelModel(source: try #require(host.siteSource(for: first.tabID)), host: "example.com")
        model.setZoom(1.75)
        #expect(first.webView.pageZoom == 1.75 && second.webView.pageZoom == 1.75)
        #expect(elsewhere.webView.pageZoom == 1.0)
        #expect(settings.zoom(profileID: profile, host: "example.com") == 1.75)
        model.setZoom(1.0)
        #expect(first.webView.pageZoom == 1.0 && second.zoom == 1.0)
        #expect(settings.siteValues.isEmpty)
        for page in [first, second, elsewhere] { host.close(page.tabID) }
    }

    /// Content blocking Off from the panel is stored as a deny and switches the site's pages; On (Ask) removes the row and switches back.
    @Test func panelContentBlockingSwitchesThePagesOfTheSite() async throws {
        let (host, _) = panelHost()
        let profile = UUID()
        let page = profilePage(host, profile: profile)
        let elsewhere = profilePage(host, profile: profile)
        #expect(try await commit(page, "https://example.com/"))
        #expect(try await commit(elsewhere, "https://example.org/"))
        let source = try #require(host.siteSource(for: page.tabID))
        source.set(.contentBlocking, .block)
        #expect(settings.decision(profileID: profile, host: "example.com", key: .contentBlocking) == .deny)
        #expect(!page.isContentBlockingOn)
        #expect(elsewhere.isContentBlockingOn)
        source.set(.contentBlocking, .ask)
        #expect(settings.decision(profileID: profile, host: "example.com", key: .contentBlocking) == nil)
        #expect(page.isContentBlockingOn)
        for each in [page, elsewhere] { host.close(each.tabID) }
    }

    /// Reset This Site removes every stored key for the host through one `removeSite` call (not key by key), leaves other hosts and
    /// profiles alone, and puts the host's live pages back to 100 % with blocking on.
    @Test func panelResetSiteClearsEveryKey() async throws {
        let (host, _) = panelHost()
        let profile = UUID()
        let other = UUID()
        settings.setDecision(profileID: other, host: "example.com", key: .camera, .allow)
        settings.setDecision(profileID: profile, host: "example.org", key: .camera, .allow)
        let page = profilePage(host, profile: profile)
        #expect(try await commit(page, "https://example.com/"))
        let source = try #require(host.siteSource(for: page.tabID))
        source.set(.camera, .allow)
        source.set(.microphone, .block)
        source.set(.contentBlocking, .block)
        source.setValue(.zoom, 2.0)
        source.setValue(.userAgent, "Invented UA")
        #expect(page.zoom == 2.0 && !page.isContentBlockingOn)
        let writesBefore = settings.siteValueWrites.count

        source.resetSite()
        #expect(settings.removedSites == ["\(profile)|example.com"])
        #expect(settings.siteValueWrites.count == writesBefore)
        for key in SitePanelKey.allCases { #expect(source.choice(key) == .ask) }
        #expect(source.value(.zoom, as: Double.self) == nil)
        #expect(source.value(.userAgent, as: String.self) == nil)
        #expect(page.zoom == 1.0 && page.webView.pageZoom == 1.0)
        #expect(page.isContentBlockingOn)
        #expect(settings.decision(profileID: other, host: "example.com", key: .camera) == .allow)
        #expect(settings.decision(profileID: profile, host: "example.org", key: .camera) == .allow)
        host.close(page.tabID)
    }

    /// A private reset clears the session's memory for the host and touches no settings source.
    @Test func privateResetSiteClearsMemoryOnly() async throws {
        let (host, _) = panelHost()
        let page = try await committedPrivatePage(host, "https://example.com/")
        let source = try #require(host.privateSiteSource(for: page.tabID))
        source.set(.camera, .allow)
        source.setValue(.zoom, 1.5)
        source.resetSite()
        #expect(source.choice(.camera) == .ask)
        #expect(source.value(.zoom, as: Double.self) == nil)
        #expect(page.zoom == 1.0)
        #expect(settings.removedSites.isEmpty && settings.values.isEmpty && settings.siteValueWrites.isEmpty)
        host.close(page.tabID)
    }
}
