import AppKit
import StaveCore
import StaveWeb

/// The user's answer to the camera and microphone question.
struct MediaAnswer: Sendable {
    let allow: Bool
    let remember: Bool
}

/// The app's one queue of camera and microphone questions. A question that can't be shown yet (its tab isn't shown anywhere, or the window
/// showing it has a sheet up) waits here, not in any one window, so it is shown by whichever window or pop-up shows its tab when it can: a tab
/// shown in another window than the one that was frontmost when the question came, or taken over by "bring here", is not stranded.
///
/// Every question resolves exactly once (`WaitingQuestions`): answered, or denied with nothing remembered when it is stale (its page was
/// unloaded, navigated or remade), cancelled (`cancel`), or its sheet is ended. Every window drains the queue when its tab selection or its
/// sheets change (`PagePrompts.mayAskAgain`).
@MainActor
final class MediaQuestionCenter {
    private struct WeakPrompts { weak var prompts: PagePrompts? }

    private let queue = WaitingQuestions<MediaAnswer>()
    private var windows: [WeakPrompts] = []

    func register(_ prompts: PagePrompts) {
        windows = windows.filter { $0.prompts != nil } + [WeakPrompts(prompts: prompts)]
    }

    func unregister(_ prompts: PagePrompts) {
        windows = windows.filter { $0.prompts != nil && $0.prompts !== prompts }
    }

    /// Asks about the tab's page as it is now: the question is dropped, and denied, if that page is unloaded, remade or navigated before it
    /// is shown or answered.
    func ask(pageHost: PageHost, tabID: UUID, host: String, camera: Bool, microphone: Bool) async -> (allow: Bool, remember: Bool) {
        guard let page = pageHost.existingPage(tabID) else { return (false, false) }
        let asked = page.commitCount
        let isStale = { [weak page, weak pageHost] () -> Bool in
            guard let page, let pageHost else { return true }
            return pageHost.existingPage(tabID) !== page || page.isClosed || page.commitCount != asked
        }
        let answer = await queue.ask(tabID: tabID, isStale: isStale) { [weak self] finish in
            guard let self, let prompts = windows.compactMap(\.prompts).first(where: { $0.canAsk(tabID) }) else { return false }
            return prompts.showMedia(tabID: tabID, host: host, camera: camera, microphone: microphone, finish: finish)
        }
        return (answer?.allow ?? false, answer?.remember ?? false)
    }

    /// Shows each waiting question that can be shown now. Hops a turn, so a sheet that is still coming down is gone when the check runs.
    func drain() {
        Task { @MainActor [weak self] in self?.queue.drain() }
    }

    /// The tab's waiting questions are denied, and its media and download sheets come down (they resolve as cancelled, or unasked). The
    /// page committed a new document, closed or unloaded: a sheet left up would hold up the new page's questions. Other sheets (JavaScript
    /// dialogs, the file picker, the external-app question) are left alone.
    func cancel(tabID: UUID) {
        for prompts in windows.compactMap(\.prompts) { prompts.end { $0.tabID == tabID && ($0.isMedia || $0.isDownload) } }
        queue.cancel(tabID: tabID)
    }
}
