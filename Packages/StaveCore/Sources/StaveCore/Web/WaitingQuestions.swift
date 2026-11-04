import Foundation

/// Questions a page asks that can't be shown yet (its tab isn't shown, another sheet is up): they wait and are shown when they can, as Chrome
/// and Firefox do, instead of being denied at once. The window decides what "can be shown" means, in `Show`.
///
/// Every question resolves exactly once: with its answer, or with nil when it is cancelled (its sheet was ended, its tab went away, the
/// window closed). A sheet taken down because its tab was hidden reports `.sentBack`, and its question waits again.
@MainActor
public final class WaitingQuestions<Answer: Sendable> {
    public enum Result: Sendable {
        case answered(Answer)
        /// The sheet came down but the question is still open: it waits to be shown again.
        case sentBack
        /// Resolves the question with nil.
        case cancelled
    }

    /// Shows the question now and returns true, or returns false when it can't be shown. A shown question reports once through `finish`;
    /// later calls to the same `finish`, and calls after the question resolved, do nothing.
    public typealias Show = (_ finish: @escaping (Result) -> Void) -> Bool

    private final class Entry {
        let tabID: UUID
        let show: Show
        /// True once the page that asked is gone (unloaded, navigated, remade): the question is then dropped, never shown.
        let isStale: () -> Bool
        var continuation: CheckedContinuation<Answer?, Never>?
        var isShowing = false
        /// Counts shows, so a late report from an earlier sheet never answers a later one.
        var generation = 0

        init(tabID: UUID, isStale: @escaping () -> Bool, show: @escaping Show) {
            self.tabID = tabID
            self.isStale = isStale
            self.show = show
        }
    }

    /// Questions in the order they were asked, waiting or up.
    private var entries: [Entry] = []
    private var isClosed = false

    public init() {}

    /// The answer, or nil when the question is cancelled. Shown at once when it can be, else when `drain` finds that it can. `isStale` is
    /// checked on every drain and right before each show: a stale question resolves with nil and is never shown.
    public func ask(tabID: UUID, isStale: @escaping () -> Bool = { false }, show: @escaping Show) async -> Answer? {
        guard !isClosed, !isStale() else { return nil }
        return await withCheckedContinuation { continuation in
            let entry = Entry(tabID: tabID, isStale: isStale, show: show)
            entry.continuation = continuation
            entries.append(entry)
            drain()
        }
    }

    /// Shows each waiting question that can be shown now, oldest first. Called whenever something that could block them changes: a tab
    /// is shown, a sheet ends. A stale question resolves with nil here whether or not it could be shown.
    public func drain() {
        guard !isClosed else { return }
        for entry in entries where !entry.isShowing && entry.continuation != nil {
            if entry.isStale() {
                resolve(entry, nil)
                continue
            }
            entry.generation += 1
            let generation = entry.generation
            entry.isShowing = true
            let shown = entry.show { [weak self, entry] result in
                self?.finish(entry, generation: generation, result)
            }
            if !shown, entry.generation == generation { entry.isShowing = false }
        }
    }

    /// The tab's questions resolve with nil, waiting or up (an up sheet is ended by its window, and its late report is ignored).
    public func cancel(tabID: UUID) {
        for entry in entries where entry.tabID == tabID { resolve(entry, nil) }
    }

    /// Every question resolves with nil, and later ones resolve at once.
    public func close() {
        isClosed = true
        for entry in entries { resolve(entry, nil) }
    }

    private func finish(_ entry: Entry, generation: Int, _ result: Result) {
        guard entry.isShowing, entry.generation == generation else { return }
        entry.isShowing = false
        switch result {
        case .answered(let answer): resolve(entry, answer)
        case .cancelled: resolve(entry, nil)
        case .sentBack: break
        }
    }

    private func resolve(_ entry: Entry, _ answer: Answer?) {
        guard let continuation = entry.continuation else { return }
        entry.continuation = nil
        entry.isShowing = false
        entries.removeAll { $0 === entry }
        continuation.resume(returning: answer)
    }
}
