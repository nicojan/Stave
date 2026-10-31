import Foundation

/// Turns the finger travel of one two-finger swipe into at most one workspace step. Pure state; `SwipeCatcher` feeds it trackpad events.
public struct WorkspaceSwipeTracker: Sendable {
    /// Horizontal finger travel, in points, that makes a swipe count.
    public static let threshold: Double = 60
    /// Horizontal travel must be at least this many times the vertical travel.
    public static let horizontalBias: Double = 1.5
    /// Travel needed before the gesture's axis is decided, so a tiny wobble at the start does not lock it vertical.
    static let lockTravel: Double = 4

    private var travelX = 0.0
    private var travelY = 0.0
    private var startedVertical = false
    private var axisDecided = false
    private var fired = false

    public init() {}

    public mutating func began() { reset() }

    public mutating func ended() { reset() }

    /// `fingerDelta*` is finger travel since the last call (positive X = rightward). Returns +1 (next workspace, fingers moving left) or
    /// -1 once per gesture when the accumulated travel passes the threshold, and nil otherwise.
    public mutating func changed(fingerDeltaX: Double, fingerDeltaY: Double) -> Int? {
        guard fingerDeltaX.isFinite, fingerDeltaY.isFinite else { return nil }
        travelX += fingerDeltaX
        travelY += fingerDeltaY
        if !axisDecided, max(abs(travelX), abs(travelY)) >= Self.lockTravel {
            axisDecided = true
            startedVertical = abs(travelY) > abs(travelX)
        }
        guard !fired, !startedVertical else { return nil }
        guard abs(travelX) >= Self.threshold, abs(travelX) >= Self.horizontalBias * abs(travelY) else { return nil }
        fired = true
        return travelX < 0 ? 1 : -1
    }

    private mutating func reset() { self = WorkspaceSwipeTracker() }
}
