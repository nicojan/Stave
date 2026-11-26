import AppKit
import StaveCore
import StaveWeb

/// The app's door to the queues of page questions (`PageQuestionQueues` in StaveCore: camera and microphone, HTTP sign-in, "wants to
/// download several files", JavaScript dialogs and "Open this link in ‹App›?"). This type knows how to tell that a question's page has gone
/// stale, which needs `PageHost`, and hands dialogs to `PageDialogCoordinator`; everything else is the queues'. Windows register through `PageQuestionWindow` (`PagePrompts` implements it, and keeps the AppKit sheets).
@MainActor
final class PageQuestionCenter {
    private let queues = PageQuestionQueues()
    /// Runs each page's dialog gate (a page that loops `alert()`) and maps replies; its rules live in StaveCore.
    private lazy var dialogs = PageDialogCoordinator(queues: queues)

    func draft(for tabID: UUID, request: DialogRequest) -> String? { dialogs.draft(for: tabID, request: request) }
    func keepDraft(_ text: String?, for tabID: UUID, request: DialogRequest) { dialogs.keepDraft(text, for: tabID, request: request) }

    func register(_ prompts: PagePrompts) { queues.register(prompts) }
    func unregister(_ prompts: PagePrompts) { queues.unregister(prompts) }

    /// Asks about the tab's page as it is now: the question is dropped, and denied, if that page is unloaded, remade or navigated before it
    /// is shown or answered.
    func ask(pageHost: PageHost, tabID: UUID, host: String, camera: Bool, microphone: Bool) async -> (allow: Bool, remember: Bool) {
        guard let isStale = staleCheck(pageHost: pageHost, tabID: tabID) else { return (false, false) }
        let answer = await queues.askMedia(tabID: tabID, host: host, camera: camera, microphone: microphone, isStale: isStale)
        return (answer?.allow ?? false, answer?.remember ?? false)
    }

    /// Asks for HTTP credentials for the tab's page as it is now: nil (dropped by the system) if that page is unloaded, remade or navigated
    /// before the sheet is shown or answered; `.cancelled` is the user's Cancel. Waits behind any sheet up on the window, the camera's included.
    func askAuth(pageHost: PageHost, tabID: UUID, challenge: AuthChallenge) async -> AuthReply? {
        guard let isStale = staleCheck(pageHost: pageHost, tabID: tabID) else { return nil }
        return await queues.askAuth(tabID: tabID, challenge: challenge, isStale: isStale)
    }

    /// Asks about several downloads for the tab's page as it is now. Held, not refused, while it can't be shown (decision 29); nil when the
    /// page is gone, remade or navigated first, or the tab has no page: the download is then refused and nothing is recorded.
    func askSeveralDownloads(pageHost: PageHost, tabID: UUID, host: String?) async -> DownloadChoice? {
        guard let isStale = staleCheck(pageHost: pageHost, tabID: tabID) else { return nil }
        return await queues.askSeveralDownloads(tabID: tabID, host: host, isStale: isStale)
    }

    /// "Open this link in ‹App›?" for the tab's page as it is now (decision 22). True is Open; false is the user's Cancel or a question the
    /// system dropped (`unasked`: the page navigated, went away, or moved to another window).
    func askExternalApp(pageHost: PageHost, tabID: UUID, host: String?, url: URL, appName: String) async -> QuestionAnswer {
        guard let isStale = staleCheck(pageHost: pageHost, tabID: tabID) else { return .unasked }
        return QuestionAnswer(externalAppReply: await queues.askExternalApp(tabID: tabID, host: host, url: url, appName: appName, isStale: isStale))
    }

    /// The page moved to another window ("Bring It Here"): only its external-app question is dropped.
    func cancelExternalApp(tabID: UUID) { queues.cancelExternalApp(tabID: tabID) }

    // MARK: JavaScript dialogs (decision 21)

    func alert(pageHost: PageHost, tabID: UUID, origin: String?, message: String) async {
        guard let page = pageHost.existingPage(tabID), let isStale = staleCheck(pageHost: pageHost, tabID: tabID) else { return }
        await dialogs.alert(tabID: tabID, page: page, navigation: page.commitCount, origin: origin, message: message, isStale: isStale)
    }

    func confirm(pageHost: PageHost, tabID: UUID, origin: String?, message: String) async -> Bool {
        guard let page = pageHost.existingPage(tabID), let isStale = staleCheck(pageHost: pageHost, tabID: tabID) else { return false }
        return await dialogs.confirm(tabID: tabID, page: page, navigation: page.commitCount, origin: origin, message: message, isStale: isStale)
    }

    func prompt(pageHost: PageHost, tabID: UUID, origin: String?, message: String, defaultText: String?) async -> String? {
        guard let page = pageHost.existingPage(tabID), let isStale = staleCheck(pageHost: pageHost, tabID: tabID) else { return nil }
        return await dialogs.prompt(tabID: tabID, page: page, navigation: page.commitCount, origin: origin, message: message, defaultText: defaultText, isStale: isStale)
    }

    /// Held JavaScript dialogs of a tab no window shows any more are answered with their safe values (its window closed).
    func cancelDialogs(tabID: UUID) { dialogs.cancelDialogs(tabID: tabID) }

    func drain() { queues.drain() }

    /// A held or shown "wants to download several files" question: idle archiving leaves that tab alone.
    func hasSeveralDownloadsQuestion(tabID: UUID) -> Bool { queues.hasSeveralDownloadsQuestion(tabID: tabID) }
    func cancel(tabID: UUID) { dialogs.cancel(tabID: tabID) }
    func cancelAuth(tabID: UUID, site: String) { queues.cancelAuth(tabID: tabID, site: site) }

    /// Nil when the tab has no page now; else a check that is true once that page is gone, remade or has committed another document.
    private func staleCheck(pageHost: PageHost, tabID: UUID) -> (() -> Bool)? {
        guard let page = pageHost.existingPage(tabID) else { return nil }
        let asked = page.commitCount
        return { [weak page, weak pageHost] in
            guard let page, let pageHost else { return true }
            return pageHost.existingPage(tabID) !== page || page.isClosed || page.commitCount != asked
        }
    }
}
