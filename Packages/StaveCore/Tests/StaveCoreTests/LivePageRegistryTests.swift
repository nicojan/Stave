import Foundation
import os
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

    @Test func waiterReceivesThePageWhenTheOwnerSwitchesAway() {
        let registry = LivePageRegistry()
        _ = registry.show(tabT, in: a)
        _ = registry.show(tabT, in: b)
        _ = registry.show(tabU, in: a)
        #expect(registry.placement(of: tabT, in: b) == .here)
        #expect(registry.placement(of: tabT, in: a) == .elsewhere(windowID: b))
    }

    @Test func earliestWaiterWins() {
        let registry = LivePageRegistry()
        let c = UUID()
        _ = registry.show(tabT, in: a)
        _ = registry.show(tabT, in: b)
        _ = registry.show(tabT, in: c)
        registry.release(windowID: a)
        #expect(registry.placement(of: tabT, in: b) == .here)
        #expect(registry.placement(of: tabT, in: c) == .elsewhere(windowID: b))
    }

    @Test func waiterReceivesThePageWhenTheOwnerWindowCloses() {
        let registry = LivePageRegistry()
        _ = registry.show(tabT, in: a)
        _ = registry.show(tabT, in: b)
        registry.windowClosed(a)
        #expect(registry.placement(of: tabT, in: b) == .here)
        #expect(registry.show(tabT, in: a) == .elsewhere(windowID: b))
    }

    @Test func bringHereLeavesTheDisplacedWindowWaiting() {
        let registry = LivePageRegistry()
        _ = registry.show(tabT, in: a)
        _ = registry.show(tabT, in: b)
        registry.bringHere(tabT, to: b)
        #expect(registry.placement(of: tabT, in: b) == .here)
        #expect(registry.placement(of: tabT, in: a) == .elsewhere(windowID: b))
        registry.release(windowID: b)
        #expect(registry.placement(of: tabT, in: a) == .here)
    }

    // MARK: Edge cases (carried from plan 4)

    @Test func switchingAwayAndBackGoesToTheBackOfTheLine() {
        let registry = LivePageRegistry()
        let c = UUID()
        _ = registry.show(tabT, in: a)
        _ = registry.show(tabT, in: b)
        _ = registry.show(tabT, in: c)
        _ = registry.show(tabU, in: b)
        _ = registry.show(tabT, in: b)
        registry.release(windowID: a)
        #expect(registry.placement(of: tabT, in: c) == .here)
        #expect(registry.placement(of: tabT, in: b) == .elsewhere(windowID: c))
    }

    @Test func releasingWithNobodyWaitingLeavesThePageUnowned() {
        let registry = LivePageRegistry()
        _ = registry.show(tabT, in: a)
        registry.release(windowID: a)
        #expect(registry.placement(of: tabT, in: a) == .here)
        #expect(registry.placement(of: tabT, in: b) == .here)
        #expect(registry.show(tabT, in: b) == .here)
        #expect(registry.placement(of: tabT, in: a) == .elsewhere(windowID: b))
    }

    @Test func releasingOrClosingAWindowThatWantsNothingChangesNothing() {
        let registry = LivePageRegistry()
        let stranger = UUID()
        _ = registry.show(tabT, in: a)
        _ = registry.show(tabT, in: b)
        registry.release(windowID: stranger)
        registry.windowClosed(stranger)
        registry.release(windowID: stranger)
        #expect(registry.placement(of: tabT, in: a) == .here)
        #expect(registry.placement(of: tabT, in: b) == .elsewhere(windowID: a))
        registry.release(windowID: a)
        registry.release(windowID: a)
        #expect(registry.placement(of: tabT, in: b) == .here)
    }

    @Test func bringHereToTheOwnerChangesNothing() {
        let registry = LivePageRegistry()
        let c = UUID()
        _ = registry.show(tabT, in: a)
        _ = registry.show(tabT, in: b)
        _ = registry.show(tabT, in: c)
        registry.bringHere(tabT, to: a)
        #expect(registry.placement(of: tabT, in: a) == .here)
        registry.release(windowID: a)
        #expect(registry.placement(of: tabT, in: b) == .here)
        #expect(registry.placement(of: tabT, in: c) == .elsewhere(windowID: b))
    }

    @Test func aWaiterThatBringsThePageKeepsItsPlaceSoTheDisplacedOwnerIsNext() {
        let registry = LivePageRegistry()
        let c = UUID()
        _ = registry.show(tabT, in: a)
        _ = registry.show(tabT, in: b)
        _ = registry.show(tabT, in: c)
        registry.bringHere(tabT, to: c)
        #expect(registry.placement(of: tabT, in: a) == .elsewhere(windowID: c))
        #expect(registry.placement(of: tabT, in: b) == .elsewhere(windowID: c))
        registry.windowClosed(c)
        #expect(registry.placement(of: tabT, in: a) == .here)
        #expect(registry.placement(of: tabT, in: b) == .elsewhere(windowID: a))
    }

    @Test func removingAWaitedForTabDropsEveryWant() {
        let registry = LivePageRegistry()
        let c = UUID()
        _ = registry.show(tabT, in: a)
        _ = registry.show(tabT, in: b)
        _ = registry.show(tabU, in: c)
        registry.tabRemoved(tabT)
        // B no longer waits for T, so A and B are free; C keeps U.
        registry.release(windowID: a)
        #expect(registry.placement(of: tabT, in: b) == .here)
        #expect(registry.placement(of: tabU, in: c) == .here)
        #expect(registry.show(tabU, in: b) == .elsewhere(windowID: c))
        // A tab with the same ID shown again starts fresh.
        #expect(registry.show(tabT, in: a) == .here)
    }

    @Test func removingAnUnknownTabChangesNothing() {
        let registry = LivePageRegistry()
        _ = registry.show(tabT, in: a)
        _ = registry.show(tabT, in: b)
        registry.tabRemoved(tabU)
        #expect(registry.placement(of: tabT, in: b) == .elsewhere(windowID: a))
        registry.release(windowID: a)
        #expect(registry.placement(of: tabT, in: b) == .here)
    }

    @Test func oneWindowShowsOneTabAtATime() {
        let registry = LivePageRegistry()
        _ = registry.show(tabT, in: a)
        _ = registry.show(tabU, in: a)
        // A let go of T when it moved to U, so B can take T while A keeps U.
        #expect(registry.show(tabT, in: b) == .here)
        #expect(registry.placement(of: tabU, in: a) == .here)
        #expect(registry.show(tabU, in: b) == .elsewhere(windowID: a))
        #expect(registry.placement(of: tabT, in: a) == .here)
    }

    @Test func ownershipChangesNotifyObservers() {
        let registry = LivePageRegistry()
        _ = registry.show(tabT, in: a)
        _ = registry.show(tabT, in: b)
        let changed = OSAllocatedUnfairLock(initialState: false)
        withObservationTracking {
            _ = registry.placement(of: tabT, in: b)
        } onChange: {
            changed.withLock { $0 = true }
        }
        registry.release(windowID: a)
        #expect(changed.withLock { $0 })
        #expect(registry.placement(of: tabT, in: b) == .here)
    }

    // MARK: - Edge cases

    @Test func bringHereUnwantedTab() {
        let registry = LivePageRegistry()
        registry.bringHere(tabT, to: a)
        #expect(registry.owner(of: tabT) == a)
        #expect(registry.show(tabT, in: b) == .elsewhere(windowID: a))
    }

    @Test func tabRemovedWithWaiters() {
        let registry = LivePageRegistry()
        _ = registry.show(tabT, in: a)
        _ = registry.show(tabT, in: b)
        registry.tabRemoved(tabT)
        #expect(registry.owner(of: tabT) == nil)
        // Neither window wants T now: releasing hands nothing on, and a later show makes the shower the owner.
        registry.release(windowID: a)
        registry.release(windowID: b)
        #expect(registry.owner(of: tabT) == nil)
        #expect(registry.show(tabT, in: b) == .here)
        #expect(registry.owner(of: tabT) == b)
    }

    @Test func closedWaiterLosesItsPlace() {
        let registry = LivePageRegistry()
        let c = UUID()
        _ = registry.show(tabT, in: a)
        _ = registry.show(tabT, in: b)
        _ = registry.show(tabT, in: c)
        registry.windowClosed(b)
        registry.release(windowID: a)
        #expect(registry.owner(of: tabT) == c)
    }

    @Test func showSameTabTwiceKeepsPlace() {
        let registry = LivePageRegistry()
        let c = UUID()
        _ = registry.show(tabT, in: a)
        _ = registry.show(tabT, in: b)
        _ = registry.show(tabT, in: b)
        _ = registry.show(tabT, in: c)
        registry.release(windowID: a)
        #expect(registry.owner(of: tabT) == b)
    }
}
