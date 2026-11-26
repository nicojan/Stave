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

    // MARK: Coalesced title writes (plan 5, Task 15)

    /// A title-only change within 500 ms of the last navigation write waits; the latest title is the one written, once. The clock is the
    /// `at:` argument, so nothing here sleeps.
    @Test func titleWritesCoalesced() {
        var r = make()
        #expect(r.record(.committed(url: "https://example.org"), at: at(0)) == [.navigation(url: "https://example.org", title: "", faviconURL: nil)])
        // A burst of titles inside the window: nothing is written, the recorder remembers it owes one.
        #expect(r.record(.title("B"), at: at(0.1)).isEmpty)
        #expect(r.record(.title("C"), at: at(0.2)).isEmpty)
        #expect(r.record(.title("D"), at: at(0.3)).isEmpty)
        #expect(r.hasPendingTitle)
        // It says how long until the window ends, counted from the last write.
        #expect(abs((r.pendingTitleDelay(at: at(0.3)) ?? 9) - 0.2) < 0.001)
        // Once the window has passed the next title writes the latest one, and nothing is pending.
        #expect(r.record(.title("E"), at: at(0.6)) == [.navigation(url: "https://example.org", title: "E", faviconURL: nil)])
        #expect(!r.hasPendingTitle)
        #expect(r.pendingTitleDelay(at: at(0.6)) == nil)
        // A repeat of what was written writes nothing.
        #expect(r.record(.title("E"), at: at(5)).isEmpty)
    }

    /// At most one write per 500 ms: three titles spread over a second write twice, never three times.
    @Test func titleWritesAreSpacedByTheInterval() {
        var r = make()
        var writes = 0
        for step in 0..<10 {
            writes += r.record(.title("T\(step)"), at: at(Double(step) * 0.1)).count
        }
        // The first at once (nothing written before), the next at 0.5 s, the rest wait.
        #expect(writes == 2)
        #expect(r.hasPendingTitle)
        #expect(r.flush(at: at(1.0)) == [.navigation(url: "https://example.com", title: "T9", faviconURL: nil)])
    }

    /// The deselect, close and quit paths flush: the pending title is written whatever the clock says, then the pending state.
    @Test func flushWritesAPendingTitle() {
        var r = make()
        _ = r.record(.committed(url: "https://example.org"), at: at(0))
        _ = r.record(.title("B"), at: at(0.1))
        _ = r.record(.stateChanged, at: at(0.1))
        _ = r.record(.stateChanged, at: at(0.2))
        #expect(r.flush(at: at(0.3)) == [.navigation(url: "https://example.org", title: "B", faviconURL: nil), .interactionState])
        #expect(r.flush(at: at(0.4)).isEmpty)
    }

    /// Only a title-only change waits: a new address, a favicon or a commit writes at once, carrying the latest title.
    @Test func addressAndFaviconChangesAreNotCoalesced() {
        var r = make()
        _ = r.record(.committed(url: "https://example.org"), at: at(0))
        #expect(r.record(.title("B"), at: at(0.1)).isEmpty)
        #expect(r.record(.favicon("https://example.org/f.ico"), at: at(0.2)) == [.navigation(url: "https://example.org", title: "B", faviconURL: "https://example.org/f.ico")])
        #expect(r.record(.title("C"), at: at(0.3)).isEmpty)
        #expect(r.record(.sameDocument(url: "https://example.org/#x"), at: at(0.4)) == [.navigation(url: "https://example.org/#x", title: "C", faviconURL: "https://example.org/f.ico")])
        #expect(!r.hasPendingTitle)
    }

    /// A pending title that returns to what was written is never written (a reload blanks the title and the page heals it).
    @Test func aTitleThatComesBackWritesNothing() {
        var r = make()
        _ = r.record(.committed(url: "https://example.org"), at: at(0))
        _ = r.record(.title("B"), at: at(1))
        #expect(r.record(.committed(url: "https://example.org"), at: at(1.1)).isEmpty)
        #expect(r.record(.title("B"), at: at(1.2)).isEmpty)
        #expect(r.flush(at: at(1.3)).isEmpty)
    }

    @Test func aClosedRecorderOwesNoTitle() {
        var r = make()
        _ = r.record(.committed(url: "https://example.org"), at: at(0))
        _ = r.record(.title("B"), at: at(0.1))
        r.close()
        #expect(!r.hasPendingTitle)
        #expect(r.flush(at: at(1)).isEmpty)
    }
}
