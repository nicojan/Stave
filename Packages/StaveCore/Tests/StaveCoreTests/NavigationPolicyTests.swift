import Testing
@testable import StaveCore

struct NavigationPolicyTests {
    static let hostile = ["javascript:alert(1)", "JavaScript:void(0)", "file:///etc/hosts", "data:text/html,x", "arc://x", "chrome://settings", "mailto:a@example.com"]

    @Test func storedHostileSchemesRefused() {
        for source in [NavigationSource.stored, .restored] {
            for url in Self.hostile {
                #expect(NavigationPolicy.decide(url, isMainFrame: true, source: source) == .refuse(.refused(url: url)))
            }
        }
    }

    @Test func webSchemesAllowed() {
        for source in [NavigationSource.stored, .restored, .typed, .page(userGesture: true), .page(userGesture: false)] {
            for url in ["https://example.com", "HTTP://example.com/x", "about:blank"] {
                #expect(NavigationPolicy.decide(url, isMainFrame: true, source: source) == .allow)
            }
        }
        #expect(NavigationPolicy.decide("https://", isMainFrame: true, source: .stored) == .refuse(.refused(url: "https://")))
        #expect(NavigationPolicy.decide("http:example.com", isMainFrame: true, source: .stored) == .refuse(.refused(url: "http:example.com")))
    }

    @Test func blobMainFrameOnlyFromAPage() {
        #expect(NavigationPolicy.decide("blob:https://example.com/u", isMainFrame: true, source: .page(userGesture: false)) == .allow)
        #expect(NavigationPolicy.decide("blob:https://example.com/u", isMainFrame: true, source: .stored) == .refuse(.refused(url: "blob:https://example.com/u")))
        #expect(NavigationPolicy.decide("blob:https://example.com/u", isMainFrame: true, source: .typed) == .refuse(.refused(url: "blob:https://example.com/u")))
    }

    @Test func pageDataMainFrameRefused() {
        #expect(NavigationPolicy.decide("data:text/html,x", isMainFrame: true, source: .page(userGesture: true)) == .refuse(nil))
        #expect(NavigationPolicy.decide("data:text/html,x", isMainFrame: false, source: .page(userGesture: true)) == .allow)
        #expect(NavigationPolicy.decide("about:srcdoc", isMainFrame: true, source: .page(userGesture: false)) == .refuse(nil))
        #expect(NavigationPolicy.decide("about:srcdoc", isMainFrame: false, source: .page(userGesture: false)) == .allow)
    }

    @Test func externalSchemesNeedAGesture() {
        let url = "mailto:a@example.com"
        #expect(NavigationPolicy.decide(url, isMainFrame: true, source: .page(userGesture: true)) == .askToOpenExternally(url))
        #expect(NavigationPolicy.decide(url, isMainFrame: true, source: .page(userGesture: false)) == .refuse(nil))
        #expect(NavigationPolicy.decide(url, isMainFrame: true, source: .typed) == .askToOpenExternally(url))
        for source in [NavigationSource.stored, .restored, .typed, .page(userGesture: true), .page(userGesture: false)] {
            #expect(NavigationPolicy.decide(url, isMainFrame: false, source: source) == .refuse(nil))
        }
    }

    @Test func fileNeverOpens() {
        for source in [NavigationSource.stored, .restored, .typed, .page(userGesture: true), .page(userGesture: false)] {
            for frame in [true, false] {
                let decision = NavigationPolicy.decide("file:///x", isMainFrame: frame, source: source)
                guard case .refuse = decision else {
                    Issue.record("file: was not refused")
                    continue
                }
            }
        }
    }

    @Test func subframesAllowTheirSchemes() {
        for url in ["https://example.com", "about:blank", "data:text/html,x", "blob:https://example.com/u"] {
            #expect(NavigationPolicy.decide(url, isMainFrame: false, source: .page(userGesture: false)) == .allow)
        }
        #expect(NavigationPolicy.decide("https://", isMainFrame: false, source: .page(userGesture: false)) == .refuse(nil))
        #expect(NavigationPolicy.decide("javascript:1", isMainFrame: false, source: .page(userGesture: true)) == .refuse(nil))
    }

    @Test func pageHostileMainFrameIsSilent() {
        #expect(NavigationPolicy.decide("javascript:alert(1)", isMainFrame: true, source: .page(userGesture: true)) == .refuse(nil))
        #expect(NavigationPolicy.decide("file:///x", isMainFrame: true, source: .page(userGesture: true)) == .refuse(nil))
    }

    @Test func linkDispositions() {
        #expect(LinkDisposition.decide(command: false, shift: false, targetsNewWindow: false) == .current)
        #expect(LinkDisposition.decide(command: true, shift: false, targetsNewWindow: false) == .newTab(select: false))
        #expect(LinkDisposition.decide(command: true, shift: true, targetsNewWindow: false) == .newTab(select: true))
        #expect(LinkDisposition.decide(command: false, shift: false, targetsNewWindow: true) == .newTab(select: true))
    }

    @Test func openRoutes() {
        #expect(OpenRoute.route(width: nil, height: nil, popupRequested: false) == .sidebarTab)
        #expect(OpenRoute.route(width: 500, height: nil, popupRequested: false) == .popupWindow)
        #expect(OpenRoute.route(width: nil, height: nil, popupRequested: true) == .popupWindow)
    }

    @Test func userAgentNamesSystemSafari() {
        #expect(UserAgent.applicationName(safariVersion: "18.3") == "Version/18.3 Safari/605.1.15")
        #expect(UserAgent.applicationName(safariVersion: nil) == "Version/17.0 Safari/605.1.15")
        #expect(UserAgent.applicationName(safariVersion: "") == "Version/17.0 Safari/605.1.15")
        #expect(UserAgent.applicationName(safariVersion: "18.3 beta<script>") == "Version/18.3 Safari/605.1.15")
        #expect(UserAgent.applicationName(safariVersion: "<b>") == "Version/17.0 Safari/605.1.15")
    }

    @Test func userInfoShowsRealHost() {
        #expect(DisplayText.address(for: "https://example.com@example.net/x") == "example.net")
    }

    @Test func schemeReading() {
        #expect(URLScheme.scheme(of: "HTTPS://x") == "https")
        #expect(URLScheme.scheme(of: "example.com") == nil)
        #expect(URLScheme.scheme(of: "1a:x") == nil)
        #expect(URLScheme.hasWebAuthority("https://a") == true)
        #expect(URLScheme.hasWebAuthority("https:///a") == false)
        #expect(URLScheme.hasWebAuthority("ftp://a") == false)
    }

    @Test func pageTextIsPlain() {
        #expect(PageText.title(.crashed) == "This page stopped working")
        #expect(PageText.title(.refused(url: "file:///x")) == "Stave won't open this address")
        #expect(PageText.detail(.refused(url: "file:///x")).contains("file:///x"))
        #expect(PageText.title(.insecure(host: "example.com")) == "This connection isn't private")
        #expect(PageText.title(.noAppForLink(url: "zoommtg://x")) == "No app can open this link")
        #expect(PageText.title(.loadFailed(host: "example.com", message: "Timed out")) == "Stave couldn't open this page")
        #expect(PageText.detail(.loadFailed(host: "example.com", message: "Timed out")).contains("Timed out"))
        #expect(PageText.detail(.insecure(host: "example.com")).contains("example.com"))
        #expect(PageText.newTabHint == "Press ⌘L to enter an address or search.")
        #expect(PageText.externalAppQuestion(appName: "Zoom") == "Open this link in Zoom?")
        #expect(PageText.mediaQuestion(host: "example.com", camera: true, microphone: false) == "Allow example.com to use your camera?")
        #expect(PageText.mediaQuestion(host: "example.com", camera: false, microphone: true) == "Allow example.com to use your microphone?")
        #expect(PageText.mediaQuestion(host: "example.com", camera: true, microphone: true) == "Allow example.com to use your camera and microphone?")
        #expect(PageText.elsewhereTitle == "This tab is open in another window")
    }

    /// Scheme matching ignores case, and a typed `data:` address is refused with the panel rather than loaded.
    @Test func upperCaseSchemesAndTypedData() {
        #expect(NavigationPolicy.decide("MAILTO:a@example.com", isMainFrame: true, source: .typed) == .askToOpenExternally("MAILTO:a@example.com"))
        #expect(NavigationPolicy.decide("MAILTO:a@example.com", isMainFrame: true, source: .page(userGesture: false)) == .refuse(nil))
        #expect(NavigationPolicy.decide("MAILTO:a@example.com", isMainFrame: true, source: .stored) == .refuse(.refused(url: "MAILTO:a@example.com")))
        for source in [NavigationSource.stored, .restored, .typed, .page(userGesture: false)] {
            #expect(NavigationPolicy.decide("ABOUT:BLANK", isMainFrame: true, source: source) == .allow)
        }
        #expect(NavigationPolicy.decide("data:text/html,x", isMainFrame: true, source: .typed) == .refuse(.refused(url: "data:text/html,x")))
        #expect(NavigationPolicy.decide("DATA:text/html,x", isMainFrame: true, source: .typed) == .refuse(.refused(url: "DATA:text/html,x")))
    }
}
