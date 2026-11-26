import Foundation

/// JavaScript dialogs between a page and the queues: runs each page's `PageDialogGate` (a page that loops `alert()` is stopped) and maps
/// the sheet's reply to what the page's call returns. The app's `PageQuestionCenter` supplies the page's identity, commit count and
/// stale check (they need WebKit); every rule here is testable without it.
///
/// Each gate belongs to one page (held weakly): a page that was unloaded or remade gets a fresh gate, so a stopped gate never matches the
/// new page. Gates are dropped with the tab's questions (`cancel`), which a new document, closing and unloading all do.
@MainActor
public final class PageDialogCoordinator {
    private struct GateEntry {
        weak var page: AnyObject?
        var gate: PageDialogGate
    }

    private let queues: PageQuestionQueues
    private let now: () -> Date
    private var gates: [UUID: GateEntry] = [:]
    private var drafts: [UUID: (request: DialogRequest, text: String)] = [:]

    public init(queues: PageQuestionQueues, now: @escaping () -> Date = Date.init) {
        self.queues = queues
        self.now = now
    }

    public func alert(tabID: UUID, page: AnyObject, navigation: Int, origin: String?, message: String, isStale: @escaping () -> Bool) async {
        _ = await ask(tabID: tabID, page: page, navigation: navigation, origin: origin, kind: .alert, message: message, isStale: isStale)
    }

    /// False when the user cancels or the question is dropped.
    public func confirm(tabID: UUID, page: AnyObject, navigation: Int, origin: String?, message: String, isStale: @escaping () -> Bool) async -> Bool {
        await ask(tabID: tabID, page: page, navigation: navigation, origin: origin, kind: .confirm, message: message, isStale: isStale)?.accepted ?? false
    }

    /// Nil when the user cancels or the question is dropped; the text (empty when none) when accepted.
    public func prompt(tabID: UUID, page: AnyObject, navigation: Int, origin: String?, message: String, defaultText: String?, isStale: @escaping () -> Bool) async -> String? {
        guard let reply = await ask(tabID: tabID, page: page, navigation: navigation, origin: origin, kind: .prompt(defaultText: defaultText), message: message, isStale: isStale),
              reply.accepted else { return nil }
        return reply.text ?? ""
    }

    /// What was typed in a hidden tab's prompt, for the question it was typed for only: a later prompt (maybe from another site) never
    /// starts with it.
    public func draft(for tabID: UUID, request: DialogRequest) -> String? {
        guard let draft = drafts[tabID], draft.request == request else { return nil }
        return draft.text
    }

    /// Keeps `text` for the question (its sheet was sent back), or with nil drops the tab's draft (any other ending).
    public func keepDraft(_ text: String?, for tabID: UUID, request: DialogRequest) {
        drafts[tabID] = text.map { (request, $0) }
    }

    /// The tab's gate and draft are dropped and its questions, every kind, are cancelled.
    public func cancel(tabID: UUID) {
        gates[tabID] = nil
        drafts[tabID] = nil
        queues.cancel(tabID: tabID)
    }

    /// Only the tab's dialogs are cancelled (their page answers with its safe values): the window that held the tab closed and no other shows it.
    /// Its prompt draft goes with them, as the prompt it belonged to is answered.
    public func cancelDialogs(tabID: UUID) {
        drafts[tabID] = nil
        queues.cancelDialogs(tabID: tabID)
    }

    /// Nil when the page's dialogs were stopped, the page is gone or navigated first, or the window closed.
    private func ask(tabID: UUID, page: AnyObject, navigation: Int, origin: String?, kind: DialogRequest.Kind, message: String, isStale: @escaping () -> Bool) async -> DialogReply? {
        var entry = gates[tabID].flatMap { $0.page === page ? $0 : nil } ?? GateEntry(page: page, gate: PageDialogGate())
        let verdict = entry.gate.next(at: now(), navigation: navigation)
        gates[tabID] = entry
        guard case .ask(let offerToStop) = verdict else { return nil }
        let reply = await queues.askDialog(tabID: tabID, request: DialogRequest(kind: kind, origin: origin, message: message, offerToStop: offerToStop), isStale: isStale)
        // Only the page that asked is stopped; a page remade while the sheet was up keeps its own fresh gate.
        if reply?.stopDialogs == true, var current = gates[tabID], current.page === page {
            current.gate.stop(navigation: navigation)
            gates[tabID] = current
        }
        return reply
    }
}
