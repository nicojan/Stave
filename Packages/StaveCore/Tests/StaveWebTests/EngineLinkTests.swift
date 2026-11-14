import ChorusEngine
import Testing
import WebKit

@testable import StaveWeb

@MainActor
@Suite("Engine link")
struct EngineLinkTests {
    @Test func contentBlockerBuilds() {
        let manager = ContentBlockerManager()
        #expect(manager.isEnabled)
        #expect(!manager.annoyanceEnabled)
        #expect(manager.enabledLists().isEmpty)
    }

    @Test func contentBlockerCompiles() async throws {
        let manager = ContentBlockerManager()
        var timeout: Task<Void, Never>?
        let ready: Bool = await withCheckedContinuation { continuation in
            var resumed = false
            let finish: (Bool) -> Void = { value in
                guard !resumed else { return }
                resumed = true
                continuation.resume(returning: value)
            }
            manager.onReady = { finish(true) }
            manager.start()
            timeout = Task { @MainActor in
                // A cancelled sleep throws: return without answering, since the compile already did.
                guard (try? await Task.sleep(for: .seconds(60))) != nil else { return }
                finish(false)
            }
        }
        // The compile answered first: the 60 s timer has nothing left to do, so it doesn't outlive the test.
        timeout?.cancel()
        #expect(ready, "the content blocker didn't report ready within 60 seconds")
        #expect(!manager.enabledLists().isEmpty)
    }

    @Test func webViewLoadsLocalHTML() async throws {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = WKWebsiteDataStore.nonPersistent()
        let webView = WKWebView(frame: .init(x: 0, y: 0, width: 200, height: 200), configuration: configuration)
        webView.loadHTMLString("<title>t</title>", baseURL: nil)
        var title: String?
        for _ in 0..<100 {
            title = webView.title
            if title == "t" { break }
            try await Task.sleep(for: .milliseconds(100))
        }
        #expect(title == "t")
    }
}
