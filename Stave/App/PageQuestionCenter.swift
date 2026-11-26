import AppKit
import StaveCore
import StaveWeb

/// The app's door to the queues of page questions (`PageQuestionQueues` in StaveCore: camera and microphone, HTTP sign-in; Task 14 adds
/// its own there). This type only knows how to tell that a question's page has gone stale, which needs `PageHost`; everything else is the
/// queues'. Windows register through `PageQuestionWindow` (`PagePrompts` implements it, and keeps the AppKit sheets).
@MainActor
final class PageQuestionCenter {
    private let queues = PageQuestionQueues()

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

    func drain() { queues.drain() }
    func cancel(tabID: UUID) { queues.cancel(tabID: tabID) }
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
