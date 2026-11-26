import Foundation
import CFNetwork
import StaveCore
import WebKit

/// HTTP authentication (plan 5, decision 15). WebKit hands every challenge to one method, so this decides which ones are Stave's to ask.
extension PageDelegate {
    /// At most this many allowed subframe hosts are remembered for one document.
    static let allowedFrameHostLimit = 64

    /// WebKit's authentication challenge. The async Swift name must be this one (`WK_SWIFT_ASYNC_NAME` in `WKNavigationDelegate.h`);
    /// `DelegateSelectorTests` checks that WebKit finds it.
    ///
    /// Basic, Digest, NTLM and the default method ask the user, with the sheet naming the server that asks (the protection space's host,
    /// never the top page's). Server trust, client certificates, Negotiate and anything else get WebKit's default handling, so its
    /// certificate evaluation is unchanged and a client-certificate request continues without one. Cancel sends no credential and rejects
    /// the protection space, so the server's own 401 page shows (a cancelled challenge fails the load with `NSURLErrorCancelled`, which
    /// Stave shows as nothing). An answer is kept for the session (`.forSession`, in memory; a private window's store keeps it in memory
    /// only), as Safari does without "remember", so the sheet doesn't come back for every subresource of the site.
    ///
    /// Challenges of one protection space on this page share one sheet, at most five different ones wait, and after three cancels in a
    /// document none is asked until the next one (`AuthQuestionGate`): a page can't lock the window with an endless loop of sheets.
    public func webView(_ webView: WKWebView, respondTo challenge: URLAuthenticationChallenge) async -> (URLSession.AuthChallengeDisposition, URLCredential?) {
        let space = challenge.protectionSpace
        guard AuthChallenge.handling(method: space.authenticationMethod) == .ask else { return (.performDefaultHandling, nil) }
        guard let page, !page.isClosed, let events, mayAsk(space) else { return (.rejectProtectionSpace, nil) }
        let asking = AuthChallenge(
            host: AuthChallenge.hostLabel(host: space.host, port: space.port, scheme: space.protocol),
            realm: space.realm,
            isProxy: space.isProxy(),
            previousFailureCount: challenge.previousFailureCount
        )
        let key = AuthSpace(host: asking.host, scheme: space.protocol, realm: space.realm, method: space.authenticationMethod, isProxy: asking.isProxy)
        let commits = page.commitCount
        let tabID = tabID
        let answer = await authGate.ask(key, document: commits) { await events.askAuth(tabID: tabID, challenge: asking) }
        // The question may have waited for its tab: an answer for a page that was since closed, remade or navigated is not sent on.
        guard let answer, !page.isClosed, host?.existingPage(self.tabID) === page, page.commitCount == commits else { return (.rejectProtectionSpace, nil) }
        return (.useCredential, URLCredential(user: answer.user, password: answer.password, persistence: .forSession))
    }

    /// The system's proxy settings (`CFNetworkCopySystemProxySettings`); a seam for tests.
    static var systemProxySettings: [String: Any]? {
        CFNetworkCopySystemProxySettings()?.takeRetainedValue() as? [String: Any]
    }

    /// WebKit doesn't say which resource asked. A proxy the Mac is set to use may ask. Anything else: Stave asks only for the top page's
    /// site, a main-frame navigation it allowed that is still provisional, or a subframe navigation it allowed since the last commit; any
    /// other challenge (an image or script from another site, or a "proxy" the system doesn't name) gets no sheet, as in mainstream
    /// browsers, so a page can't put a sign-in prompt for a site over a page that is not that site's.
    private func mayAsk(_ space: URLProtectionSpace) -> Bool {
        if space.isProxy(), SystemProxy.isProxyHost(space.host, in: proxySettings()) { return true }
        let key = Self.hostKey(space.host)
        if let top = topURL?.absoluteString, Self.siteKey(top) == key { return true }
        if mainFrameProvisional, let pending = pendingURL?.absoluteString, Self.siteKey(pending) == key { return true }
        return allowedFrameHosts.contains(key)
    }

    /// The site key for a host name (a protection space's host, with no brackets around an IPv6 address), matching `siteKey` of an address.
    static func hostKey(_ host: String) -> String {
        siteKey(SystemProxy.hostKey(host))
    }

    /// The same site key for a host and for an address: `HostText`'s, else the lowercased text.
    static func siteKey(_ hostOrURL: String) -> String {
        SiteHost.normalized(hostOrURL) ?? hostOrURL.lowercased()
    }

    /// A subframe navigation the policy allowed: its host may ask for credentials until the next main-frame commit.
    func noteAllowedFrame(_ url: String) {
        guard let key = SiteHost.normalized(url), !allowedFrameHosts.contains(key) else { return }
        allowedFrameHosts = Array((allowedFrameHosts + [key]).suffix(Self.allowedFrameHostLimit))
    }
}
