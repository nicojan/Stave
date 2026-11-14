import Testing
@testable import StaveCore

struct NavigationPolicyTests {
    static let hostile = ["javascript:alert(1)", "JavaScript:void(0)", "file:///etc/hosts", "data:text/html,x", "arc://x", "chrome://settings", "mailto:a@example.com"]

    @Test func storedHostileSchemesRefused() {
        for source in [NavigationSource.stored, .restored] {
            for url in Self.hostile where URLScheme.scheme(of: url) != "file" {
                #expect(NavigationPolicy.decide(url, isMainFrame: true, source: source) == .refuse(.refused(url: url)))
            }
        }
    }

    /// A stored or restored `file:` tab doesn't load by itself; its panel offers "Open Again" (decision 6, question 13).
    @Test func restoredFileTabIsRefused() {
        for source in [NavigationSource.stored, .restored] {
            let decision = NavigationPolicy.decide("file:///etc/hosts", isMainFrame: true, source: source)
            #expect(decision == .refuse(.fileNotReopened(url: "file:///etc/hosts")))
        }
        let failure = PageFailure.fileNotReopened(url: "file:///Users/test/a.html")
        #expect(PageText.title(failure) == PageText.title(.refused(url: "file:///Users/test/a.html")))
        #expect(PageText.detail(failure).contains("file:///Users/test/a.html"))
        #expect(PageText.offersOpenAgain(failure))
        #expect(!PageText.offersOpenAgain(.refused(url: "file:///Users/test/a.html")))
        #expect(!PageText.offersOpenAgain(.crashed))
        #expect(PageText.openAgainButton == "Open Again")
    }

    /// A refused address in a tab with nothing loaded (a refused link from another app, a refused typed address in a blank tab) offers no
    /// Reload, which could only refuse it again; over a loaded page Reload stays, and every other failure keeps it (fix round 2).
    @Test func refusedBlankTabOffersNoReload() {
        for url in ["javascript:alert(1)", "file:///etc/hosts", "data:text/html,x"] {
            #expect(!PageText.offersReload(.refused(url: url), hasDocument: false))
            #expect(PageText.offersReload(.refused(url: url), hasDocument: true))
        }
        // Open Again stands in for Reload on a stored file tab.
        #expect(!PageText.offersReload(.fileNotReopened(url: "file:///Users/test/a.html"), hasDocument: false))
        #expect(!PageText.offersReload(.fileNotReopened(url: "file:///Users/test/a.html"), hasDocument: true))
        for failure in [PageFailure.loadFailed(host: "example.com", message: "x"), .insecure(host: "example.com"), .crashed, .noAppForLink(url: "x-invented:a")] {
            #expect(PageText.offersReload(failure, hasDocument: false))
            #expect(PageText.offersReload(failure, hasDocument: true))
        }
    }

    /// The opened file loads through `.openedFile`; nothing outside its grant does.
    @Test func openedFileLoadsOnlyItsGrant() {
        let folder = "/Users/test/site"
        #expect(NavigationPolicy.decide("file:///Users/test/site/a.html", isMainFrame: true, source: .openedFile(grantedFolder: folder)) == .allow)
        #expect(NavigationPolicy.decide("file:///etc/hosts", isMainFrame: true, source: .openedFile(grantedFolder: folder)) == .refuse(.refused(url: "file:///etc/hosts")))
        #expect(NavigationPolicy.decide("javascript:alert(1)", isMainFrame: true, source: .openedFile(grantedFolder: folder)) == .refuse(.refused(url: "javascript:alert(1)")))
        #expect(NavigationPolicy.decide("file:///Users/test/site/b.html", isMainFrame: false, source: .openedFile(grantedFolder: folder)) == .refuse(nil))
    }

    /// A user-clicked main-frame link to a file inside the tab's granted folder opens; outside it shows the refused panel.
    @Test func linkInsideFolderOpens() {
        let source = NavigationSource.page(userGesture: true, grantedFolder: "/Users/test/site")
        #expect(NavigationPolicy.decide("file:///Users/test/site/b.html", isMainFrame: true, source: source) == .allow)
        #expect(NavigationPolicy.decide("file:///Users/test/site/sub/c.html", isMainFrame: true, source: source) == .allow)
        #expect(NavigationPolicy.decide("file:///etc/hosts", isMainFrame: true, source: source) == .refuse(.refused(url: "file:///etc/hosts")))
        #expect(NavigationPolicy.decide("file:///Users/test/site/../secret.html", isMainFrame: true, source: source) == .refuse(.refused(url: "file:///Users/test/site/../secret.html")))
        // A subframe never loads a file, even inside the folder.
        #expect(NavigationPolicy.decide("file:///Users/test/site/b.html", isMainFrame: false, source: source) == .refuse(nil))
        // Web links from the file still open.
        #expect(NavigationPolicy.decide("https://example.com", isMainFrame: true, source: source) == .allow)
    }

    /// A script-started `file:` navigation is refused with no panel, inside the folder or not.
    @Test func scriptFileNavigationRefused() {
        let source = NavigationSource.page(userGesture: false, grantedFolder: "/Users/test/site")
        #expect(NavigationPolicy.decide("file:///Users/test/site/b.html", isMainFrame: true, source: source) == .refuse(nil))
        #expect(NavigationPolicy.decide("file:///etc/hosts", isMainFrame: true, source: source) == .refuse(nil))
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
