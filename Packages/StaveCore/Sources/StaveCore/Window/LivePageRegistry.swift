import Foundation
import Observation

/// Where a tab's live page is shown, from one window's point of view.
public enum LivePlacement: Equatable, Sendable { case here, elsewhere(windowID: UUID) }

/// Tracks which window shows each tab's live page, so a tab is live in at most one window.
/// Each window shows at most one tab. Focus never moves a page; only `bringHere` does.
@MainActor @Observable
public final class LivePageRegistry {
    /// Window ID to the tab it shows. Rebuilt on every change, never edited in place.
    private var shownTab: [UUID: UUID] = [:]

    public init() {}

    /// Releases the window's previous tab, then claims `tabID` if no other window owns it.
    @discardableResult
    public func show(_ tabID: UUID, in windowID: UUID) -> LivePlacement {
        var next = shownTab.filter { $0.key != windowID }
        if let owner = owner(of: tabID, in: next) {
            shownTab = next
            return .elsewhere(windowID: owner)
        }
        next = next.merging([windowID: tabID]) { _, new in new }
        shownTab = next
        return .here
    }

    /// Transfers ownership of `tabID` to `windowID`, releasing that window's previous tab.
    public func bringHere(_ tabID: UUID, to windowID: UUID) {
        let kept = shownTab.filter { $0.key != windowID && $0.value != tabID }
        shownTab = kept.merging([windowID: tabID]) { _, new in new }
    }

    public func windowClosed(_ windowID: UUID) {
        shownTab = shownTab.filter { $0.key != windowID }
    }

    public func tabRemoved(_ tabID: UUID) {
        shownTab = shownTab.filter { $0.value != tabID }
    }

    /// `.here` for a tab no window owns, or one this window owns; `.elsewhere` when another window owns it.
    public func placement(of tabID: UUID, in windowID: UUID) -> LivePlacement {
        guard let owner = owner(of: tabID, in: shownTab), owner != windowID else { return .here }
        return .elsewhere(windowID: owner)
    }

    private func owner(of tabID: UUID, in map: [UUID: UUID]) -> UUID? {
        map.first { $0.value == tabID }?.key
    }
}
