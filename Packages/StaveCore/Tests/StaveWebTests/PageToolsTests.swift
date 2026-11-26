import Foundation
import Testing
import WebKit

@testable import StaveWeb
import StaveCore

/// Answers once the first navigation finishes or fails.
@MainActor
private final class LoadWaiter: NSObject, WKNavigationDelegate {
    private(set) var finished = false

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) { finished = true }
}

extension WebKitTests {
@MainActor
@Suite("Page tools")
struct PageToolsTests {
    /// A web view on a throwaway in-memory store, loaded with a local HTML string; nil when it never finished loading.
    fileprivate func loadedWebView(_ html: String, delegate: LoadWaiter) async throws -> WKWebView? {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        let webView = WKWebView(frame: NSRect(x: 0, y: 0, width: 400, height: 300), configuration: configuration)
        webView.navigationDelegate = delegate
        webView.loadHTMLString(html, baseURL: URL(string: "https://example.com/"))
        // A generous deadline, not a time bound: CI runners load WebKit pages in parallel and slowly.
        let deadline = Date().addingTimeInterval(60)
        while !delegate.finished && Date() < deadline { try await Task.sleep(for: .milliseconds(50)) }
        return delegate.finished ? webView : nil
    }

    @Test func findsInLocalHTML() async throws {
        let delegate = LoadWaiter()
        let loaded = try await loadedWebView("<!doctype html><title>Invented</title><p>alpha beta alpha</p>", delegate: delegate)
        let webView = try #require(loaded)
        #expect(await PageTools.find("alpha", backwards: false, in: webView) == .found)
        #expect(await PageTools.find("alpha", backwards: false, in: webView) == .found) // the second match, then it wraps
        #expect(await PageTools.find("alpha", backwards: true, in: webView) == .found)
        #expect(await PageTools.find("ALPHA", backwards: false, in: webView) == .found) // case doesn't matter, as in Safari
        #expect(await PageTools.find("gamma", backwards: false, in: webView) == .notFound)
        #expect(await PageTools.find("", backwards: false, in: webView) == .notFound)
    }

    /// ⌘E reads the page's selection from Stave's own script world; nil with nothing selected.
    @Test func selectedTextReadsTheSelection() async throws {
        let delegate = LoadWaiter()
        let loaded = try await loadedWebView("<!doctype html><title>Invented</title><p id=p>alpha beta</p>", delegate: delegate)
        let webView = try #require(loaded)
        #expect(await PageTools.selectedText(in: webView) == nil)
        _ = try await webView.evaluateJavaScript("getSelection().selectAllChildren(document.getElementById('p')); 0")
        #expect(await PageTools.selectedText(in: webView) == "alpha beta")
    }

    /// Decision 13: the print job is named after the page and prints what the web view shows. The operation is made, never run: no print job
    /// is ever sent from a test.
    @Test func printOperationNamesThePage() async throws {
        let delegate = LoadWaiter()
        let loaded = try await loadedWebView("<!doctype html><title>Invented</title><p>alpha</p>", delegate: delegate)
        let webView = try #require(loaded)
        let operation = PageTools.print(webView, title: "Invented Title")
        #expect(operation.jobTitle == "Invented Title")
        #expect(operation.showsPrintPanel)
        #expect(operation.view?.frame.isEmpty == false)
    }

    /// Decision 14: the Develop items need WebKit's private inspector and the page's `developerExtrasEnabled`; without the preference they
    /// stay disabled.
    @Test func inspectorNeedsDeveloperExtras() {
        let on = WKWebViewConfiguration()
        PageConfiguration.enableDeveloperExtras(on)
        let inspectable = WKWebView(frame: .zero, configuration: on)
        #expect(PageTools.hasDeveloperExtras(inspectable))
        #expect(PageTools.canShowInspector(inspectable))
        #expect(PageTools.canShowPageSource(inspectable))
        let plain = WKWebView(frame: .zero, configuration: WKWebViewConfiguration())
        #expect(!PageTools.hasDeveloperExtras(plain))
        #expect(!PageTools.canShowInspector(plain))
        #expect(!PageTools.canShowPageSource(plain))
        // `isInspectable` stays off: the in-app inspector doesn't need it (decision 14).
        #expect(!inspectable.isInspectable)
    }
}
}
