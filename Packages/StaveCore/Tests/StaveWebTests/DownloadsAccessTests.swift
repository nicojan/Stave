import Foundation
import StaveCore
import Testing
import WebKit

@testable import StaveWeb

/// Stands in for macOS's Downloads-folder prompt: the folder check blocks its thread until `release()`.
final class BlockingProbe: @unchecked Sendable {
    private let gate = DispatchSemaphore(value: 0)
    private let lock = NSLock()
    private var calls: [Bool] = []

    /// Whether each check ran on the main thread.
    var ranOnMainThread: [Bool] { lock.withLock { calls } }

    func probe(_ directory: URL) -> FolderAccess {
        lock.withLock { calls.append(Thread.isMainThread) }
        // Bounded, so a check that blocks the main thread fails the test instead of hanging it.
        _ = gate.wait(timeout: .now() + 30)
        return .readable
    }

    func release() { gate.signal() }
}

/// The first-ever download froze the app while macOS asked about the Downloads folder: WebKit made the folder's sandbox extension on the
/// main thread, the first time Stave touched it (walkthrough fix 3). Stave now touches the folder first, off the main thread.
extension PageDelegateTests {
    func askForDestination(_ page: LivePage, named name: String) async throws -> URL? {
        try await askForDestination(page, download: await newDownload(page), named: name)
    }

    /// WebKit's download object, made before any timing starts: the first one can take seconds on a loaded CI runner.
    func newDownload(_ page: LivePage) async -> WKDownload {
        await page.webView.startDownload(using: URLRequest(url: URL(string: "data:text/plain,abc")!))
    }

    func askForDestination(_ page: LivePage, download: WKDownload, named name: String) async throws -> URL? {
        try await delegate(of: page).download(download, decideDestinationUsing: URLResponse(), suggestedFilename: name)
    }

    @Test func downloadsFolderIsCheckedOffTheMainThreadFirst() async throws {
        let dir = try tempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        events.downloadsDirectory = dir
        let host = makeHost()
        let probe = BlockingProbe()
        defer { probe.release() } // never leave a test thread blocked if an expectation stops the test early
        host.downloadsFolder.probe = { probe.probe($0) }
        let page = host.page(for: request(), writer: writer)

        let download = await newDownload(page)
        let asking = Task { try await askForDestination(page, download: download, named: "a.txt") }
        // While the check is blocked (the prompt is up), the main actor keeps running and nothing is handed to WebKit yet.
        #expect(try await waitUntil(seconds: 15) { probe.ranOnMainThread.count == 1 })
        #expect(probe.ranOnMainThread == [false])
        #expect(events.downloads.items(for: .profile(page.tabID)).isEmpty)
        probe.release()
        let destination = try await asking.value
        #expect(destination?.deletingLastPathComponent().standardizedFileURL == dir.standardizedFileURL)
        #expect(events.downloads.items(for: .profile(page.tabID)).map(\.filename) == ["a.txt"])
        host.close(page.tabID)
    }

    @Test func refusedDownloadsFolderFailsTheDownloadVisibly() async throws {
        let dir = try tempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        events.downloadsDirectory = dir
        let host = makeHost()
        host.downloadsFolder.probe = { _ in .refused }
        let page = host.page(for: request(), writer: writer)
        #expect(try await askForDestination(page, named: "a.txt") == nil)
        let rows = events.downloads.items(for: .profile(page.tabID))
        #expect(rows.map(\.filename) == ["a.txt"])
        #expect(rows.first?.state == .failed(PageText.downloadsFolderRefused))
        host.close(page.tabID)
    }

    @Test func otherFolderProblemsDontPointToSystemSettings() async throws {
        let dir = try tempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        events.downloadsDirectory = dir
        let host = makeHost()
        host.downloadsFolder.probe = { _ in .unavailable }
        let page = host.page(for: request(), writer: writer)
        #expect(try await askForDestination(page, named: "a.txt") == nil)
        #expect(events.downloads.items(for: .profile(page.tabID)).first?.state == .failed(PageText.downloadsFolderUnavailable))
        host.close(page.tabID)
    }

    @Test func downloadsWaitingOnTheQuestionShareOneCheck() async throws {
        let dir = try tempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        events.downloadsDirectory = dir
        let host = makeHost()
        let probe = BlockingProbe()
        defer { probe.release() }
        host.downloadsFolder.probe = { probe.probe($0) }
        // Two pages, so each one's first download goes ahead without the several-files question.
        let first = host.page(for: request(), writer: writer)
        let second = host.page(for: request(), writer: writer)
        let (firstDownload, secondDownload) = (await newDownload(first), await newDownload(second))
        let one = Task { try await askForDestination(first, download: firstDownload, named: "one.txt") }
        let two = Task { try await askForDestination(second, download: secondDownload, named: "two.txt") }
        #expect(try await waitUntil(seconds: 15) { probe.ranOnMainThread.count == 1 })
        try await Task.sleep(for: .milliseconds(200))
        #expect(probe.ranOnMainThread.count == 1)
        probe.release()
        #expect(try await one.value != nil)
        #expect(try await two.value != nil)
        #expect(probe.ranOnMainThread.count == 1)
        host.close(first.tabID)
        host.close(second.tabID)
    }

    @Test func realCheckOpensTheFolder() throws {
        let dir = try tempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        #expect(DownloadsFolderCheck.open(dir) == .readable)
        #expect(DownloadsFolderCheck.open(dir.appendingPathComponent("missing", isDirectory: true)) == .unavailable)
        let file = dir.appendingPathComponent("not-a-folder")
        try Data("x".utf8).write(to: file)
        #expect(DownloadsFolderCheck.open(file) == .unavailable)
    }
}
