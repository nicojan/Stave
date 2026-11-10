import AppKit
import SwiftUI
import StaveCore

/// Turns two-finger horizontal swipes over its area into workspace steps. It sits behind the sidebar and watches scroll events with a local
/// monitor, so it never takes a click or a scroll from the list: every event is handed on untouched, and vertical scrolling works as usual.
/// The rule (60 pt, once per gesture, horizontal only) is `WorkspaceSwipeTracker`; this only reads the trackpad.
struct SwipeCatcher: NSViewRepresentable {
    /// +1 for the next workspace, -1 for the previous.
    let onStep: (Int) -> Void

    func makeNSView(context: Context) -> CatcherView {
        let view = CatcherView()
        view.onStep = onStep
        return view
    }

    func updateNSView(_ view: CatcherView, context: Context) { view.onStep = onStep }

    static func dismantleNSView(_ view: CatcherView, coordinator: ()) { view.stop() }

    @MainActor
    final class CatcherView: NSView {
        var onStep: (Int) -> Void = { _ in }
        private var tracker = WorkspaceSwipeTracker()
        private var monitor: Any?

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            removeMonitor()
            guard window != nil else { return }
            monitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { [weak self] event in
                MainActor.assumeIsolated { self?.handle(event) }
                return event // never swallowed: the list keeps its vertical scrolling
            }
        }

        override func hitTest(_ point: NSPoint) -> NSView? { nil }

        func stop() { removeMonitor() }

        private func removeMonitor() {
            if let monitor { NSEvent.removeMonitor(monitor) }
            monitor = nil
        }

        private func handle(_ event: NSEvent) {
            guard let window, event.window === window, event.hasPreciseScrollingDeltas else { return }
            // Momentum events have an empty `phase` and are ignored, so the glide after a swipe cannot switch twice.
            let phase = event.phase
            guard !phase.isEmpty, bounds.contains(convert(event.locationInWindow, from: nil)) || phase.contains(.ended) || phase.contains(.cancelled) else { return }
            if phase.contains(.began) { tracker.began() }
            if phase.contains(.began) || phase.contains(.changed) {
                // With natural scrolling the deltas already follow the fingers; without it they are the opposite.
                let sign: Double = event.isDirectionInvertedFromDevice ? 1 : -1
                if let step = tracker.changed(fingerDeltaX: sign * Double(event.scrollingDeltaX), fingerDeltaY: sign * Double(event.scrollingDeltaY)) {
                    onStep(step)
                }
            }
            if phase.contains(.ended) || phase.contains(.cancelled) { tracker.ended() }
        }
    }
}
