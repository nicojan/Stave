import Foundation
import Testing
@testable import StaveCore

@MainActor
struct LivePageRegistryTests {
    private let a = UUID()
    private let b = UUID()
    private let tabT = UUID()
    private let tabU = UUID()

    @Test func firstWindowGetsThePage() {
        let registry = LivePageRegistry()
        #expect(registry.show(tabT, in: a) == .here)
        #expect(registry.show(tabT, in: b) == .elsewhere(windowID: a))
        #expect(registry.placement(of: tabT, in: a) == .here)
        #expect(registry.placement(of: tabT, in: b) == .elsewhere(windowID: a))
    }

    @Test func unownedTabIsHere() {
        let registry = LivePageRegistry()
        #expect(registry.placement(of: tabT, in: a) == .here)
    }

    @Test func bringHereMovesIt() {
        let registry = LivePageRegistry()
        _ = registry.show(tabT, in: a)
        _ = registry.show(tabT, in: b)
        registry.bringHere(tabT, to: b)
        #expect(registry.placement(of: tabT, in: b) == .here)
        #expect(registry.placement(of: tabT, in: a) == .elsewhere(windowID: b))
    }

    @Test func bringHereReleasesTheTargetsPreviousTab() {
        let registry = LivePageRegistry()
        _ = registry.show(tabU, in: b)
        _ = registry.show(tabT, in: a)
        registry.bringHere(tabT, to: b)
        // B now shows T only; U is free, and A no longer owns anything.
        #expect(registry.show(tabU, in: a) == .here)
        #expect(registry.placement(of: tabT, in: a) == .elsewhere(windowID: b))
    }

    @Test func leavingAPageFreesIt() {
        let registry = LivePageRegistry()
        _ = registry.show(tabT, in: a)
        #expect(registry.show(tabT, in: b) == .elsewhere(windowID: a))
        #expect(registry.show(tabU, in: a) == .here)
        #expect(registry.placement(of: tabT, in: b) == .here)
        #expect(registry.show(tabT, in: b) == .here)
        #expect(registry.placement(of: tabT, in: a) == .elsewhere(windowID: b))
    }

    @Test func showingAnotherTabNeverStealsOne() {
        let registry = LivePageRegistry()
        _ = registry.show(tabT, in: a)
        _ = registry.show(tabT, in: b)
        #expect(registry.placement(of: tabT, in: a) == .here)
    }

    @Test func closingWindowReleases() {
        let registry = LivePageRegistry()
        _ = registry.show(tabT, in: a)
        registry.windowClosed(a)
        #expect(registry.show(tabT, in: b) == .here)
    }

    @Test func removedTabReleases() {
        let registry = LivePageRegistry()
        _ = registry.show(tabT, in: a)
        registry.tabRemoved(tabT)
        #expect(registry.placement(of: tabT, in: b) == .here)
        #expect(registry.show(tabU, in: a) == .here)
        #expect(registry.show(tabT, in: b) == .here)
    }
}
