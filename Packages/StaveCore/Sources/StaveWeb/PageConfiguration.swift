import Foundation
import WebKit

/// Builds the configuration every Stave page starts from.
@MainActor
public enum PageConfiguration {
    public static let faviconWorld = WKContentWorld.world(name: "StaveFavicon")
    public static let faviconHandlerName = "staveFavicon"
    static let faviconScript = """
    (() => { const l = document.querySelector('link[rel~="icon"]'); window.webkit.messageHandlers.staveFavicon.postMessage(l ? l.href : new URL('/favicon.ico', location.href).href); })();
    """
    /// WebKit drops a main-frame navigation to a `file:` URL outside the web process's read access before it asks the navigation delegate,
    /// so the policy never sees a click on such a link (decision 6, by-hand gap in Task 5). This isolated-world script reports the user's own
    /// plain click on a `file:` link in an opened file's page: trusted, left button, no ⌘/⌃/⌥, not cancelled by the page, opening in place.
    /// A script's navigation, a ⌘-click and a `target=_blank` link are never reported, so they stay silent.
    public static let fileLinkWorld = WKContentWorld.world(name: "StaveFileLink")
    public static let fileLinkHandlerName = "staveFileLink"
    static let fileLinkScript = """
    (() => { if (location.protocol !== 'file:') return; window.addEventListener('click', (e) => {
      if (!e.isTrusted || e.defaultPrevented || e.button !== 0 || e.metaKey || e.ctrlKey || e.altKey) return;
      const a = e.target instanceof Element ? e.target.closest('a[href]') : null;
      if (!a || a.hasAttribute('download') || a.protocol !== 'file:') return;
      const t = (a.getAttribute('target') || '').toLowerCase();
      if (t && t !== '_self' && t !== '_top' && t !== '_parent') return;
      window.webkit.messageHandlers.staveFileLink.postMessage(a.href);
    }); })();
    """

    public static func make(
        store: WKWebsiteDataStore,
        ruleLists: [WKContentRuleList],
        applicationName: String,
        messageHandler: WKScriptMessageHandler,
        fileLinkHandler: WKScriptMessageHandler
    ) -> WKWebViewConfiguration {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = store
        configuration.applicationNameForUserAgent = applicationName
        configuration.preferences.isElementFullscreenEnabled = true
        configuration.preferences.javaScriptCanOpenWindowsAutomatically = false
        let content = WKUserContentController()
        content.addUserScript(WKUserScript(source: faviconScript, injectionTime: .atDocumentEnd, forMainFrameOnly: true, in: faviconWorld))
        content.add(messageHandler, contentWorld: faviconWorld, name: faviconHandlerName)
        content.addUserScript(WKUserScript(source: fileLinkScript, injectionTime: .atDocumentStart, forMainFrameOnly: true, in: fileLinkWorld))
        content.add(fileLinkHandler, contentWorld: fileLinkWorld, name: fileLinkHandlerName)
        for list in ruleLists { content.add(list) }
        configuration.userContentController = content
        return configuration
    }
}
