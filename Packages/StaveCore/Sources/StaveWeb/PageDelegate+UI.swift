import AppKit
import Foundation
import StaveCore
import WebKit

/// Pop-ups, linked tabs, `window.close()`, JavaScript panels, file upload and camera/microphone.
extension PageDelegate {
    // MARK: New windows

    /// Follows `OpenRoute`. The new view is built from the configuration WebKit passes (required by WebKit;
    /// it carries `window.opener` and the opener's store). The app adopts it while `events` runs, which
    /// gives it its own delegate; a view left unadopted would load ungated, so it is refused instead.
    public func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration, for navigationAction: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
        // Taken first, so a choice is used by the request it was made for whatever happens below. The menu's request is `.other`;
        // a clicked `target=_blank` link neither takes nor discards it.
        let fromLinkMenu = navigationAction.navigationType == .other ? (webView as? PageWebView)?.takeLinkMenuChoice() : nil
        guard let page, !page.isClosed, let host, let events else { return nil }
        let url = navigationAction.request.url?.absoluteString ?? ""
        switch fromLinkMenu {
        case .newTab: return openLinkInNewTab(url, events: events)
        case .newWindow: return openLinkInNewWindow(url, events: events)
        case nil: break
        }
        let route = OpenRoute.route(width: windowFeatures.width?.doubleValue, height: windowFeatures.height?.doubleValue, popupRequested: false)
        let child = PageWebView(frame: .zero, configuration: configuration)
        if let pageView = webView as? PageWebView { child.now = pageView.now }
        switch route {
        case .sidebarTab:
            let modifiers = navigationAction.navigationType == .linkActivated ? navigationAction.modifierFlags : []
            let disposition = LinkDisposition.decide(command: modifiers.contains(.command), shift: modifiers.contains(.shift), targetsNewWindow: true)
            let select = if case .newTab(let select) = disposition { select } else { true }
            guard events.openLinkedTab(opener: tabID, url: url, select: select, webView: child) != nil else { return nil }
        case .popupWindow:
            events.openPopup(opener: tabID, webView: child, features: windowFeatures)
        }
        guard host.isAdopted(child) else { return nil }
        return child
    }

    /// "Open Link in New Tab" from the link menu opens a background tab the way ⌘-click does: the app makes a fresh page (its own
    /// content blocking for its site, no `window.opener`), and WebKit gets no view.
    private func openLinkInNewTab(_ url: String, events: PageEvents) -> WKWebView? {
        if NavigationPolicy.decide(url, isMainFrame: true, source: .page(userGesture: true)) == .allow {
            _ = events.openLinkedTab(opener: tabID, url: url, select: false, webView: nil)
        }
        return nil
    }

    /// "Open Link in New Window" from the link menu opens a real window, as in every browser: the app makes it and a fresh page for the link,
    /// and WebKit gets no view. A `target=_blank` click and `window.open` don't come here.
    private func openLinkInNewWindow(_ url: String, events: PageEvents) -> WKWebView? {
        if NavigationPolicy.decide(url, isMainFrame: true, source: .page(userGesture: true)) == .allow {
            events.openLinkInNewWindow(opener: tabID, url: url)
        }
        return nil
    }

    public func webViewDidClose(_ webView: WKWebView) {
        events?.closePage(tabID)
    }

    // MARK: JavaScript panels

    public func webView(_ webView: WKWebView, runJavaScriptAlertPanelWithMessage message: String, initiatedByFrame frame: WKFrameInfo) async {
        guard isOpen, let events else { return }
        await events.alert(tabID: tabID, origin: Self.dialogOrigin(of: frame), message: message)
    }

    public func webView(_ webView: WKWebView, runJavaScriptConfirmPanelWithMessage message: String, initiatedByFrame frame: WKFrameInfo) async -> Bool {
        guard isOpen, let events else { return false }
        return await events.confirm(tabID: tabID, origin: Self.dialogOrigin(of: frame), message: message)
    }

    public func webView(_ webView: WKWebView, runJavaScriptTextInputPanelWithPrompt prompt: String, defaultText: String?, initiatedByFrame frame: WKFrameInfo) async -> String? {
        guard isOpen, let events else { return nil }
        return await events.prompt(tabID: tabID, origin: Self.dialogOrigin(of: frame), message: prompt, defaultText: defaultText)
    }

    public func webView(_ webView: WKWebView, runOpenPanelWith parameters: WKOpenPanelParameters, initiatedByFrame frame: WKFrameInfo) async -> [URL]? {
        guard isOpen, let events else { return nil }
        return await events.chooseFiles(tabID: tabID, allowsMultiple: parameters.allowsMultipleSelection, allowsDirectories: parameters.allowsDirectories)
    }

    /// The asking frame's host: its security origin's, else its request's; nil when it has none (an opaque origin such as a sandboxed srcdoc).
    static func dialogOrigin(of frame: WKFrameInfo) -> String? {
        dialogOrigin(securityHost: frame.securityOrigin.host, requestURL: frame.request.url)
    }

    static func dialogOrigin(securityHost: String, requestURL: URL?) -> String? {
        if !securityHost.isEmpty { return securityHost }
        guard let host = requestURL?.host, !host.isEmpty else { return nil }
        return host
    }

    private var isOpen: Bool {
        guard let page else { return false }
        return !page.isClosed
    }

    // MARK: Camera and microphone

    /// WebKit's camera and microphone question, asked after macOS's own permission check. The async Swift name must be this one
    /// (`WK_SWIFT_ASYNC_NAME` in `WKUIDelegate.h`): an async method using the selector's labels matches nothing, and WebKit then shows its
    /// own prompt, which remembers nothing. `origin` is the top page's, so an embedded frame is asked about, and remembered under, the top
    /// site (as Chrome does for permissions a page delegates); JavaScript dialogs name the frame instead, on purpose.
    public func webView(_ webView: WKWebView, decideMediaCapturePermissionsFor origin: WKSecurityOrigin, initiatedBy frame: WKFrameInfo, type: WKMediaCaptureType) async -> WKPermissionDecision {
        let (camera, microphone) = switch type {
        case .camera: (true, false)
        case .microphone: (false, true)
        default: (true, true)
        }
        return await mediaDecision(originHost: origin.host, camera: camera, microphone: microphone)
    }

    /// Whether the page's current top document is on `site`. The origin WebKit passes is the top page's, so it must match: a commit can
    /// slip in between WebKit's call and this task, and the question would then name one site over another's page.
    private func isTopSite(_ site: String) -> Bool {
        topURL.flatMap { SiteHost.normalized($0.absoluteString) } == site
    }

    /// A remembered answer for every key asked grants; any remembered deny denies (rows stored earlier still count); otherwise the app asks.
    /// Only an Allow is remembered, per key, when the user ticks "Remember for this site" (plan 3, decision 11). A Don't Allow denies this
    /// time and stores nothing, so the next load asks again: a stopgap until a per-site settings panel lets the user undo a stored deny.
    func mediaDecision(originHost: String, camera: Bool, microphone: Bool) async -> WKPermissionDecision {
        guard let page, !page.isClosed, let host, let events, let site = SiteHost.normalized(originHost), isTopSite(site) else { return .deny }
        let keys: [SiteSettingKey] = (camera ? [.camera] : []) + (microphone ? [.microphone] : [])
        guard !keys.isEmpty else { return .deny }
        let remembered = keys.map { host.rememberedMedia(for: page, host: site, key: $0) }
        if remembered.contains(.deny) { return .deny }
        if remembered.allSatisfy({ $0 == .allow }) { return .grant }
        let commits = page.commitCount
        let answer = await events.askMedia(tabID: tabID, host: site, camera: camera, microphone: microphone)
        // The question may have waited, or been up, while the page navigated, was unloaded or remade: the answer is then for a page that
        // is gone, so nothing is remembered or granted (an allow must not be stored for the old host).
        guard !page.isClosed, host.existingPage(tabID) === page, page.commitCount == commits, isTopSite(site) else { return .deny }
        if answer.remember, answer.allow {
            for key in keys { host.rememberMedia(.allow, for: page, host: site, key: key) }
        }
        return answer.allow ? .grant : .deny
    }
}
