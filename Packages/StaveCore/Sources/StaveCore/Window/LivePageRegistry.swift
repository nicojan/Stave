import Foundation
import Observation

/// Where a tab's live page is shown, from one window's point of view.
public enum LivePlacement: Equatable, Sendable { case here, elsewhere(windowID: UUID) }

/// Tracks which window shows each tab's live page, so a tab is live in at most one window.
/// Each window wants at most one tab (its selection). The first window to want an unowned tab owns it; others wait.
/// When an owner lets go (wants something else, closes, or the tab is removed), the earliest-requesting waiter gets the page.
/// Focus never moves a page; only `bringHere` does. Observable, so views see ownership changes without a store write.
@MainActor @Observable
public final class LivePageRegistry {
    /// Window to the tab it wants, tab to its owning window, and windows in the order they asked. Replaced whole, never edited in place.
    private struct State {
        var wants: [UUID: UUID] = [:]
        var owners: [UUID: UUID] = [:]
        var order: [UUID] = []

        /// Frees `tabID` and hands it to the earliest window still wanting it, if any.
        func handingOff(_ tabID: UUID) -> State {
            var next = self
            next.owners[tabID] = order.first { wants[$0] == tabID }
            return next
        }

        /// `windowID` wants `tabID` now. A tab it owned before is handed on. Keeps its place in line when the want is unchanged.
        func wanting(_ tabID: UUID, by windowID: UUID) -> State {
            guard wants[windowID] != tabID else { return self }
            var next = self.releasing(windowID)
            next.wants[windowID] = tabID
            next.order.append(windowID)
            return next
        }

        /// `windowID` wants nothing. The tab it owned goes to the next waiter.
        func releasing(_ windowID: UUID) -> State {
            guard let previous = wants[windowID] else { return self }
            var next = self
            next.wants[windowID] = nil
            next.order = order.filter { $0 != windowID }
            return next.owners[previous] == windowID ? next.handingOff(previous) : next
        }
    }

    private var state = State()

    public init() {}

    /// Records that the window wants `tabID` (dropping its previous want), and makes it owner if no window owns the tab.
    @discardableResult
    public func show(_ tabID: UUID, in windowID: UUID) -> LivePlacement {
        var next = state.wanting(tabID, by: windowID)
        if next.owners[tabID] == nil { next.owners[tabID] = windowID }
        state = next
        return placement(of: tabID, in: windowID)
    }

    /// Makes `windowID` the owner of `tabID`. The displaced window keeps wanting it, so it reads `.elsewhere`.
    public func bringHere(_ tabID: UUID, to windowID: UUID) {
        var next = state.wanting(tabID, by: windowID)
        next.owners[tabID] = windowID
        state = next
    }

    /// The window wants nothing: its page goes to the next waiter.
    public func release(windowID: UUID) {
        state = state.releasing(windowID)
    }

    public func windowClosed(_ windowID: UUID) { release(windowID: windowID) }

    public func tabRemoved(_ tabID: UUID) {
        var next = state
        next.owners[tabID] = nil
        next.wants = next.wants.filter { $0.value != tabID }
        next.order = next.order.filter { next.wants[$0] != nil }
        state = next
    }

    /// `.here` for a tab no window owns, or one this window owns; `.elsewhere` when another window owns it.
    public func placement(of tabID: UUID, in windowID: UUID) -> LivePlacement {
        guard let owner = state.owners[tabID], owner != windowID else { return .here }
        return .elsewhere(windowID: owner)
    }
}
