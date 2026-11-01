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

    public static func make(
        store: WKWebsiteDataStore,
        ruleLists: [WKContentRuleList],
        applicationName: String,
        messageHandler: WKScriptMessageHandler
    ) -> WKWebViewConfiguration {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = store
        configuration.applicationNameForUserAgent = applicationName
        configuration.preferences.isElementFullscreenEnabled = true
        configuration.preferences.javaScriptCanOpenWindowsAutomatically = false
        let content = WKUserContentController()
        content.addUserScript(WKUserScript(source: faviconScript, injectionTime: .atDocumentEnd, forMainFrameOnly: true, in: faviconWorld))
        content.add(messageHandler, contentWorld: faviconWorld, name: faviconHandlerName)
        for list in ruleLists { content.add(list) }
        configuration.userContentController = content
        return configuration
    }
}
