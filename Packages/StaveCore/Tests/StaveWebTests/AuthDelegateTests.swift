import Foundation
import StaveCore
import Testing
import WebKit

@testable import StaveWeb

/// A sender for a hand-made challenge. Nothing here is called: the delegate answers through its completion value.
final class ChallengeSender: NSObject, URLAuthenticationChallengeSender, @unchecked Sendable {
    func use(_ credential: URLCredential, for challenge: URLAuthenticationChallenge) {}
    func continueWithoutCredential(for challenge: URLAuthenticationChallenge) {}
    func cancel(_ challenge: URLAuthenticationChallenge) {}
}

/// HTTP auth through the delegate's own method (plan 5, Task 11). Hand-made challenges, so nothing loads and nothing touches the network.
extension WebKitTests.PageDelegateTests {
    func challenge(host: String, port: Int = 443, scheme: String = "https", realm: String? = "test", method: String = NSURLAuthenticationMethodHTTPBasic, failures: Int = 0) -> URLAuthenticationChallenge {
        let space = URLProtectionSpace(host: host, port: port, protocol: scheme, realm: realm, authenticationMethod: method)
        return URLAuthenticationChallenge(protectionSpace: space, proposedCredential: nil, previousFailureCount: failures, failureResponse: nil, error: nil, sender: ChallengeSender())
    }

    func proxyChallenge(host: String) -> URLAuthenticationChallenge {
        let space = URLProtectionSpace(proxyHost: host, port: 8080, type: NSURLProtectionSpaceHTTPProxy, realm: "proxy", authenticationMethod: NSURLAuthenticationMethodHTTPBasic)
        return URLAuthenticationChallenge(protectionSpace: space, proposedCredential: nil, previousFailureCount: 0, failureResponse: nil, error: nil, sender: ChallengeSender())
    }

    /// A page on `top` with its delegate, ready to answer challenges.
    func authPage(top: String = "https://example.com/") throws -> (host: PageHost, page: LivePage, delegate: PageDelegate) {
        let host = makeHost()
        let page = host.page(for: request(), writer: writer)
        let delegate = try delegate(of: page)
        delegate.currentTopURL = { URL(string: top) }
        return (host, page, delegate)
    }

    /// Review Focus 6: the sheet names the frame that asks, never the top page. A subframe on example.org inside example.com.
    @Test func authNamesTheAskingFrame() async throws {
        let (host, page, delegate) = try authPage()
        events.authAnswer = AuthAnswer(user: "ann", password: "secret")
        #expect(delegate.decide(NavigationRequest("https://example.org/frame", isMainFrame: false, type: .other)) == .allow)
        let (disposition, credential) = await delegate.webView(page.webView, respondTo: challenge(host: "example.org"))
        #expect(events.authQuestions.count == 1)
        let asked = try #require(events.authQuestions.first)
        #expect(asked.challenge.host == "example.org")
        #expect(AuthText.title(for: asked.challenge) == "example.org wants you to sign in")
        #expect(asked.tabID == page.tabID)
        #expect(disposition == .useCredential)
        #expect(credential?.user == "ann")
        #expect(credential?.password == "secret")
        // Ruling H1: for the session, in memory, as Safari without "remember": the sheet doesn't come back for every subresource.
        #expect(credential?.persistence == URLCredential.Persistence.forSession)
        host.close(page.tabID)
    }

    @Test func theTopSitesOwnChallengeAsksWithItsRealmAndFailureCount() async throws {
        let (host, page, delegate) = try authPage()
        events.authAnswer = AuthAnswer(user: "a", password: "b")
        _ = await delegate.webView(page.webView, respondTo: challenge(host: "example.com", port: 8443, realm: "Staff", failures: 1))
        let asked = try #require(events.authQuestions.first?.challenge)
        #expect(asked == AuthChallenge(host: "example.com:8443", realm: "Staff", isProxy: false, previousFailureCount: 1))
        host.close(page.tabID)
    }

    /// `www.` doesn't make the top site a stranger.
    @Test func wwwOfTheTopSiteAsks() async throws {
        let (host, page, delegate) = try authPage()
        events.authAnswer = AuthAnswer(user: "a", password: "b")
        _ = await delegate.webView(page.webView, respondTo: challenge(host: "www.example.com"))
        #expect(events.authQuestions.first?.challenge.host == "www.example.com")
        host.close(page.tabID)
    }

    /// A main-frame navigation the delegate allowed to another site is the one asking, though the old page is still the top document.
    @Test func pendingMainFrameNavigationAsks() async throws {
        let (host, page, delegate) = try authPage()
        events.authAnswer = AuthAnswer(user: "a", password: "b")
        #expect(delegate.decide(NavigationRequest("https://example.net/private", type: .linkActivated)) == .allow)
        _ = await delegate.webView(page.webView, respondTo: challenge(host: "example.net"))
        #expect(events.authQuestions.first?.challenge.host == "example.net")
        host.close(page.tabID)
    }

    /// An image or script from another site that answers 401 is neither the page nor a frame Stave allowed: no sheet over the page.
    @Test func crossSiteSubresourceDoesNotAsk() async throws {
        let (host, page, delegate) = try authPage()
        events.authAnswer = AuthAnswer(user: "a", password: "b")
        let (disposition, credential) = await delegate.webView(page.webView, respondTo: challenge(host: "example.org"))
        #expect(events.authQuestions.isEmpty)
        #expect(disposition == .rejectProtectionSpace)
        #expect(credential == nil)
        host.close(page.tabID)
    }

    /// A frame the policy refused never asked anything, so its host can't ask either.
    @Test func aRefusedFrameDoesNotAsk() async throws {
        let (host, page, delegate) = try authPage()
        #expect(delegate.decide(NavigationRequest("javascript:alert(1)", isMainFrame: false, type: .other)) == .cancel)
        let (disposition, _) = await delegate.webView(page.webView, respondTo: challenge(host: "example.org"))
        #expect(events.authQuestions.isEmpty)
        #expect(disposition == .rejectProtectionSpace)
        host.close(page.tabID)
    }

    /// A proxy the Mac is set to use may ask for any resource: it is not a site that put a frame on the page.
    @Test func proxyInTheSystemSettingsAsksWhateverTheTopSite() async throws {
        let (host, page, delegate) = try authPage()
        delegate.proxySettings = { ["HTTPProxy": "proxy.example.net", "HTTPEnable": 1] }
        events.authAnswer = AuthAnswer(user: "a", password: "b")
        let (disposition, _) = await delegate.webView(page.webView, respondTo: proxyChallenge(host: "proxy.example.net"))
        let asked = try #require(events.authQuestions.first?.challenge)
        #expect(asked.isProxy)
        #expect(asked.host == "proxy.example.net:8080")
        #expect(disposition == .useCredential)
        host.close(page.tabID)
    }

    /// M3: a "proxy" the system doesn't name (a page's resource claiming to be a proxy) gets the same rule as any other challenge.
    @Test func proxyNotInTheSystemSettingsIsJudgedLikeAnyHost() async throws {
        let (host, page, delegate) = try authPage()
        events.authAnswer = AuthAnswer(user: "a", password: "b")
        for settings: [String: Any]? in [nil, [:], ["HTTPProxy": "proxy.example.net", "HTTPEnable": 0], ["HTTPProxy": "other.example.net", "HTTPEnable": 1]] {
            delegate.proxySettings = { settings }
            let (disposition, credential) = await delegate.webView(page.webView, respondTo: proxyChallenge(host: "proxy.example.net"))
            #expect(disposition == .rejectProtectionSpace)
            #expect(credential == nil)
        }
        #expect(events.authQuestions.isEmpty)
        // The same host as the top site asks, proxy or not.
        let (sameSite, _) = await delegate.webView(page.webView, respondTo: proxyChallenge(host: "example.com"))
        #expect(sameSite == .useCredential)
        host.close(page.tabID)
    }

    /// Review Focus 6: Cancel sends no credential, and the server's own 401 page shows (`.rejectProtectionSpace`, not a cancelled load).
    @Test func cancelSendsNothing() async throws {
        let (host, page, delegate) = try authPage()
        events.authAnswer = nil
        let (disposition, credential) = await delegate.webView(page.webView, respondTo: challenge(host: "example.com"))
        #expect(events.authQuestions.count == 1)
        #expect(disposition == .rejectProtectionSpace)
        #expect(credential == nil)
        host.close(page.tabID)
    }

    @Test func digestNTLMAndDefaultAskThroughTheDelegate() async throws {
        let (host, page, delegate) = try authPage()
        events.authAnswer = AuthAnswer(user: "a", password: "b")
        for method in [NSURLAuthenticationMethodHTTPDigest, NSURLAuthenticationMethodNTLM, NSURLAuthenticationMethodDefault] {
            let (disposition, _) = await delegate.webView(page.webView, respondTo: challenge(host: "example.com", method: method))
            #expect(disposition == .useCredential, "\(method)")
        }
        #expect(events.authQuestions.count == 3)
        host.close(page.tabID)
    }

    /// M1: WebKit continues without a certificate.
    @Test func clientCertificateContinuesWithoutOneThroughTheDelegate() async throws {
        let (host, page, delegate) = try authPage()
        let (disposition, credential) = await delegate.webView(page.webView, respondTo: challenge(host: "example.com", realm: nil, method: NSURLAuthenticationMethodClientCertificate))
        #expect(disposition == .performDefaultHandling)
        #expect(credential == nil)
        #expect(events.authQuestions.isEmpty)
        host.close(page.tabID)
    }

    /// Without this, every HTTPS load would fail: server trust must reach WebKit's own evaluation, whatever host asks.
    @Test func negotiateAndServerTrustUseDefaultHandling() async throws {
        let (host, page, delegate) = try authPage()
        // Not an unknown method name: URLProtectionSpace turns one into the default method, which asks (`AuthChallengeTests` covers the name).
        for method in [NSURLAuthenticationMethodServerTrust, NSURLAuthenticationMethodNegotiate, NSURLAuthenticationMethodHTMLForm] {
            let (disposition, credential) = await delegate.webView(page.webView, respondTo: challenge(host: "example.org", realm: nil, method: method))
            #expect(disposition == .performDefaultHandling, "\(method)")
            #expect(credential == nil)
        }
        #expect(events.authQuestions.isEmpty)
        host.close(page.tabID)
    }

    /// The tab isn't shown: the app holds the question, and the delegate waits for it. Nothing is asked, and nothing is answered, until shown.
    @Test func challengeForHiddenTabWaits() async throws {
        let (host, page, delegate) = try authPage()
        events.authHeld = true
        events.authAnswer = AuthAnswer(user: "ann", password: "secret")
        let webView = page.webView
        let hidden = challenge(host: "example.com")
        let finished = Flag()
        let task = Task { @MainActor in
            let result = await delegate.webView(webView, respondTo: hidden)
            finished.isSet = true
            return result
        }
        #expect(try await waitUntil { events.heldAuthCount == 1 })
        // A few turns of the main actor: it still hasn't answered.
        for _ in 0..<5 { try await Task.sleep(for: .milliseconds(20)) }
        #expect(events.authQuestions.isEmpty)
        #expect(!finished.isSet)
        events.showTab()
        let (disposition, credential) = await task.value
        #expect(events.authQuestions.count == 1)
        #expect(disposition == .useCredential)
        #expect(credential?.user == "ann")
        host.close(page.tabID)
    }

    /// An answer typed for a document the page has since left is not sent to the new page's server.
    @Test func answerForAPageThatNavigatedIsRejected() async throws {
        let (host, page, delegate) = try authPage()
        events.authAnswer = AuthAnswer(user: "ann", password: "secret")
        events.whileAskingAuth = { delegate.webView(page.webView, didCommit: nil) }
        let (disposition, credential) = await delegate.webView(page.webView, respondTo: challenge(host: "example.com"))
        #expect(disposition == .rejectProtectionSpace)
        #expect(credential == nil)
        host.close(page.tabID)
    }
    // MARK: H2, L1, L2, L3

    /// H2 (a), through the delegate: two challenges for one protection space on one tab are one question and get one answer.
    @Test func challengesForOneSpaceShareOneSheet() async throws {
        let (host, page, delegate) = try authPage()
        events.authHeld = true
        events.authAnswer = AuthAnswer(user: "ann", password: "secret")
        let webView = page.webView
        let first = Task { @MainActor in await delegate.webView(webView, respondTo: challenge(host: "example.com")) }
        #expect(try await waitUntil { events.heldAuthCount == 1 })
        let second = Task { @MainActor in await delegate.webView(webView, respondTo: challenge(host: "example.com")) }
        for _ in 0..<50 { await Task.yield() }
        #expect(events.heldAuthCount == 1)
        events.showTab()
        let (firstDisposition, firstCredential) = await first.value
        let (secondDisposition, secondCredential) = await second.value
        #expect(events.authQuestions.count == 1)
        #expect(firstDisposition == .useCredential && secondDisposition == .useCredential)
        #expect(firstCredential?.user == "ann" && secondCredential?.user == "ann")
        host.close(page.tabID)
    }

    /// H2 (b): after three cancels on a document, the fourth challenge gets no sheet; a new main-frame commit asks again.
    @Test func threeCancelsStopTheSheetsUntilANewCommit() async throws {
        let (host, page, delegate) = try authPage()
        events.authAnswer = nil
        for _ in 0..<3 {
            let (disposition, _) = await delegate.webView(page.webView, respondTo: challenge(host: "example.com"))
            #expect(disposition == .rejectProtectionSpace)
        }
        #expect(events.authQuestions.count == 3)
        let (refused, credential) = await delegate.webView(page.webView, respondTo: challenge(host: "example.com"))
        #expect(refused == .rejectProtectionSpace)
        #expect(credential == nil)
        #expect(events.authQuestions.count == 3)
        delegate.webView(page.webView, didCommit: nil)
        events.authAnswer = AuthAnswer(user: "ann", password: "secret")
        let (asked, _) = await delegate.webView(page.webView, respondTo: challenge(host: "example.com"))
        #expect(events.authQuestions.count == 4)
        #expect(asked == .useCredential)
        host.close(page.tabID)
    }

    /// H2 (c): at most five different questions wait on a tab; a sixth is refused unasked.
    @Test func sixthWaitingQuestionOnATabIsRefused() async throws {
        let (host, page, delegate) = try authPage()
        events.authHeld = true
        events.authAnswer = AuthAnswer(user: "ann", password: "secret")
        let webView = page.webView
        var tasks: [Task<(URLSession.AuthChallengeDisposition, URLCredential?), Never>] = []
        for index in 0..<5 {
            let realm = "realm \(index)"
            tasks.append(Task { @MainActor in await delegate.webView(webView, respondTo: challenge(host: "example.com", realm: realm)) })
        }
        #expect(try await waitUntil { events.heldAuthCount == 5 })
        // Start the sixth in a task and release every held question. With the cap removed it would be asked (held, a sixth question) and
        // then answered: the test fails on `authQuestions` below, where awaiting it in line would hang.
        let sixthDone = Flag()
        let sixthTask = Task { @MainActor () -> (URLSession.AuthChallengeDisposition, URLCredential?) in
            let result = await delegate.webView(webView, respondTo: challenge(host: "example.com", realm: "realm 5"))
            sixthDone.isSet = true
            return result
        }
        var turns = 0
        while !sixthDone.isSet, events.heldAuthCount <= 5, turns < 10_000 {
            await Task.yield()
            turns += 1
        }
        events.showTab()
        let (sixth, credential) = await sixthTask.value
        #expect(sixth == .rejectProtectionSpace)
        #expect(credential == nil)
        for task in tasks { #expect(await task.value.0 == .useCredential) }
        #expect(events.authQuestions.count == 5)
        host.close(page.tabID)
    }

    /// L1 and item 4: a main-frame provisional failure of the current navigation cancels the tab's waiting sign-ins about that navigation's
    /// host only, with any error code; a cancel with no navigation to place it, or of a replaced one, doesn't.
    @Test func provisionalFailureCancelsWaitingSignIns() async throws {
        let (host, page, delegate) = try authPage()
        delegate.webView(page.webView, didFailProvisionalNavigation: nil, withError: NSError(domain: NSURLErrorDomain, code: NSURLErrorCancelled))
        #expect(events.cancelledAuthTabs.isEmpty)
        #expect(delegate.decide(NavigationRequest("https://www.example.net:8443/private", type: .linkActivated)) == .allow)
        delegate.webView(page.webView, didFailProvisionalNavigation: nil, withError: NSError(domain: NSURLErrorDomain, code: NSURLErrorCannotFindHost))
        #expect(events.cancelledAuthTabs == [page.tabID])
        // The site key is the pending host's, with no port and no www.
        #expect(events.cancelledAuthSites == ["example.net"])
        #expect(!events.cancelledTabs.contains(page.tabID))
        host.close(page.tabID)
    }

    /// Item 1: a navigation stopped with nothing newer behind it (`window.stop()`, Esc) is current, so its cancel ends the provisional
    /// state: its host may no longer ask, and its waiting sign-ins go.
    @Test func stoppedNavigationWithNothingNewerEndsItsHostsRight() async throws {
        let (host, page, delegate) = try authPage()
        events.authAnswer = AuthAnswer(user: "a", password: "b")
        let started = NSObject()
        #expect(delegate.decide(NavigationRequest("https://example.net/private", type: .linkActivated)) == .allow)
        delegate.navigationStarted(ObjectIdentifier(started))
        let (during, _) = await delegate.webView(page.webView, respondTo: challenge(host: "example.net"))
        #expect(during == .useCredential)
        delegate.provisionalNavigationFailed(ObjectIdentifier(started), error: NSError(domain: NSURLErrorDomain, code: NSURLErrorCancelled))
        #expect(!delegate.mainFrameProvisional)
        #expect(events.cancelledAuthSites == ["example.net"])
        let (after, _) = await delegate.webView(page.webView, respondTo: challenge(host: "example.net"))
        #expect(after == .rejectProtectionSpace)
        host.close(page.tabID)
    }

    /// Item 1: a replaced navigation's late cancel ends nothing, whichever of the successor's start and the cancel arrives first.
    @Test func replacedNavigationsCancelEndsNothing() async throws {
        let (host, page, delegate) = try authPage()
        events.authAnswer = AuthAnswer(user: "a", password: "b")
        let first = NSObject()
        let second = NSObject()
        let cancelled = NSError(domain: NSURLErrorDomain, code: NSURLErrorCancelled)
        // The cancel arrives after the successor started.
        #expect(delegate.decide(NavigationRequest("https://example.net/a", type: .linkActivated)) == .allow)
        delegate.navigationStarted(ObjectIdentifier(first))
        #expect(delegate.decide(NavigationRequest("https://example.org/b", type: .linkActivated)) == .allow)
        delegate.navigationStarted(ObjectIdentifier(second))
        delegate.provisionalNavigationFailed(ObjectIdentifier(first), error: cancelled)
        #expect(delegate.mainFrameProvisional)
        let (late, _) = await delegate.webView(page.webView, respondTo: challenge(host: "example.org"))
        #expect(late == .useCredential)
        // The cancel arrives after the successor was allowed but before it started.
        #expect(delegate.decide(NavigationRequest("https://example.net/c", type: .linkActivated)) == .allow)
        delegate.provisionalNavigationFailed(ObjectIdentifier(second), error: cancelled)
        #expect(delegate.mainFrameProvisional)
        let (early, _) = await delegate.webView(page.webView, respondTo: challenge(host: "example.net"))
        #expect(early == .useCredential)
        #expect(events.cancelledAuthSites.isEmpty)
        host.close(page.tabID)
    }

    /// A server redirect runs the policy check again for the same navigation: a stop after it still ends that navigation's right to ask.
    @Test func redirectedNavigationStoppedEndsItsRightToAsk() async throws {
        let (host, page, delegate) = try authPage()
        events.authAnswer = AuthAnswer(user: "a", password: "b")
        let navigation = NSObject()
        let cancelled = NSError(domain: NSURLErrorDomain, code: NSURLErrorCancelled)
        #expect(delegate.decide(NavigationRequest("https://example.net/r", type: .linkActivated)) == .allow)
        delegate.navigationStarted(ObjectIdentifier(navigation))
        // The 302's policy check, then WebKit's redirect callback for the same navigation.
        #expect(delegate.decide(NavigationRequest("https://example.org/b", type: .other)) == .allow)
        delegate.navigationRedirected(ObjectIdentifier(navigation))
        delegate.provisionalNavigationFailed(ObjectIdentifier(navigation), error: cancelled)
        #expect(!delegate.mainFrameProvisional)
        let (disposition, _) = await delegate.webView(page.webView, respondTo: challenge(host: "example.org"))
        #expect(disposition == .rejectProtectionSpace)
        #expect(events.cancelledAuthSites == ["example.org"])
        host.close(page.tabID)
    }

    /// Item 4: only the user's Cancel counts toward the three-cancel stop; questions the system dropped are not counted.
    @Test func systemDroppedQuestionsDoNotCountAsCancels() async throws {
        let (host, page, delegate) = try authPage()
        events.authDropped = true
        for _ in 0..<5 {
            let (disposition, credential) = await delegate.webView(page.webView, respondTo: challenge(host: "example.com"))
            #expect(disposition == .rejectProtectionSpace)
            #expect(credential == nil)
        }
        #expect(events.authQuestions.count == 5)
        events.authDropped = false
        events.authAnswer = AuthAnswer(user: "ann", password: "secret")
        let (asked, _) = await delegate.webView(page.webView, respondTo: challenge(host: "example.com"))
        #expect(asked == .useCredential)
        host.close(page.tabID)
    }

    /// Item 7: the same host and realm over http and over https are two questions, never one shared answer.
    @Test func httpAndHttpsAreTwoSheets() async throws {
        let (host, page, delegate) = try authPage(top: "http://example.com/")
        events.authHeld = true
        events.authAnswer = AuthAnswer(user: "ann", password: "secret")
        let webView = page.webView
        let plain = Task { @MainActor in await delegate.webView(webView, respondTo: challenge(host: "example.com", port: 80, scheme: "http")) }
        let secure = Task { @MainActor in await delegate.webView(webView, respondTo: challenge(host: "example.com", port: 443, scheme: "https")) }
        var turns = 0
        while events.heldAuthCount < 2, turns < 10_000 {
            await Task.yield()
            turns += 1
        }
        #expect(events.heldAuthCount == 2)
        events.showTab()
        #expect(await plain.value.0 == .useCredential)
        #expect(await secure.value.0 == .useCredential)
        #expect(events.authQuestions.count == 2)
        host.close(page.tabID)
    }

    /// L2: the pending navigation's host asks only while that navigation is provisional; it ends at the commit and at a failure.
    @Test func pendingHostAsksOnlyWhileProvisional() async throws {
        let (host, page, delegate) = try authPage()
        events.authAnswer = AuthAnswer(user: "a", password: "b")
        #expect(delegate.decide(NavigationRequest("https://example.net/private", type: .linkActivated)) == .allow)
        let (during, _) = await delegate.webView(page.webView, respondTo: challenge(host: "example.net"))
        #expect(during == .useCredential)
        // The navigation failed: its host is a stranger again (the top document is still example.com).
        delegate.webView(page.webView, didFailProvisionalNavigation: nil, withError: NSError(domain: NSURLErrorDomain, code: NSURLErrorCannotFindHost))
        let (afterFailure, _) = await delegate.webView(page.webView, respondTo: challenge(host: "example.net"))
        #expect(afterFailure == .rejectProtectionSpace)
        // A new one is allowed and then commits; the top document stays example.com in this test, so its host is a stranger again.
        #expect(delegate.decide(NavigationRequest("https://example.net/next", type: .linkActivated)) == .allow)
        delegate.webView(page.webView, didCommit: nil)
        let (afterCommit, _) = await delegate.webView(page.webView, respondTo: challenge(host: "example.net"))
        #expect(afterCommit == .rejectProtectionSpace)
        host.close(page.tabID)
    }

    /// L2: a subframe allowed on the old document keeps its host until the main frame commits, not until the next navigation is merely allowed.
    @Test func frameHostsLastUntilTheMainFrameCommits() async throws {
        let (host, page, delegate) = try authPage()
        events.authAnswer = AuthAnswer(user: "a", password: "b")
        #expect(delegate.decide(NavigationRequest("https://example.org/frame", isMainFrame: false, type: .other)) == .allow)
        #expect(delegate.decide(NavigationRequest("https://example.com/other", type: .linkActivated)) == .allow)
        let (stillThere, _) = await delegate.webView(page.webView, respondTo: challenge(host: "example.org"))
        #expect(stillThere == .useCredential)
        delegate.webView(page.webView, didCommit: nil)
        let (gone, _) = await delegate.webView(page.webView, respondTo: challenge(host: "example.org"))
        #expect(gone == .rejectProtectionSpace)
        host.close(page.tabID)
    }

    /// L3: an IPv6 host in a protection space has no brackets; the page's address does.
    @Test func ipv6HostMatchesItsBracketedAddress() async throws {
        let (host, page, delegate) = try authPage(top: "http://[::1]:8080/")
        events.authAnswer = AuthAnswer(user: "a", password: "b")
        let (disposition, _) = await delegate.webView(page.webView, respondTo: challenge(host: "::1", port: 8080, scheme: "http"))
        #expect(disposition == .useCredential)
        #expect(events.authQuestions.first?.challenge.host == "[::1]:8080")
        let (other, _) = await delegate.webView(page.webView, respondTo: challenge(host: "::2", port: 8080, scheme: "http"))
        #expect(other == .rejectProtectionSpace)
        host.close(page.tabID)
    }
}

@MainActor
final class Flag {
    var isSet = false
}
