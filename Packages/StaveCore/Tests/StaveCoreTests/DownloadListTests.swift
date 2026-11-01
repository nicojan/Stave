import Foundation
import Testing
@testable import StaveCore

@Suite struct DownloadListTests {
    /// A private window closing cancels its running rows only: a finished row and another owner's running row are left alone.
    @MainActor @Test func cancelRunningCancelsOnlyThatOwnersRunningRows() {
        let list = DownloadList()
        var cancelled: [UUID] = []
        list.onCancel = { cancelled.append($0) }
        let window = DownloadOwner.privateWindow(UUID())
        let running = list.begin(owner: window, filename: "a.bin", sourceHost: nil)
        let done = list.begin(owner: window, filename: "b.bin", sourceHost: nil)
        list.finish(done, at: URL(fileURLWithPath: "/tmp/b.bin"))
        let profile = DownloadOwner.profile(UUID())
        let other = list.begin(owner: profile, filename: "c.bin", sourceHost: nil)
        list.cancelRunning(owner: window)
        #expect(cancelled == [running])
        #expect(list.items(for: window).first { $0.id == running }?.state == .cancelled)
        #expect(list.items(for: window).first { $0.id == done }?.state == .finished(URL(fileURLWithPath: "/tmp/b.bin")))
        #expect(list.items(for: profile).first { $0.id == other }?.state == .running(fraction: nil))
    }

    @Test func filenamesAreSanitized() {
        #expect(DownloadFilename.sanitized("../../.zshrc") == "zshrc")
        #expect(DownloadFilename.sanitized(".hidden") == "hidden")
        #expect(DownloadFilename.sanitized("a/b.txt") == "a-b.txt")
        #expect(DownloadFilename.sanitized("a:b.txt") == "a-b.txt")
        #expect(DownloadFilename.sanitized("") == "download")
        #expect(DownloadFilename.sanitized("...") == "download")
        #expect(DownloadFilename.sanitized("x\u{0}\u{7}y.pdf") == "xy.pdf")
        #expect(DownloadFilename.sanitized("rapport été.pdf") == "rapport été.pdf")
        for hostile in ["a/\u{200D}b", "a/\u{301}b", "a:\u{301}b", "/\u{301}x", ".\u{200D}.zshrc", "/\u{200D}/\u{301}.x"] {
            let out = DownloadFilename.sanitized(hostile)
            #expect(!out.unicodeScalars.contains("/") && !out.unicodeScalars.contains(":"))
            #expect(!out.hasPrefix("."))
            #expect(out.unicodeScalars.first.map { $0 != "." && $0.properties.generalCategory != .format } ?? false)
        }
        let long = DownloadFilename.sanitized(String(repeating: "a", count: 300) + ".pdf")
        #expect(long.utf8.count <= 200)
        #expect(long.hasSuffix(".pdf"))
        let multi = DownloadFilename.sanitized(String(repeating: "é", count: 200) + ".pdf")
        #expect(multi.utf8.count <= 200)
        #expect(multi.hasSuffix(".pdf"))
        #expect(String(multi.dropLast(4)).allSatisfy { $0 == "é" })
        let absurd = DownloadFilename.sanitized("a." + String(repeating: "b", count: 400))
        #expect(absurd.utf8.count <= 200)
    }

    @Test func collisionsGetNumbered() {
        let dir = URL(fileURLWithPath: "/private/tmp/stave-dl-test", isDirectory: true)
        let taken: Set<String> = ["report.pdf", "report (2).pdf", "notes"]
        let exists: (URL) -> Bool = { taken.contains($0.lastPathComponent) }
        let a = DownloadFilename.unique("report.pdf", in: dir, exists: exists)
        #expect(a.lastPathComponent == "report (3).pdf")
        #expect(a.deletingLastPathComponent().path == dir.path)
        let b = DownloadFilename.unique("notes", in: dir, exists: exists)
        #expect(b.lastPathComponent == "notes (2)")
        let c = DownloadFilename.unique("free.txt", in: dir, exists: exists)
        #expect(c.lastPathComponent == "free.txt")
        let d = DownloadFilename.unique("../x.txt", in: dir, exists: { _ in false })
        #expect(d.deletingLastPathComponent().path == dir.path)
    }

    @MainActor @Test func listOrdersAndSeparatesOwners() {
        let list = DownloadList()
        let p = DownloadOwner.profile(UUID())
        let w = DownloadOwner.privateWindow(UUID())
        let a = list.begin(owner: p, filename: "a", sourceHost: "x.com")
        let b = list.begin(owner: p, filename: "b", sourceHost: nil)
        _ = list.begin(owner: w, filename: "c", sourceHost: nil)
        #expect(list.items(for: p).map(\.id) == [b, a])
        #expect(list.items(for: w).count == 1)
        list.dropOwner(w)
        #expect(list.items(for: w).isEmpty)
        #expect(list.items(for: p).count == 2)
    }

    @MainActor @Test func rowEndsOnce() throws {
        let list = DownloadList()
        let p = DownloadOwner.profile(UUID())
        var cancels: [UUID] = []
        list.onCancel = { cancels.append($0) }
        let a = list.begin(owner: p, filename: "a", sourceHost: nil)
        list.cancel(a)
        list.finish(a, at: URL(fileURLWithPath: "/private/tmp/a"))
        list.cancel(a)
        #expect(list.items(for: p)[0].state == .cancelled)
        #expect(cancels == [a])

        let b = list.begin(owner: p, filename: "b", sourceHost: nil)
        list.progress(b, fraction: 0.5)
        #expect(list.items(for: p)[0].state == .running(fraction: 0.5))
        let url = URL(fileURLWithPath: "/private/tmp/b")
        list.finish(b, at: url)
        list.progress(b, fraction: 0.9)
        list.fail(b, message: "x")
        #expect(list.items(for: p)[0].state == .finished(url))
    }

    @MainActor @Test func clearFinishedKeepsRunning() {
        let list = DownloadList()
        let p = DownloadOwner.profile(UUID())
        let q = DownloadOwner.profile(UUID())
        let run = list.begin(owner: p, filename: "run", sourceHost: nil)
        let done = list.begin(owner: p, filename: "done", sourceHost: nil)
        let bad = list.begin(owner: p, filename: "bad", sourceHost: nil)
        let gone = list.begin(owner: p, filename: "gone", sourceHost: nil)
        let other = list.begin(owner: q, filename: "o", sourceHost: nil)
        list.finish(done, at: URL(fileURLWithPath: "/private/tmp/d"))
        list.fail(bad, message: "m")
        list.cancel(gone)
        list.finish(other, at: URL(fileURLWithPath: "/private/tmp/o"))
        list.clearFinished(owner: p)
        #expect(list.items(for: p).map(\.id) == [run])
        #expect(list.items(for: q).count == 1)
    }
}
