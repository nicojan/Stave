import Foundation

/// The windows of the running app, in the order they first appeared, ready to hand to `saveWindows`.
/// `save()` and `update` never depend on close order: the app saves before quit and does not report closes while quitting.
@MainActor
public final class WindowSession {
    private let store: OrganizationStore
    public private(set) var states: [WindowState] = []

    private var saveTask: Task<Void, Never>?
    private let saveDelay: Duration
    /// Called when a debounced save fails.
    public var onSaveError: (@MainActor (Error) -> Void)?

    public init(store: OrganizationStore, saveDelay: Duration = .milliseconds(500)) {
        self.store = store
        self.saveDelay = saveDelay
    }

    /// One save for all windows, `saveDelay` after the last call. Every call restarts the delay.
    public func scheduleSave() {
        saveTask?.cancel()
        saveTask = Task { [weak self, saveDelay] in
            try? await Task.sleep(for: saveDelay)
            guard !Task.isCancelled, let self else { return }
            do { try self.save() } catch { self.onSaveError?(error) }
        }
    }

    /// Saves now and drops any pending delayed save.
    public func saveNow() throws {
        saveTask?.cancel()
        saveTask = nil
        try save()
    }

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
