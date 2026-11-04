import AppKit
import Foundation
import StaveCore
import Testing
import WebKit

@testable import StaveWeb

/// A page Stave reopens by itself (a tab restored at launch, or any stored tab shown again) downloads nothing until the user acts on it:
/// the restored `double.html` saved a file at relaunch with no click (walkthrough fix 2).
extension PageDelegateTests {
    /// A page for a stored tab, kept off the network.
    func storedPage(_ host: PageHost, url: String = "https://example.com/files", openedByUser: Bool = false) async throws -> LivePage {
        host.testRuleLists = [try await blockAllRuleList()]
        var stored = request(url: url)
        stored.openedByUser = openedByUser
        return host.page(for: stored, writer: writer)
    }

    /// Asks the page's delegate for a destination as WebKit would; the file itself is never written.
    func startDownload(on page: LivePage, named name: String) async throws -> URL? {
        let delegate = try delegate(of: page)
        let download = await page.webView.startDownload(using: URLRequest(url: URL(string: "data:text/plain,abc")!))
        return await delegate.download(download, decideDestinationUsing: URLResponse(), suggestedFilename: name)
    }

    func mouse(_ type: NSEvent.EventType) throws -> NSEvent {
        try #require(NSEvent.mouseEvent(with: type, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: 0, context: nil, eventNumber: 0, clickCount: 1, pressure: 1))
    }

    func keyPress() throws -> NSEvent {
        try #require(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: 0, context: nil, characters: "a", charactersIgnoringModifiers: "a", isARepeat: false, keyCode: 0))
    }

    @Test func storedPageDownloadsNothingUntilTheUserActs() async throws {
        let dir = try tempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        events.downloadsDirectory = dir
        let host = makeHost()
        let page = try await storedPage(host)
        #expect(try await startDownload(on: page, named: "auto.txt") == nil)
        #expect(events.downloads.items(for: .profile(page.tabID)).isEmpty)
        // Refused without asking: no "several files" question either.
        #expect(events.severalDownloadsQuestions.isEmpty)
        // A key pressed in the page is the user acting on it. The refused download counted as the document's first, so this one asks.
        page.webView.keyDown(with: try keyPress())
        #expect(!page.awaitsUserAction)
        #expect(try await startDownload(on: page, named: "asked.txt") != nil)
        #expect(events.severalDownloadsQuestions.count == 1)
        #expect(events.downloads.items(for: .profile(page.tabID)).map(\.filename) == ["asked.txt"])
        host.close(page.tabID)
    }

    /// The page asks, as Safari does, instead of refusing in silence; the answer's download counts as the document's first.
    @Test func storedPageAsksBeforeItsFirstDownloadAndAllowedOneProceeds() async throws {
        let dir = try tempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        events.downloadsDirectory = dir
        events.downloadAnswer = true
        let host = makeHost()
        let page = try await storedPage(host, url: "https://files.example.com/list")
        #expect(try await startDownload(on: page, named: "first.txt") != nil)
        #expect(events.downloadQuestions.count == 1)
        #expect(events.downloadQuestions.first?.tabID == page.tabID)
        #expect(events.downloadQuestions.first?.host == "files.example.com")
        #expect(events.downloads.items(for: .profile(page.tabID)).map(\.filename) == ["first.txt"])
        // Still untouched, and the next one is the several-files question, not this one again.
        #expect(page.awaitsUserAction)
        events.severalDownloadsAnswer = false
        #expect(try await startDownload(on: page, named: "second.txt") == nil)
        #expect(events.downloadQuestions.count == 1)
        #expect(events.severalDownloadsQuestions.count == 1)
        host.close(page.tabID)
    }

    @Test func storedPageRefusedDownloadStillCountsAsTheFirst() async throws {
        let dir = try tempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        events.downloadsDirectory = dir
        events.downloadAnswer = false
        events.severalDownloadsAnswer = true
        let host = makeHost()
        let page = try await storedPage(host)
        #expect(try await startDownload(on: page, named: "first.txt") == nil)
        #expect(events.downloadQuestions.count == 1)
        #expect(events.downloads.items(for: .profile(page.tabID)).isEmpty)
        // The next one goes through the several-files question (answered Allow here).
        #expect(try await startDownload(on: page, named: "second.txt") != nil)
        #expect(events.severalDownloadsQuestions.count == 1)
        #expect(events.downloadQuestions.count == 1)
        host.close(page.tabID)
    }

    @Test func storedPageAsksOneDownloadQuestionAtATime() async throws {
        let dir = try tempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        events.downloadsDirectory = dir
        events.downloadAnswer = true
        let host = makeHost()
        let page = try await storedPage(host)
        var second: URL?? = .none
        events.whileAskingToDownload = { [self] in
            // A second download arrives while the first one's question is up.
            second = .some(try? await startDownload(on: page, named: "second.txt"))
        }
        #expect(try await startDownload(on: page, named: "first.txt") != nil)
        #expect(second == .some(nil))
        #expect(events.downloadQuestions.count == 1)
        #expect(events.severalDownloadsQuestions.isEmpty)
        host.close(page.tabID)
    }

    @Test func pageTheUserActedOnDownloadsWithoutThisQuestion() async throws {
        let dir = try tempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        events.downloadsDirectory = dir
        let host = makeHost()
        let page = try await storedPage(host)
        page.userActed()
        #expect(try await startDownload(on: page, named: "a.txt") != nil)
        #expect(events.downloadQuestions.isEmpty)
        host.close(page.tabID)
    }

    @Test func restoredStateDownloadsNothingUntilTheUserActs() async throws {
        let dir = try tempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        events.downloadsDirectory = dir
        let host = makeHost()
        host.testRuleLists = [try await blockAllRuleList()]
        // Real state from a page that loaded, so the restore path (not the stored URL) runs.
        let first = host.page(for: request(), writer: writer)
        first.webView.loadHTMLString("<title>T</title>", baseURL: URL(string: "https://example.com/"))
        #expect(try await waitUntil { first.status.title == "T" && !first.webView.isLoading })
        let state = try #require(first.webView.interactionState as? Data)
        host.close(first.tabID)

        let page = host.page(for: request(url: "https://example.com/", state: state), writer: writer)
        #expect(page.didRestoreState)
        #expect(try await startDownload(on: page, named: "auto.txt") == nil)
        page.webView.keyDown(with: try keyPress())
        #expect(try await startDownload(on: page, named: "after.txt") != nil)
        host.close(page.tabID)
    }

    @Test func pageCommandsAndTypingCountAsTheUserActing() async throws {
        let dir = try tempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        events.downloadsDirectory = dir
        let host = makeHost()
        let acts: [(LivePage) throws -> Void] = [
            { $0.webView.mouseDown(with: try mouse(.leftMouseDown)) },
            { $0.webView.rightMouseDown(with: try mouse(.rightMouseDown)) },
            { $0.webView.otherMouseDown(with: try mouse(.otherMouseDown)) },
            { $0.webView.reload() },
            { $0.webView.reloadFromOrigin() },
            { $0.webView.goBack() },
            { $0.webView.goForward() },
            { host.loadTyped("https://example.com/typed", in: $0.tabID) },
            // The app's Reload after a failed first load, which loads the stored address instead of calling reload().
            { $0.userActed() },
        ]
        for act in acts {
            let page = try await storedPage(host)
            #expect(try await startDownload(on: page, named: "auto.txt") == nil)
            try act(page)
            #expect(try await startDownload(on: page, named: "after.txt") != nil)
            host.close(page.tabID)
        }
    }

    @Test func linkOpenedByTheUserMayDownloadAtOnce() async throws {
        let dir = try tempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        events.downloadsDirectory = dir
        let host = makeHost()
        // A ⌘-click or "Open Link in New Tab" page: the user asked for this link, which may be a file.
        let page = try await storedPage(host, url: "https://example.com/file.zip", openedByUser: true)
        #expect(try await startDownload(on: page, named: "file.zip") != nil)
        host.close(page.tabID)
    }

    @Test func pageWithNothingStoredMayDownload() async throws {
        let dir = try tempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        events.downloadsDirectory = dir
        let host = makeHost()
        // A blank page made for a typed address loads nothing by itself.
        let page = host.page(for: request(), writer: writer)
        #expect(try await startDownload(on: page, named: "a.txt") != nil)
        host.close(page.tabID)
    }

    @Test func pagesOwnNavigationsDontCountAsTheUserActing() async throws {
        let host = makeHost()
        let page = try await storedPage(host)
        let delegate = try delegate(of: page)
        // A script's location.reload(), history.back() and link clicks reach Stave only as navigations, never as the web view's
        // reload() or goBack(); they leave the page waiting.
        for type in [WKNavigationType.reload, .backForward, .linkActivated, .other, .formSubmitted] {
            _ = delegate.decide(NavigationRequest("https://example.com/next", type: type))
        }
        #expect(page.awaitsUserAction)
        host.close(page.tabID)
    }

    @Test func linkFromAnUntouchedPageIsNotOpenedByTheUser() async throws {
        let host = makeHost()
        let page = try await storedPage(host)
        // A script can fake a ⌘-click; a tab it opens from a page nobody touched waits too.
        #expect(!host.linkOpenedByUser(opener: page.tabID))
        page.webView.mouseDown(with: try mouse(.leftMouseDown))
        #expect(host.linkOpenedByUser(opener: page.tabID))
        #expect(!host.linkOpenedByUser(opener: UUID()))
        host.close(page.tabID)
    }
}
