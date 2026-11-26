import Foundation
import StaveCore
import Testing
import WebKit

@testable import StaveWeb

/// Downloads that arrive while a download question is up wait for its answer and follow it (Chrome queues them behind the prompt).
extension WebKitTests.PageDelegateTests {
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

    /// The question is dropped before the user chose (the app's queue resolves it with no answer): this download is refused, but that is not
    /// the user's Don't Allow, so the next one asks again. Nothing is recorded.
    @Test func severalFilesQuestionThatCouldNotBeAskedIsNotRecordedAsARefusal() async throws {
        let dir = try downloadsDirectoryForQueueTests()
        defer { try? FileManager.default.removeItem(at: dir) }
        let host = makeHost()
        let page = host.page(for: request(), writer: writer)
        let delegate = try delegate(of: page)
        #expect(try await startDownload(on: page, named: "1.txt") != nil)
        // It can't be asked now (its tab is hidden): held, not refused.
        events.holdSeveralQuestion = true
        let held = decideInTask(delegate, on: page, named: "2.txt")
        #expect(try await waitUntil { events.isSeveralQuestionHeld })
        #expect(events.severalDownloadsQuestions.count == 1)
        events.dropHeldSeveral()
        #expect(await held.value == nil)
        #expect(delegate.waitingDownloadCount == 0)
        // The next download of the same document asks again, and its Allow holds for the rest of the document.
        events.holdSeveralQuestion = false
        events.severalDownloadsAnswer = true
        #expect(try await startDownload(on: page, named: "3.txt") != nil)
        #expect(events.severalDownloadsQuestions.count == 2)
        #expect(try await startDownload(on: page, named: "4.txt") != nil)
        #expect(events.severalDownloadsQuestions.count == 2)
        host.close(page.tabID)
    }

    /// Question 7: a held answer reaches `downloadGate`. The downloads that arrive while the question is held wait behind it, and one
    /// Allow lets them and the rest of the document through, with no second question.
    @Test func heldSeveralFilesAnswerReachesTheDownloadGate() async throws {
        let dir = try downloadsDirectoryForQueueTests()
        defer { try? FileManager.default.removeItem(at: dir) }
        let host = makeHost()
        let page = host.page(for: request(), writer: writer)
        let delegate = try delegate(of: page)
        #expect(try await startDownload(on: page, named: "1.txt") != nil)
        events.holdSeveralQuestion = true
        let held = decideInTask(delegate, on: page, named: "2.txt")
        #expect(try await waitUntil { events.isSeveralQuestionHeld })
        let behind = try await startWaiting(["3.txt", "4.txt"], delegate: delegate, on: page)
        events.answerHeldSeveral(.allowed)
        #expect(await held.value != nil)
        for task in behind { #expect(await task.value != nil) }
        events.holdSeveralQuestion = false
        #expect(try await startDownload(on: page, named: "5.txt") != nil)
        #expect(events.severalDownloadsQuestions.count == 1)
        #expect(events.downloads.items(for: .profile(page.tabID)).count == 5)
        host.close(page.tabID)
    }

    /// WebKit fails a download while its question is held. The late Allow gives it no row and no reserved name: the next download of the
    /// same name gets the plain name.
    @Test func downloadThatFailedWhileHeldGetsNoRowAndNoName() async throws {
        let dir = try downloadsDirectoryForQueueTests()
        defer { try? FileManager.default.removeItem(at: dir) }
        let host = makeHost()
        let page = host.page(for: request(), writer: writer)
        let delegate = try delegate(of: page)
        #expect(try await startDownload(on: page, named: "1.txt") != nil)
        events.holdSeveralQuestion = true
        let download = await page.webView.startDownload(using: URLRequest(url: URL(string: "data:text/plain,abc")!))
        let held = Task { @MainActor in
            await delegate.download(download, decideDestinationUsing: URLResponse(), suggestedFilename: "late.txt")
        }
        #expect(try await waitUntil { events.isSeveralQuestionHeld })

        host.downloadFailed(download, message: "Network lost") // WebKit gives up while the question is up
        events.answerHeldSeveral(.allowed)

        #expect(await held.value == nil)
        #expect(events.downloads.items(for: .profile(page.tabID)).map(\.filename) == ["1.txt"], "no Downloading row")
        events.holdSeveralQuestion = false
        let next = try #require(try await startDownload(on: page, named: "late.txt"))
        #expect(next.lastPathComponent == "late.txt", "the failed download reserved no name")
        host.close(page.tabID)
    }

    /// WebKit fails a download while the Downloads folder is being listed (after the questions, before the row): no row, and the name that
    /// was reserved is given back, so the next download of that name gets the plain one.
    @Test func downloadThatFailedDuringTheFolderListingGetsNoRowAndNoName() async throws {
        let dir = try downloadsDirectoryForQueueTests()
        defer { try? FileManager.default.removeItem(at: dir) }
        let host = makeHost()
        let page = host.page(for: request(), writer: writer)
        let delegate = try delegate(of: page)
        let gate = ListingGate()
        host.folderListing = { _ in await gate.hold() }
        let download = await page.webView.startDownload(using: URLRequest(url: URL(string: "data:text/plain,abc")!))
        let deciding = Task { @MainActor in
            await delegate.download(download, decideDestinationUsing: URLResponse(), suggestedFilename: "late.txt")
        }
        #expect(try await waitUntil { gate.isHolding })

        host.downloadFailed(download, message: "Network lost") // WebKit gives up while the folder is being read
        gate.release()

        #expect(await deciding.value == nil)
        #expect(events.downloads.items(for: .profile(page.tabID)).isEmpty, "no Downloading row")
        host.folderListing = { await PageHost.existingNames(in: $0) }
        let next = try #require(try await startDownload(on: page, named: "late.txt"))
        #expect(next.lastPathComponent == "late.txt", "the failed download kept no name")
        host.close(page.tabID)
    }

    /// Question 7: a held Don't Allow refuses the waiting downloads and the rest of the document.
    @Test func heldSeveralFilesDeclineRefusesTheRestOfTheDocument() async throws {
        let dir = try downloadsDirectoryForQueueTests()
        defer { try? FileManager.default.removeItem(at: dir) }
        let host = makeHost()
        let page = host.page(for: request(), writer: writer)
        let delegate = try delegate(of: page)
        #expect(try await startDownload(on: page, named: "1.txt") != nil)
        events.holdSeveralQuestion = true
        let held = decideInTask(delegate, on: page, named: "2.txt")
        #expect(try await waitUntil { events.isSeveralQuestionHeld })
        let behind = try await startWaiting(["3.txt"], delegate: delegate, on: page)
        events.answerHeldSeveral(.declined)
        #expect(await held.value == nil)
        for task in behind { #expect(await task.value == nil) }
        events.holdSeveralQuestion = false
        #expect(try await startDownload(on: page, named: "4.txt") == nil)
        #expect(events.severalDownloadsQuestions.count == 1)
        #expect(events.downloads.items(for: .profile(page.tabID)).map(\.filename) == ["1.txt"])
        host.close(page.tabID)
    }

    /// Question 7: a new committed document drops the held question and refuses its downloads, with nothing recorded; the new document asks
    /// afresh.
    @Test func heldQuestionDroppedOnNavigation() async throws {
        let dir = try downloadsDirectoryForQueueTests()
        defer { try? FileManager.default.removeItem(at: dir) }
        let host = makeHost()
        let page = host.page(for: request(), writer: writer)
        let delegate = try delegate(of: page)
        #expect(try await startDownload(on: page, named: "1.txt") != nil)
        events.holdSeveralQuestion = true
        let held = decideInTask(delegate, on: page, named: "2.txt")
        #expect(try await waitUntil { events.isSeveralQuestionHeld })
        let behind = try await startWaiting(["3.txt"], delegate: delegate, on: page)

        delegate.webView(page.webView, didCommit: nil) // the new document: the queue's question is dropped, the waiting downloads refused

        #expect(await held.value == nil)
        for task in behind { #expect(await task.value == nil) }
        #expect(events.cancelledTabs.contains(page.tabID))
        #expect(delegate.waitingDownloadCount == 0)
        #expect(events.downloads.items(for: .profile(page.tabID)).map(\.filename) == ["1.txt"])
        // Nothing was recorded: the new document's first download goes ahead and its second asks again.
        events.holdSeveralQuestion = false
        events.severalDownloadsAnswer = true
        #expect(try await startDownload(on: page, named: "4.txt") != nil)
        #expect(try await startDownload(on: page, named: "5.txt") != nil)
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

/// Holds a folder listing open until the test lets it go. A lock, not an actor, so the test can poll `isHolding` synchronously.
final class ListingGate: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Void, Never>?
    private var holding = false

    var isHolding: Bool { lock.withLock { holding } }

    func hold() async -> Set<String> {
        await withCheckedContinuation { next in
            lock.withLock {
                continuation = next
                holding = true
            }
        }
        return []
    }

    func release() {
        let waiting = lock.withLock { () -> CheckedContinuation<Void, Never>? in
            defer { continuation = nil }
            return continuation
        }
        waiting?.resume()
    }
}
