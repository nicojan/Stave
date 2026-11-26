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

/// The kinds of sheet a page's question can have up. Used to end a tab's sheets by kind.
public enum PageQuestionKind: Sendable, Hashable {
    case media, auth, download
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
    /// Ends the tab's sheets of these kinds; their questions resolve as cancelled by the system (not the user's Cancel).
    func endSheets(tabID: UUID, kinds: Set<PageQuestionKind>)
    /// Ends the tab's sign-in sheet about `site` only (`AuthChallenge.siteKey`); other sheets stay.
    func endAuthSheets(tabID: UUID, site: String)
}

/// Every app-wide queue of page questions, in one place: camera and microphone, and HTTP sign-in (Task 14 adds the downloads'). A question
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

    /// Shows each waiting question that can be shown now, every queue, oldest first.
    public func drainNow() {
        media.drain()
        auth.drain()
    }

    /// `drainNow`, a turn later, so a sheet that is still coming down is gone when the check runs.
    public func drain() {
        Task { @MainActor [weak self] in self?.drainNow() }
    }

    /// The tab's questions, waiting or up, in every queue, are cancelled and its media, sign-in and download sheets come down. The page
    /// committed a new document, closed or unloaded: a sheet left up would hold up the new page's questions.
    public func cancel(tabID: UUID) {
        for window in live { window.endSheets(tabID: tabID, kinds: [.media, .auth, .download]) }
        media.cancel(tabID: tabID)
        auth.cancel(tabID: tabID)
    }

    /// Only the tab's sign-in questions about `site` are cancelled, by the system (a main-frame load to that site failed or was stopped; the
    /// page still shown, its camera question and its other sites' sign-ins stay).
    public func cancelAuth(tabID: UUID, site: String) {
        for window in live { window.endAuthSheets(tabID: tabID, site: site) }
        auth.cancel(tabID: tabID, site: site)
    }
}
