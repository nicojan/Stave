import Foundation
import Testing
@testable import StaveCore

struct CompactRevealTests {
    private let width = 260.0

    private func revealed(at time: TimeInterval = 0) -> CompactReveal {
        var reveal = CompactReveal()
        reveal.pointerMoved(x: 0, sidebarWidth: width, at: time)
        return reveal
    }

    @Test func startsHidden() {
        let reveal = CompactReveal()
        #expect(!reveal.isRevealed)
        #expect(reveal.hideAt == nil)
    }

    @Test func edgeReveals() {
        var reveal = CompactReveal()
        reveal.pointerMoved(x: CompactReveal.edgeWidth + 1, sidebarWidth: width, at: 0)
        #expect(!reveal.isRevealed)
        reveal.pointerMoved(x: CompactReveal.edgeWidth, sidebarWidth: width, at: 0)
        #expect(reveal.isRevealed)
    }

    @Test func insideSidebarStays() {
        var reveal = revealed()
        reveal.pointerMoved(x: width, sidebarWidth: width, at: 1)
        #expect(reveal.isRevealed)
        #expect(reveal.hideAt == nil)
    }

    @Test func hiddenSidebarIgnoresThePointerBeyondTheEdge() {
        var reveal = CompactReveal()
        reveal.pointerMoved(x: 100, sidebarWidth: width, at: 0)
        reveal.pointerMoved(x: 500, sidebarWidth: width, at: 1)
        #expect(!reveal.isRevealed)
        #expect(reveal.hideAt == nil)
    }

    @Test func leavingSchedulesHide() {
        var reveal = revealed()
        reveal.pointerMoved(x: width + 1, sidebarWidth: width, at: 2)
        #expect(reveal.isRevealed)
        #expect(reveal.hideAt == 2 + CompactReveal.hideDelay)
    }

    @Test func returningCancelsHide() {
        var reveal = revealed()
        reveal.pointerMoved(x: 400, sidebarWidth: width, at: 2)
        reveal.pointerMoved(x: 100, sidebarWidth: width, at: 2.1)
        #expect(reveal.hideAt == nil)
        reveal.tick(at: 5)
        #expect(reveal.isRevealed)
    }

    @Test func tickHidesAfterDelay() {
        var reveal = revealed()
        reveal.pointerMoved(x: 400, sidebarWidth: width, at: 0)
        reveal.tick(at: 0.39)
        #expect(reveal.isRevealed)
        reveal.tick(at: 0.4)
        #expect(!reveal.isRevealed)
        #expect(reveal.hideAt == nil)
    }

    @Test func heldNeverHides() {
        var reveal = revealed()
        reveal.setHeld(true, at: 0)
        reveal.pointerMoved(x: 400, sidebarWidth: width, at: 0)
        #expect(reveal.hideAt == nil)
        reveal.tick(at: 100)
        #expect(reveal.isRevealed)
    }

    @Test func holdingCancelsAPendingHide() {
        var reveal = revealed()
        reveal.pointerMoved(x: 400, sidebarWidth: width, at: 0)
        reveal.setHeld(true, at: 0.1)
        #expect(reveal.hideAt == nil)
        reveal.tick(at: 1)
        #expect(reveal.isRevealed)
    }

    @Test func releasingHoldOutsideSchedules() {
        var reveal = revealed()
        reveal.setHeld(true, at: 0)
        reveal.pointerMoved(x: 400, sidebarWidth: width, at: 1)
        reveal.setHeld(false, at: 3)
        #expect(reveal.hideAt == 3 + CompactReveal.hideDelay)
        reveal.tick(at: 3 + CompactReveal.hideDelay)
        #expect(!reveal.isRevealed)
    }

    @Test func releasingHoldInsideDoesNotSchedule() {
        var reveal = revealed()
        reveal.setHeld(true, at: 0)
        reveal.pointerMoved(x: 100, sidebarWidth: width, at: 1)
        reveal.setHeld(false, at: 3)
        #expect(reveal.hideAt == nil)
    }

    @Test func notRescheduledWhilePending() {
        var reveal = revealed()
        reveal.pointerMoved(x: 300, sidebarWidth: width, at: 1)
        let first = reveal.hideAt
        reveal.pointerMoved(x: 320, sidebarWidth: width, at: 1.2)
        #expect(reveal.hideAt == first)
    }

    @Test func releasingHoldWhileHiddenDoesNothing() {
        var reveal = CompactReveal()
        reveal.setHeld(true, at: 0)
        reveal.setHeld(false, at: 1)
        #expect(!reveal.isRevealed)
        #expect(reveal.hideAt == nil)
    }

    @Test func keyboardRevealShowsAndHidesOnceReleased() {
        var reveal = CompactReveal()
        reveal.revealForKeyboard()
        reveal.setHeld(true, at: 0)
        #expect(reveal.isRevealed)
        reveal.tick(at: 50)
        #expect(reveal.isRevealed)
        reveal.setHeld(false, at: 60)
        #expect(reveal.hideAt == 60 + CompactReveal.hideDelay)
    }

    @Test func leavingTheWindowCountsAsOutside() {
        var reveal = revealed()
        reveal.pointerLeft(at: 1)
        #expect(reveal.hideAt == 1 + CompactReveal.hideDelay)
    }
}

struct CompactHoldTests {
    @Test func nothingActiveIsNotHeld() {
        #expect(!CompactHold().isHeld)
    }

    @Test func eachSignalHolds() {
        #expect(CompactHold(commandBarOpen: true).isHeld)
        #expect(CompactHold(menuOpen: true).isHeld)
        #expect(CompactHold(popoverOpen: true).isHeld)
        #expect(CompactHold(sheetOpen: true).isHeld)
        #expect(CompactHold(dragInFlight: true).isHeld)
        #expect(CompactHold(keyboardFocusInside: true).isHeld)
    }
}
