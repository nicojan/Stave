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
        guard let page, !page.isClosed, let host, let events else { return nil }
        let url = navigationAction.request.url?.absoluteString ?? ""
        let route = OpenRoute.route(width: windowFeatures.width?.doubleValue, height: windowFeatures.height?.doubleValue, popupRequested: false)
        let child = WKWebView(frame: .zero, configuration: configuration)
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

    public func webViewDidClose(_ webView: WKWebView) {
        events?.closePage(tabID)
    }

    // MARK: JavaScript panels

    public func webView(_ webView: WKWebView, runJavaScriptAlertPanelWithMessage message: String, initiatedByFrame frame: WKFrameInfo) async {
        guard isOpen, let events else { return }
        await events.alert(tabID: tabID, message: message)
    }

    public func webView(_ webView: WKWebView, runJavaScriptConfirmPanelWithMessage message: String, initiatedByFrame frame: WKFrameInfo) async -> Bool {
        guard isOpen, let events else { return false }
        return await events.confirm(tabID: tabID, message: message)
    }

    public func webView(_ webView: WKWebView, runJavaScriptTextInputPanelWithPrompt prompt: String, defaultText: String?, initiatedByFrame frame: WKFrameInfo) async -> String? {
        guard isOpen, let events else { return nil }
        return await events.prompt(tabID: tabID, message: prompt, defaultText: defaultText)
    }

    public func webView(_ webView: WKWebView, runOpenPanelWith parameters: WKOpenPanelParameters, initiatedByFrame frame: WKFrameInfo) async -> [URL]? {
        guard isOpen, let events else { return nil }
        return await events.chooseFiles(tabID: tabID, allowsMultiple: parameters.allowsMultipleSelection, allowsDirectories: parameters.allowsDirectories)
    }

    private var isOpen: Bool {
        guard let page else { return false }
        return !page.isClosed
    }

    // MARK: Camera and microphone

    public func webView(_ webView: WKWebView, requestMediaCapturePermissionFor origin: WKSecurityOrigin, initiatedByFrame frame: WKFrameInfo, type: WKMediaCaptureType) async -> WKPermissionDecision {
        let (camera, microphone) = switch type {
        case .camera: (true, false)
        case .microphone: (false, true)
        default: (true, true)
        }
        return await mediaDecision(originHost: origin.host, camera: camera, microphone: microphone)
    }

    /// A remembered answer for every key asked grants; any remembered deny denies; otherwise the app asks,
    /// and the answer is remembered per key when the user says so (plan 3, decision 11).
    func mediaDecision(originHost: String, camera: Bool, microphone: Bool) async -> WKPermissionDecision {
        guard let page, !page.isClosed, let host, let events, let site = SiteHost.normalized(originHost) else { return .deny }
        let keys: [SiteSettingKey] = (camera ? [.camera] : []) + (microphone ? [.microphone] : [])
        guard !keys.isEmpty else { return .deny }
        let remembered = keys.map { host.rememberedMedia(for: page, host: site, key: $0) }
        if remembered.contains(.deny) { return .deny }
        if remembered.allSatisfy({ $0 == .allow }) { return .grant }
        let answer = await events.askMedia(tabID: tabID, host: site, camera: camera, microphone: microphone)
        if answer.remember {
            for key in keys { host.rememberMedia(answer.allow ? .allow : .deny, for: page, host: site, key: key) }
        }
        return answer.allow && !page.isClosed ? .grant : .deny
    }
}
