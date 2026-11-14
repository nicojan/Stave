import Foundation
import Testing
@testable import StaveCore

@Suite struct PageRecorderTests {
    private let t0 = Date(timeIntervalSince1970: 1_000_000)
    private func at(_ s: TimeInterval) -> Date { t0.addingTimeInterval(s) }
    private func make() -> PageRecorder { PageRecorder(url: "https://example.com", title: "A", faviconURL: nil) }

    @Test func commitClearsTitleAndWritesOnce() {
        var r = make()
        #expect(r.record(.committed(url: "https://example.org"), at: at(0)) == [.navigation(url: "https://example.org", title: "", faviconURL: nil)])
        #expect(r.record(.title("B"), at: at(1)) == [.navigation(url: "https://example.org", title: "B", faviconURL: nil)])
        #expect(r.record(.title("B"), at: at(2)).isEmpty)
    }

    /// A fragment or `pushState` change keeps the document, so its title and favicon stay.
    @Test func sameDocumentKeepsTitleAndFavicon() {
        var r = PageRecorder(url: "https://example.com", title: "A", faviconURL: "https://example.com/f.ico")
        #expect(r.record(.sameDocument(url: "https://example.com/#b"), at: at(0)) == [.navigation(url: "https://example.com/#b", title: "A", faviconURL: "https://example.com/f.ico")])
        #expect(r.record(.sameDocument(url: "https://example.com/#b"), at: at(1)).isEmpty)
    }

    @Test func faviconWritesWithPage() {
        var r = make()
        let expected = PageWrite.navigation(url: "https://example.com", title: "A", faviconURL: "https://example.org/f.ico")
        #expect(r.record(.favicon("https://example.org/f.ico"), at: at(0)) == [expected])
        #expect(r.record(.favicon("https://example.org/f.ico"), at: at(1)).isEmpty)
    }

    @Test func stateIsThrottled() {
        var r = make()
        #expect(r.record(.stateChanged, at: at(0)) == [.interactionState])
        #expect(r.record(.stateChanged, at: at(1)).isEmpty)
        #expect(r.record(.stateChanged, at: at(2.5)) == [.interactionState])
    }

    @Test func finishedFlushesPendingState() {
        var r = make()
        _ = r.record(.stateChanged, at: at(0))
        _ = r.record(.stateChanged, at: at(1))
        #expect(r.record(.finished, at: at(1.2)) == [.interactionState])
        #expect(r.record(.finished, at: at(1.3)).isEmpty)
    }

    @Test func flushEmitsOnlyPending() {
        var r = make()
        #expect(r.flush(at: at(0)).isEmpty)
        _ = r.record(.stateChanged, at: at(0))
        _ = r.record(.stateChanged, at: at(1))
        #expect(r.flush(at: at(1.1)) == [.interactionState])
        #expect(r.flush(at: at(1.2)).isEmpty)
    }

    @Test func closedRecorderEmitsNothing() {
        var r = make()
        _ = r.record(.stateChanged, at: at(0))
        _ = r.record(.stateChanged, at: at(1))
        r.close()
        #expect(r.record(.committed(url: "https://x.test"), at: at(5)).isEmpty)
        #expect(r.record(.title("Z"), at: at(5)).isEmpty)
        #expect(r.record(.favicon("f"), at: at(5)).isEmpty)
        #expect(r.record(.stateChanged, at: at(10)).isEmpty)
        #expect(r.record(.finished, at: at(10)).isEmpty)
        #expect(r.flush(at: at(10)).isEmpty)
    }

    /// A flush starts a new throttle window, so a change right after it waits for the interval again.
    @Test func flushResetsTheThrottleClock() {
        var r = make()
        _ = r.record(.stateChanged, at: at(0))
        _ = r.record(.stateChanged, at: at(1))
        #expect(r.flush(at: at(1.5)) == [.interactionState])
        #expect(r.record(.stateChanged, at: at(2.5)).isEmpty)
        #expect(r.record(.stateChanged, at: at(3.6)) == [.interactionState])
    }

    /// A commit that leaves address, title and favicon as stored (a reload of a page with no title yet) writes nothing.
    @Test func sameStateCommitWritesNothing() {
        var r = PageRecorder(url: "https://example.com", title: "", faviconURL: nil)
        #expect(r.record(.committed(url: "https://example.com"), at: at(0)).isEmpty)
        // With a title stored, the same address still writes, because a commit clears the title.
        var titled = make()
        #expect(titled.record(.committed(url: "https://example.com"), at: at(0)) == [.navigation(url: "https://example.com", title: "", faviconURL: nil)])
    }
}
