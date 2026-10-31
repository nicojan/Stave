import Foundation

/// The windows of the running app, in the order they first appeared, ready to hand to `saveWindows`.
/// `save()` and `update` never depend on close order: the app saves before quit and does not report closes while quitting.
@MainActor
public final class WindowSession {
    private let store: OrganizationStore
    public private(set) var states: [WindowState] = []

    public init(store: OrganizationStore) { self.store = store }

    /// Replaces the window's state in place, or appends it when the window is new.
    public func update(_ state: WindowState) {
        if let index = states.firstIndex(where: { $0.id == state.id }) {
            states = states.enumerated().map { $0.offset == index ? state : $0.element }
        } else {
            states = states + [state]
        }
    }

    /// A window that is not the last leaves the saved set; the last one stays, so the next launch restores it.
    public func windowClosed(_ id: UUID, isLast: Bool) {
        guard !isLast else { return }
        states = states.filter { $0.id != id }
    }

    /// Writes every state with `sortIndex` 0, 1, 2… in the current order.
    public func save() throws {
        let numbered = states.enumerated().map { offset, state -> WindowState in
            var copy = state
            copy.sortIndex = Double(offset)
            return copy
        }
        try store.saveWindows(numbered)
    }
}
