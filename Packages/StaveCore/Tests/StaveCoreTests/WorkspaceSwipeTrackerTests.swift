import Testing
@testable import StaveCore

struct WorkspaceSwipeTrackerTests {
    @Test func leftwardTravelPastThresholdGivesNextOnceThenNothing() {
        var tracker = WorkspaceSwipeTracker()
        tracker.began()
        #expect(tracker.changed(fingerDeltaX: -30, fingerDeltaY: 0) == nil)
        #expect(tracker.changed(fingerDeltaX: -31, fingerDeltaY: 0) == 1)
        #expect(tracker.changed(fingerDeltaX: -50, fingerDeltaY: 0) == nil)
        #expect(tracker.changed(fingerDeltaX: -50, fingerDeltaY: 0) == nil)
    }

    @Test func rightwardTravelGivesPrevious() {
        var tracker = WorkspaceSwipeTracker()
        tracker.began()
        #expect(tracker.changed(fingerDeltaX: 61, fingerDeltaY: 0) == -1)
    }

    @Test func shortGestureThenEndedSwitchesNothingAndTheNextStartsFromZero() {
        var tracker = WorkspaceSwipeTracker()
        tracker.began()
        #expect(tracker.changed(fingerDeltaX: -59, fingerDeltaY: 0) == nil)
        tracker.ended()
        tracker.began()
        #expect(tracker.changed(fingerDeltaX: -2, fingerDeltaY: 0) == nil)
        #expect(tracker.changed(fingerDeltaX: -60, fingerDeltaY: 0) == 1)
    }

    @Test func aNewGestureCanSwitchAgainAfterOneSwitched() {
        var tracker = WorkspaceSwipeTracker()
        tracker.began()
        #expect(tracker.changed(fingerDeltaX: -70, fingerDeltaY: 0) == 1)
        tracker.ended()
        tracker.began()
        #expect(tracker.changed(fingerDeltaX: 70, fingerDeltaY: 0) == -1)
    }

    @Test func mostlyVerticalTravelNeverSwitches() {
        var tracker = WorkspaceSwipeTracker()
        tracker.began()
        #expect(tracker.changed(fingerDeltaX: 70, fingerDeltaY: 60) == nil)
    }

    @Test func aGestureThatStartedVerticalNeverSwitches() {
        var tracker = WorkspaceSwipeTracker()
        tracker.began()
        #expect(tracker.changed(fingerDeltaX: 0, fingerDeltaY: 30) == nil)
        #expect(tracker.changed(fingerDeltaX: 200, fingerDeltaY: 0) == nil)
        #expect(tracker.changed(fingerDeltaX: 200, fingerDeltaY: 0) == nil)
    }

    @Test func aTinyWobbleBeforeHorizontalTravelDoesNotLockTheGesture() {
        var tracker = WorkspaceSwipeTracker()
        tracker.began()
        #expect(tracker.changed(fingerDeltaX: 0, fingerDeltaY: 1) == nil)
        #expect(tracker.changed(fingerDeltaX: -70, fingerDeltaY: 0) == 1)
    }

    @Test func changedWithoutBeganStillTracksFromZero() {
        var tracker = WorkspaceSwipeTracker()
        #expect(tracker.changed(fingerDeltaX: -61, fingerDeltaY: 0) == 1)
    }
}
