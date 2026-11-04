import Foundation
import StaveCore
import Testing
import WebKit

@testable import StaveWeb

/// Downloads that arrive while a download question is up wait for its answer and follow it (Chrome queues them behind the prompt).
extension PageDelegateTests {
    /// Starts a download on the page's delegate and returns the task its destination decision runs in.
    func decideInTask(_ delegate: PageDelegate, on page: LivePage, named name: String) -> Task<URL?, Never> {
        Task { @MainActor in
            let download = await page.webView.startDownload(using: URLRequest(url: URL(string: "data:text/plain,abc")!))
            return await delegate.download(download, decideDestinationUsing: URLResponse(), suggestedFilename: name)
        }
    }

    /// Starts `names` while a question is up, and returns once every one of them waits behind it.
    func startWaiting(_ names: [String], delegate: PageDelegate, on page: LivePage) async throws -> [Task<URL?, Never>] {
        let tasks = names.map { decideInTask(delegate, on: page, named: $0) }
        let waiting = try await waitUntil { delegate.waitingDownloadCount == names.count }
        #expect(waiting)
        return tasks
    }

    func downloadsDirectoryForQueueTests() throws -> URL {
        let dir = try tempDirectory()
        events.downloadsDirectory = dir
        return dir
    }

    @Test func downloadsWaitingBehindSeveralFilesFollowAnAllow() async throws {
        let dir = try downloadsDirectoryForQueueTests()
        defer { try? FileManager.default.removeItem(at: dir) }
        let host = makeHost()
        let page = host.page(for: request(), writer: writer)
        let delegate = try delegate(of: page)
        events.severalDownloadsAnswer = true
        var waiting: [Task<URL?, Never>] = []
        #expect(try await startDownload(on: page, named: "1.txt") != nil)
        events.whileAskingSeveral = { [self] in
            waiting = (try? await startWaiting(["3.txt", "4.txt"], delegate: delegate, on: page)) ?? []
        }
        #expect(try await startDownload(on: page, named: "2.txt") != nil)
        #expect(waiting.count == 2)
        for task in waiting { #expect(await task.value != nil) }
        // One question covered all of them.
        #expect(events.severalDownloadsQuestions.count == 1)
        #expect(delegate.waitingDownloadCount == 0)
        #expect(events.downloads.items(for: .profile(page.tabID)).count == 4)
        host.close(page.tabID)
    }

    @Test func downloadsWaitingBehindSeveralFilesAreRefusedAfterADeny() async throws {
        let dir = try downloadsDirectoryForQueueTests()
        defer { try? FileManager.default.removeItem(at: dir) }
        let host = makeHost()
        let page = host.page(for: request(), writer: writer)
        let delegate = try delegate(of: page)
        events.severalDownloadsAnswer = false
        var waiting: [Task<URL?, Never>] = []
        #expect(try await startDownload(on: page, named: "1.txt") != nil)
        events.whileAskingSeveral = { [self] in
            waiting = (try? await startWaiting(["3.txt", "4.txt"], delegate: delegate, on: page)) ?? []
        }
        #expect(try await startDownload(on: page, named: "2.txt") == nil)
        #expect(waiting.count == 2)
        for task in waiting { #expect(await task.value == nil) }
        #expect(events.severalDownloadsQuestions.count == 1)
        #expect(delegate.waitingDownloadCount == 0)
        #expect(events.downloads.items(for: .profile(page.tabID)).map(\.filename) == ["1.txt"])
        host.close(page.tabID)
    }

    /// The first-download question (a reopened page): downloads waiting behind it go on to one "several files" question covering them all.
    @Test func downloadsWaitingBehindTheFirstQuestionGoOnToOneSeveralFilesQuestion() async throws {
        for severalAllowed in [true, false] {
            let dir = try downloadsDirectoryForQueueTests()
            defer { try? FileManager.default.removeItem(at: dir) }
            events.downloadAnswer = true
            events.severalDownloadsAnswer = severalAllowed
            events.severalDownloadsQuestions = []
            let host = makeHost()
            let page = try await storedPage(host)
            let delegate = try delegate(of: page)
            var waiting: [Task<URL?, Never>] = []
            events.whileAskingToDownload = { [self] in
                waiting = (try? await startWaiting(["2.txt", "3.txt"], delegate: delegate, on: page)) ?? []
            }
            // The first itself was allowed, whatever the several-files answer is.
            #expect(try await startDownload(on: page, named: "1.txt") != nil)
            #expect(waiting.count == 2)
            for task in waiting { #expect((await task.value != nil) == severalAllowed) }
            #expect(events.severalDownloadsQuestions.count == 1)
            #expect(events.downloadQuestions.count >= 1)
            #expect(delegate.waitingDownloadCount == 0)
            events.downloadQuestions = []
            events.whileAskingToDownload = nil
            host.close(page.tabID)
        }
    }

    @Test func downloadsWaitingBehindADeclinedFirstQuestionAreRefusedWithoutAsking() async throws {
        let dir = try downloadsDirectoryForQueueTests()
        defer { try? FileManager.default.removeItem(at: dir) }
        events.downloadAnswer = false
        events.severalDownloadsAnswer = true
        let host = makeHost()
        let page = try await storedPage(host)
        let delegate = try delegate(of: page)
        var waiting: [Task<URL?, Never>] = []
        events.whileAskingToDownload = { [self] in
            waiting = (try? await startWaiting(["2.txt", "3.txt"], delegate: delegate, on: page)) ?? []
        }
        #expect(try await startDownload(on: page, named: "1.txt") == nil)
        for task in waiting { #expect(await task.value == nil) }
        #expect(events.severalDownloadsQuestions.isEmpty)
        #expect(delegate.waitingDownloadCount == 0)
        host.close(page.tabID)
    }

    @Test func downloadsWaitingWhenThePageNavigatesAreRefused() async throws {
        let dir = try downloadsDirectoryForQueueTests()
        defer { try? FileManager.default.removeItem(at: dir) }
        let host = makeHost()
        let page = host.page(for: request(), writer: writer)
        let delegate = try delegate(of: page)
        events.severalDownloadsAnswer = true
        var waiting: [Task<URL?, Never>] = []
        #expect(try await startDownload(on: page, named: "1.txt") != nil)
        events.whileAskingSeveral = { [self] in
            waiting = (try? await startWaiting(["3.txt"], delegate: delegate, on: page)) ?? []
            delegate.webView(page.webView, didCommit: nil)
        }
        _ = try await startDownload(on: page, named: "2.txt")
        #expect(waiting.count == 1)
        for task in waiting { #expect(await task.value == nil) }
        #expect(delegate.waitingDownloadCount == 0)
        host.close(page.tabID)
    }

    /// The page closing while downloads wait refuses them (the host tells the delegate), so no continuation is left behind.
    @Test func downloadsWaitingWhenThePageClosesAreRefused() async throws {
        let dir = try downloadsDirectoryForQueueTests()
        defer { try? FileManager.default.removeItem(at: dir) }
        let host = makeHost()
        let page = host.page(for: request(), writer: writer)
        let delegate = try delegate(of: page)
        events.severalDownloadsAnswer = true
        var waiting: [Task<URL?, Never>] = []
        #expect(try await startDownload(on: page, named: "1.txt") != nil)
        events.whileAskingSeveral = { [self] in
            waiting = (try? await startWaiting(["3.txt"], delegate: delegate, on: page)) ?? []
            host.close(page.tabID)
        }
        _ = try await startDownload(on: page, named: "2.txt")
        for task in waiting { #expect(await task.value == nil) }
        #expect(delegate.waitingDownloadCount == 0)
    }

    // MARK: A question that could not be asked is not an answer

    /// The sheet couldn't be shown (or came down): this download is refused, but that is not the user's Don't Allow, so the next one asks.
    @Test func severalFilesQuestionThatCouldNotBeAskedIsNotRecordedAsARefusal() async throws {
        let dir = try downloadsDirectoryForQueueTests()
        defer { try? FileManager.default.removeItem(at: dir) }
        let host = makeHost()
        let page = host.page(for: request(), writer: writer)
        #expect(try await startDownload(on: page, named: "1.txt") != nil)
        events.severalCouldNotAsk = true
        #expect(try await startDownload(on: page, named: "2.txt") == nil)
        #expect(events.severalDownloadsQuestions.count == 1)
        events.severalCouldNotAsk = false
        events.severalDownloadsAnswer = true
        #expect(try await startDownload(on: page, named: "3.txt") != nil)
        #expect(events.severalDownloadsQuestions.count == 2)
        // The Allow now holds for the rest of the document.
        #expect(try await startDownload(on: page, named: "4.txt") != nil)
        #expect(events.severalDownloadsQuestions.count == 2)
        host.close(page.tabID)
    }

    @Test func firstDownloadQuestionThatCouldNotBeAskedDoesNotStickAsADecline() async throws {
        let dir = try downloadsDirectoryForQueueTests()
        defer { try? FileManager.default.removeItem(at: dir) }
        let host = makeHost()
        let page = try await storedPage(host)
        events.downloadCouldNotAsk = true
        #expect(try await startDownload(on: page, named: "1.txt") == nil)
        #expect(events.downloadQuestions.count == 1)
        // A new document's first download asks again: nobody said no.
        page.committed()
        events.downloadCouldNotAsk = false
        events.downloadAnswer = true
        #expect(try await startDownload(on: page, named: "2.txt") != nil)
        #expect(events.downloadQuestions.count == 2)
        host.close(page.tabID)
    }

    /// The page commits after the first-download question was allowed but before the first waiting download takes over: that download is
    /// for the old page, so it is refused and no several-files question names the new page.
    @Test func handoffAfterAFirstDownloadAllowChecksThePageStillMatches() async throws {
        let dir = try downloadsDirectoryForQueueTests()
        defer { try? FileManager.default.removeItem(at: dir) }
        events.downloadAnswer = true
        events.severalDownloadsAnswer = true
        let host = makeHost()
        let page = try await storedPage(host)
        let delegate = try delegate(of: page)
        var waiting: [Task<URL?, Never>] = []
        events.whileAskingToDownload = { [self] in
            waiting = (try? await startWaiting(["2.txt"], delegate: delegate, on: page)) ?? []
            // Queued before the answer's handoff, so the commit runs first.
            Task { @MainActor in delegate.webView(page.webView, didCommit: nil) }
        }
        _ = try await startDownload(on: page, named: "1.txt")
        #expect(waiting.count == 1)
        for task in waiting { #expect(await task.value == nil) }
        #expect(events.severalDownloadsQuestions.isEmpty)
        #expect(delegate.waitingDownloadCount == 0)
        host.close(page.tabID)
    }
}
