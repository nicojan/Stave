import Foundation

/// The user's answer to the camera and microphone question.
public struct MediaAnswer: Sendable, Equatable {
    public let allow: Bool
    public let remember: Bool

    public init(allow: Bool, remember: Bool) {
        self.allow = allow
        self.remember = remember
    }
}

/// The user's answer to "‹host› wants to download several files".
public enum DownloadChoice: Sendable, Equatable {
    case allow, dontAllow
}

/// A JavaScript `alert`, `confirm` or `prompt` a page asks (plan 5, decision 21).
public struct DialogRequest: Sendable, Equatable {
    public enum Kind: Sendable, Equatable {
        case alert, confirm
        case prompt(defaultText: String?)
    }

    public let kind: Kind
    /// The host of the frame that asked (nil for a frame with no web origin), which the heading names.
    public let origin: String?
    public let message: String
    /// The page has asked often enough that the sheet offers "Don't show more dialogs from this page".
    public let offerToStop: Bool

    public init(kind: Kind, origin: String?, message: String, offerToStop: Bool) {
        self.kind = kind
        self.origin = origin
        self.message = message
        self.offerToStop = offerToStop
    }
}

/// How a dialog's sheet was answered: OK (`accepted`) or Cancel, the prompt's text, and whether "Don't show more dialogs" was ticked.
public struct DialogReply: Sendable, Equatable {
    public let accepted: Bool
    public let text: String?
    public let stopDialogs: Bool

    public init(accepted: Bool, text: String?, stopDialogs: Bool) {
        self.accepted = accepted
        self.text = text
        self.stopDialogs = stopDialogs
    }
}

/// The kinds of sheet a page's question can have up. Used to end a tab's sheets by kind.
public enum PageQuestionKind: Sendable, Hashable {
    case media, auth, download, dialog, externalApp
}

/// A window (or pop-up) that can show a page's waiting questions. The AppKit side implements it; the queues decide nothing about sheets.
@MainActor
public protocol PageQuestionWindow: AnyObject {
    /// Whether this window shows the tab now and has no sheet up.
    func canAsk(_ tabID: UUID) -> Bool
    /// Shows the camera and microphone sheet and returns true, or returns false. `finish` hears how it ended.
    func showMedia(tabID: UUID, host: String, camera: Bool, microphone: Bool, finish: @escaping (WaitingQuestions<MediaAnswer>.Result) -> Void) -> Bool
    /// Shows the HTTP sign-in sheet and returns true, or returns false. `finish` hears how it ended.
    func showAuth(tabID: UUID, challenge: AuthChallenge, finish: @escaping (WaitingQuestions<AuthReply>.Result) -> Void) -> Bool
    /// Shows the "wants to download several files" sheet and returns true, or returns false. `finish` hears how it ended.
    func showSeveralDownloads(tabID: UUID, host: String?, finish: @escaping (WaitingQuestions<DownloadChoice>.Result) -> Void) -> Bool
    /// Shows a JavaScript dialog's sheet and returns true, or returns false. `finish` hears how it ended.
    func showDialog(tabID: UUID, request: DialogRequest, finish: @escaping (WaitingQuestions<DialogReply>.Result) -> Void) -> Bool
    /// Shows "Open this link in ‹App›?" and returns true, or returns false. `finish` hears how it ended: answered (true is Open), sent back
    /// (its tab was hidden, so the question waits again) or cancelled.
    func showExternalApp(tabID: UUID, host: String?, url: URL, appName: String, finish: @escaping (WaitingQuestions<Bool>.Result) -> Void) -> Bool
    /// Ends the tab's sheets of these kinds; their questions resolve as cancelled by the system (not the user's Cancel).
    func endSheets(tabID: UUID, kinds: Set<PageQuestionKind>)
    /// Ends the tab's sign-in sheet about `site` only (`AuthChallenge.siteKey`); other sheets stay.
    func endAuthSheets(tabID: UUID, site: String)
}

/// Every app-wide queue of page questions, in one place: camera and microphone, HTTP sign-in, "wants to download several files",
/// JavaScript dialogs and "Open this link in ‹App›?". A question
/// that can't be shown yet (its tab isn't shown anywhere, or the window showing it has a sheet up) waits here, not in any one window, so
/// whichever window or pop-up shows its tab shows it when it can. One `drain()` and one `cancel(tabID:)` cover every queue, so a new queue
/// can't be missed by either.
///
/// Every question resolves exactly once (`WaitingQuestions`).
@MainActor
public final class PageQuestionQueues {
    private struct WeakWindow { weak var window: PageQuestionWindow? }

    private let media = WaitingQuestions<MediaAnswer>()
    private let auth = WaitingQuestions<AuthReply>()
    private let severalDownloads = WaitingQuestions<DownloadChoice>()
    private let dialogs = WaitingQuestions<DialogReply>()
    private let externalApps = WaitingQuestions<Bool>()
    private var windows: [WeakWindow] = []

    public init() {}

    public func register(_ window: PageQuestionWindow) {
        windows = windows.filter { $0.window != nil } + [WeakWindow(window: window)]
    }

    public func unregister(_ window: PageQuestionWindow) {
        windows = windows.filter { $0.window != nil && $0.window !== window }
    }

    private var live: [PageQuestionWindow] { windows.compactMap(\.window) }

    /// Camera and microphone. Nil answer: denied (cancelled or stale).
    public func askMedia(tabID: UUID, host: String, camera: Bool, microphone: Bool, isStale: @escaping () -> Bool) async -> MediaAnswer? {
        await media.ask(tabID: tabID, isStale: isStale) { [weak self] finish in
            guard let self, let window = live.first(where: { $0.canAsk(tabID) }) else { return false }
            return window.showMedia(tabID: tabID, host: host, camera: camera, microphone: microphone, finish: finish)
        }
    }

    /// HTTP sign-in. `.signedIn` or the user's `.cancelled`; nil when the system dropped the question (stale, tab gone, failed load). Waits
    /// behind any sheet up on the window, the camera's included.
    public func askAuth(tabID: UUID, challenge: AuthChallenge, isStale: @escaping () -> Bool) async -> AuthReply? {
        await auth.ask(tabID: tabID, site: challenge.siteKey, isStale: isStale) { [weak self] finish in
            guard let self, let window = live.first(where: { $0.canAsk(tabID) }) else { return false }
            return window.showAuth(tabID: tabID, challenge: challenge, finish: finish)
        }
    }

    /// "‹host› wants to download several files". Held, not refused, while it can't be shown (its tab is hidden, another sheet is up), as
    /// Chrome queues a tab's question until the tab is shown. Nil: dropped by the system (a new document committed, the page closed, the
    /// tab was forgotten, the window closed), so nothing is answered and nothing is recorded.
    public func askSeveralDownloads(tabID: UUID, host: String?, isStale: @escaping () -> Bool) async -> DownloadChoice? {
        await severalDownloads.ask(tabID: tabID, isStale: isStale) { [weak self] finish in
            guard let self, let window = live.first(where: { $0.canAsk(tabID) }) else { return false }
            return window.showSeveralDownloads(tabID: tabID, host: host, finish: finish)
        }
    }

    /// Whether the tab has a "wants to download several files" question open, held or up. Idle archiving leaves such a tab alone:
    /// archiving it would drop the question and refuse the page's downloads.
    public func hasSeveralDownloadsQuestion(tabID: UUID) -> Bool { severalDownloads.isOpen(tabID: tabID) }

    /// A JavaScript `alert`, `confirm` or `prompt`. Held, not answered at once, while its tab is hidden or another sheet is up, as Chrome and
    /// Firefox hold a tab's dialogs until it is shown (decision 21); the page's script waits meanwhile. Nil: dropped by the system (a new
    /// document committed, the page closed or unloaded, the tab was forgotten, the window closed), so `alert` returns, `confirm` is false
    /// and `prompt` is nil.
    public func askDialog(tabID: UUID, request: DialogRequest, isStale: @escaping () -> Bool) async -> DialogReply? {
        await dialogs.ask(tabID: tabID, isStale: isStale) { [weak self] finish in
            guard let self, let window = live.first(where: { $0.canAsk(tabID) }) else { return false }
            return window.showDialog(tabID: tabID, request: request, finish: finish)
        }
    }

    /// "Open this link in ‹App›?" (decision 22). It belongs to its tab: hidden with it, back when it is shown again. True is Open, false the
    /// user's Cancel; nil when the system dropped it (the page navigated or went away, or it moved to another window).
    public func askExternalApp(tabID: UUID, host: String?, url: URL, appName: String, isStale: @escaping () -> Bool) async -> Bool? {
        await externalApps.ask(tabID: tabID, isStale: isStale) { [weak self] finish in
            guard let self, let window = live.first(where: { $0.canAsk(tabID) }) else { return false }
            return window.showExternalApp(tabID: tabID, host: host, url: url, appName: appName, finish: finish)
        }
    }

    /// Shows each waiting question that can be shown now, every queue, oldest first.
    public func drainNow() {
        media.drain()
        auth.drain()
        severalDownloads.drain()
        dialogs.drain()
        externalApps.drain()
    }

    /// `drainNow`, a turn later, so a sheet that is still coming down is gone when the check runs.
    public func drain() {
        Task { @MainActor [weak self] in self?.drainNow() }
    }

    /// The tab's questions, waiting or up, in every queue, are cancelled and its sheets come down. The page
    /// committed a new document, closed or unloaded: a sheet left up would hold up the new page's questions.
    public func cancel(tabID: UUID) {
        for window in live { window.endSheets(tabID: tabID, kinds: [.media, .auth, .download, .dialog, .externalApp]) }
        media.cancel(tabID: tabID)
        auth.cancel(tabID: tabID)
        severalDownloads.cancel(tabID: tabID)
        dialogs.cancel(tabID: tabID)
        externalApps.cancel(tabID: tabID)
    }

    /// Only the tab's JavaScript dialogs are cancelled, waiting or up: nothing will show them (their window closed), so their page's calls
    /// return with their safe answers.
    public func cancelDialogs(tabID: UUID) {
        for window in live { window.endSheets(tabID: tabID, kinds: [.dialog]) }
        dialogs.cancel(tabID: tabID)
    }

    /// Only the tab's external-app question is dropped, waiting or up: its page moved to another window ("Bring It Here"), so a stale sheet
    /// can't open a link for a page the window no longer shows. Its other questions go with the page and stay.
    public func cancelExternalApp(tabID: UUID) {
        for window in live { window.endSheets(tabID: tabID, kinds: [.externalApp]) }
        externalApps.cancel(tabID: tabID)
    }

    /// Only the tab's sign-in questions about `site` are cancelled, by the system (a main-frame load to that site failed or was stopped; the
    /// page still shown, its camera question and its other sites' sign-ins stay).
    public func cancelAuth(tabID: UUID, site: String) {
        for window in live { window.endAuthSheets(tabID: tabID, site: site) }
        auth.cancel(tabID: tabID, site: site)
    }
}
