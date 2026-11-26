import Foundation
import StaveCore
import Testing
import WebKit

@testable import StaveWeb

extension PageHost {
    /// Test seam: what WebKit's first progress report does, capturing the destination file's identity as this download's.
    func claimDownloadFile(_ rowID: UUID) {
        activeDownloads.claimDestination(forRow: rowID)
    }
}

/// Plan 3's Carried download fixes (plan 5 Task 14): quarantine, partial files, and same-name downloads.
extension WebKitTests.PageDelegateTests {
    /// The first mark, made when WebKit's first bytes arrived, took. A refresh at the end that throws must not delete the finished file or
    /// fail its row.
    @Test func finishedFileSurvivesARemarkFailure() async throws {
        let dir = try tempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        events.downloadsDirectory = dir
        let host = makeHost()
        let page = host.page(for: request(), writer: writer)
        let own = try await handDrivenDownload(host, page, name: "done.bin")
        try Data("all".utf8).write(to: own.destination)
        host.claimDownloadFile(own.row)
        #expect(Quarantine.isMarked(own.destination))
        host.markDownload = { _, _ in throw CocoaError(.fileWriteNoPermission) }

        host.downloadFinished(try #require(host.activeDownload(own.row)))

        #expect(try Data(contentsOf: own.destination) == Data("all".utf8))
        #expect(Quarantine.isMarked(own.destination))
        #expect(events.downloads.items(for: .profile(page.tabID)).first { $0.id == own.row }?.state == .finished(own.destination))
        host.close(page.tabID)
    }

    /// A download that fails with bytes on disk but no progress report seen (so never claimed) is claimed at the failure: the partial is
    /// quarantined, never left unmarked.
    @Test func failedClaimsThePartial() async throws {
        let dir = try tempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        events.downloadsDirectory = dir
        let host = makeHost()
        let page = host.page(for: request(), writer: writer)
        host.downloadWroteBytes = { _ in true } // WebKit's count shows it wrote
        let own = try await handDrivenDownload(host, page, name: "half.bin")
        try Data("half".utf8).write(to: own.destination) // WebKit wrote it, but no progress report reached the app
        #expect(!Quarantine.isMarked(own.destination))

        host.downloadFailed(try #require(host.activeDownload(own.row)), message: "Network lost")

        #expect(Quarantine.isMarked(own.destination))
        #expect(FileManager.default.fileExists(atPath: own.destination.path), "the partial stays, marked")
        host.close(page.tabID)
    }

    /// Another program creates a file at the destination after `begin` and before WebKit writes (so it is newer than the download), and the
    /// download then fails with nothing written by WebKit. The file is not claimed: not marked, and not removed when marking would fail.
    @Test func failedNeverClaimsAFileAnotherProgramCreatedAfterBegin() async throws {
        let dir = try tempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        events.downloadsDirectory = dir
        let host = makeHost()
        host.markDownload = { _, _ in throw CocoaError(.fileWriteNoPermission) }
        host.downloadWroteBytes = { _ in false } // WebKit's own count: nothing written
        let page = host.page(for: request(), writer: writer)
        let own = try await handDrivenDownload(host, page, name: "race.bin")
        try Data("theirs".utf8).write(to: own.destination) // created now, newer than the download's start

        host.downloadFailed(try #require(host.activeDownload(own.row)), message: "File exists")

        #expect(try Data(contentsOf: own.destination) == Data("theirs".utf8))
        #expect(!Quarantine.isMarked(own.destination))
        host.close(page.tabID)
    }

    /// A file that was already at the destination before the download began is not the download's: a failure neither marks nor removes it
    /// (a mark that can't be made would otherwise delete someone else's file), even when WebKit's count says it wrote.
    @Test func failedLeavesAFileThatWasThereBeforeAlone() async throws {
        let dir = try tempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        events.downloadsDirectory = dir
        let host = makeHost()
        host.markDownload = { _, _ in throw CocoaError(.fileWriteNoPermission) }
        host.downloadWroteBytes = { _ in true } // WebKit's count says it wrote, so only the creation-date check keeps the old file out
        let page = host.page(for: request(), writer: writer)
        let own = try await handDrivenDownload(host, page, name: "old.bin")
        try Data("older".utf8).write(to: own.destination)
        try FileManager.default.setAttributes([.creationDate: Date(timeIntervalSinceNow: -3600)], ofItemAtPath: own.destination.path)

        host.downloadFailed(try #require(host.activeDownload(own.row)), message: "File exists")

        #expect(try Data(contentsOf: own.destination) == Data("older".utf8))
        #expect(!Quarantine.isMarked(own.destination))
        host.close(page.tabID)
    }

    /// Two downloads of the same name that start together (neither has written yet) get different names, and the name frees when its
    /// download ends.
    @Test func concurrentSameNameDownloadsDontCollide() async throws {
        let dir = try tempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        events.downloadsDirectory = dir
        let host = makeHost()
        let page = host.page(for: request(), writer: writer)
        events.severalDownloadsAnswer = true
        let first = try await handDrivenDownload(host, page, name: "name.txt")
        let second = try await handDrivenDownload(host, page, name: "name.txt")
        let third = try await handDrivenDownload(host, page, name: "name.txt")
        #expect(first.destination.lastPathComponent == "name.txt")
        #expect(second.destination.lastPathComponent == "name (2).txt")
        #expect(third.destination.lastPathComponent == "name (3).txt")
        // Truly at once: three decisions in flight together.
        let delegate = try delegate(of: page)
        let a = decideInTask(delegate, on: page, named: "same.txt")
        let b = decideInTask(delegate, on: page, named: "same.txt")
        let names = try await Set([#require(await a.value), #require(await b.value)].map(\.lastPathComponent))
        #expect(names == ["same.txt", "same (2).txt"])
        // The first download ends: its name is free for the next one.
        events.downloads.cancel(first.row)
        let again = try await handDrivenDownload(host, page, name: "name.txt")
        #expect(again.destination.lastPathComponent == "name.txt")
        host.close(page.tabID)
    }

    /// The raw `com.apple.quarantine` attribute: flags;timestamp;agent (empty here);event ID.
    static func quarantineAttribute(_ file: URL) throws -> String {
        let name = "com.apple.quarantine"
        let size = getxattr(file.path, name, nil, 0, 0, 0)
        guard size > 0 else { throw CocoaError(.fileReadNoSuchFile) }
        var buffer = [UInt8](repeating: 0, count: size)
        let read = getxattr(file.path, name, &buffer, size, 0, 0)
        guard read > 0 else { throw CocoaError(.fileReadUnknown) }
        return String(decoding: buffer.prefix(read), as: UTF8.self)
    }

    /// The source page and download URL go into the quarantine properties handed to LaunchServices (the input, which is what names the site,
    /// decision 23), and the record the file system stores carries Stave's agent and the event ID the xattr names. The delegate passes both URLs.
    @Test func quarantineReceivesTheSourceAndStoresAnEvent() async throws {
        let source = QuarantineSource(download: URL(string: "https://cdn.example.com/f.zip"), page: URL(string: "https://example.com/page"))
        let properties = Quarantine.properties(for: source)
        #expect(properties[kLSQuarantineDataURLKey as String] as? URL == URL(string: "https://cdn.example.com/f.zip"))
        #expect(properties[kLSQuarantineOriginURLKey as String] as? URL == URL(string: "https://example.com/page"))
        #expect(properties[kLSQuarantineAgentNameKey as String] as? String == "Stave")
        let bare = Quarantine.properties(for: nil)
        #expect(bare[kLSQuarantineDataURLKey as String] == nil && bare[kLSQuarantineOriginURLKey as String] == nil)

        // What the file system stores, read back fresh (not the inputs). On this macOS the stored record does not carry the source URLs
        // back (`quarantineProperties` returns agent, type, time and event ID only, and the events database's URL columns are empty for
        // every agent, Chrome's included; checked 2026-11-26), so the URLs are checked at the input above and in the delegate test below,
        // and here the record that was stored: Stave's agent, a LaunchServices event, and the same event ID in the xattr itself.
        let stored = try tempDirectory()
        defer { try? FileManager.default.removeItem(at: stored) }
        let markedFile = stored.appendingPathComponent("marked.zip")
        try Data("zip".utf8).write(to: markedFile)
        #expect(!Quarantine.isMarked(markedFile))
        try Quarantine.mark(markedFile, source: source)
        let readBack = try URL(fileURLWithPath: markedFile.path).resourceValues(forKeys: [.quarantinePropertiesKey]).quarantineProperties
        let storedProperties = try #require(readBack)
        #expect(storedProperties[kLSQuarantineAgentNameKey as String] as? String == "Stave")
        let eventID = try #require(storedProperties["LSQuarantineEventIdentifier"] as? String)
        #expect(Quarantine.isMarked(markedFile))
        let xattr = try Self.quarantineAttribute(markedFile)
        #expect(xattr.uppercased().contains(eventID.uppercased()), "the xattr names the same event")

        // Through the delegate: the seam receives both URLs for a real page and a download of another origin.
        let dir = try tempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        events.downloadsDirectory = dir
        let host = makeHost()
        var marked: [QuarantineSource?] = []
        host.markDownload = { file, source in
            marked.append(source)
            try Quarantine.mark(file, source: source)
        }
        let page = host.page(for: request(), writer: writer)
        page.webView.loadHTMLString("<title>T</title>", baseURL: URL(string: "https://example.com/page"))
        #expect(try await waitUntil { page.status.title == "T" && !page.webView.isLoading })
        let delegate = try delegate(of: page)
        let download = await page.webView.startDownload(using: URLRequest(url: URL(string: "https://cdn.example.com/f.zip")!))
        let destination = try #require(await delegate.download(download, decideDestinationUsing: URLResponse(), suggestedFilename: "f.zip"))
        let row = try #require(events.downloads.items(for: .profile(page.tabID)).first)
        try Data("zip".utf8).write(to: destination)
        host.claimDownloadFile(row.id)
        #expect(marked.first == source)
        #expect(row.sourceHost == "cdn.example.com")
        host.close(page.tabID)
    }
}
