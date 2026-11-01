import Foundation
import Testing
@testable import StaveCore

@Suite struct HibernationPolicyTests {
    private let now = Date(timeIntervalSince1970: 2_000_000)
    private func page(minutesAgo: Double, shown: Bool = false, busy: Bool = false) -> LivePageInfo {
        LivePageInfo(id: UUID(), isShown: shown, lastShownAt: now.addingTimeInterval(-minutesAgo * 60), isBusyWithMedia: busy)
    }

    @Test func hibernationSkipsShownAndBusy() {
        let shown = page(minutesAgo: 40, shown: true)
        let busy = page(minutesAgo: 40, busy: true)
        let old = page(minutesAgo: 31)
        let recent = page(minutesAgo: 10)
        #expect(HibernationPolicy.pagesToUnload([shown, busy, old, recent], now: now) == [old.id])
    }

    @Test func idleBoundaryIsInclusive() {
        let exact = page(minutesAgo: 30)
        #expect(HibernationPolicy.pagesToUnload([exact], now: now) == [exact.id])
    }

    @Test func hibernationCapsLivePages() {
        let pages = (1...30).map { page(minutesAgo: Double($0) * 0.5) }
        let expected = pages.sorted { $0.lastShownAt < $1.lastShownAt }.prefix(6).map(\.id)
        #expect(HibernationPolicy.pagesToUnload(pages, now: now) == Array(expected))
    }

    @Test func shownAndBusyCountTowardCapButAreNeverRemoved() {
        let shown = (0..<20).map { _ in page(minutesAgo: 1, shown: true) }
        let busy = (0..<6).map { _ in page(minutesAgo: 2, busy: true) }
        let idle = (1...3).map { page(minutesAgo: Double($0)) }
        let result = HibernationPolicy.pagesToUnload(shown + busy + idle, now: now)
        // 29 live, cap 24: 5 over, only 3 eligible.
        #expect(result == idle.sorted { $0.lastShownAt < $1.lastShownAt }.map(\.id))
    }

    @Test func idleAndOverflowAreUniqueAndOldestFirst() {
        let idle = (0..<2).map { page(minutesAgo: 40 + Double($0)) }
        let fresh = (0..<24).map { page(minutesAgo: 1 + Double($0) * 0.1) }
        let result = HibernationPolicy.pagesToUnload(fresh + idle, now: now)
        #expect(result == idle.sorted { $0.lastShownAt < $1.lastShownAt }.map(\.id))
        #expect(Set(result).count == result.count)
    }
}
