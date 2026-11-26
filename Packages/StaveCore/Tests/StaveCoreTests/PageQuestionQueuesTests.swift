import Foundation
import Testing

@testable import StaveCore

/// A window that shows one sheet at a time, as the app's does, and that the test answers by hand.
@MainActor
final class FakeQuestionWindow: PageQuestionWindow {
    var shownTabs: Set<UUID> = []
    var sheetUp = false
    private(set) var mediaShown = 0
    private(set) var authShown = 0
    private(set) var ended: [(UUID, Set<PageQuestionKind>)] = []
    private(set) var endedAuthSites: [String] = []
    private var authSite: String?
    var mediaFinish: ((WaitingQuestions<MediaAnswer>.Result) -> Void)?
    var authFinish: ((WaitingQuestions<AuthReply>.Result) -> Void)?
    private(set) var downloadsShown = 0
    private(set) var downloadHosts: [String?] = []
    var downloadFinish: ((WaitingQuestions<DownloadChoice>.Result) -> Void)?
    private(set) var dialogsShown: [DialogRequest] = []
    var dialogFinish: ((WaitingQuestions<DialogReply>.Result) -> Void)?
    private(set) var externalShown: [(host: String?, appName: String)] = []
    var externalFinish: ((WaitingQuestions<Bool>.Result) -> Void)?

    func canAsk(_ tabID: UUID) -> Bool { !sheetUp && shownTabs.contains(tabID) }

    func showMedia(tabID: UUID, host: String, camera: Bool, microphone: Bool, finish: @escaping (WaitingQuestions<MediaAnswer>.Result) -> Void) -> Bool {
        guard canAsk(tabID) else { return false }
        sheetUp = true
        mediaShown += 1
        mediaFinish = finish
        return true
    }

    func showAuth(tabID: UUID, challenge: AuthChallenge, finish: @escaping (WaitingQuestions<AuthReply>.Result) -> Void) -> Bool {
        guard canAsk(tabID) else { return false }
        sheetUp = true
        authShown += 1
        authSite = challenge.siteKey
        authFinish = finish
        return true
    }

    func showSeveralDownloads(tabID: UUID, host: String?, finish: @escaping (WaitingQuestions<DownloadChoice>.Result) -> Void) -> Bool {
        guard canAsk(tabID) else { return false }
        sheetUp = true
        downloadsShown += 1
        downloadHosts.append(host)
        downloadFinish = finish
        return true
    }

    func showDialog(tabID: UUID, request: DialogRequest, finish: @escaping (WaitingQuestions<DialogReply>.Result) -> Void) -> Bool {
        guard canAsk(tabID) else { return false }
        sheetUp = true
        dialogsShown.append(request)
        dialogFinish = finish
        return true
    }

    func showExternalApp(tabID: UUID, host: String?, url: URL, appName: String, finish: @escaping (WaitingQuestions<Bool>.Result) -> Void) -> Bool {
        guard canAsk(tabID) else { return false }
        sheetUp = true
        externalShown.append((host, appName))
        externalFinish = finish
        return true
    }

    /// Ends the one sign-in sheet about `site`, as the app does: it reports cancelled (by the system, not the user).
    func endAuthSheets(tabID: UUID, site: String) {
        endedAuthSites.append(site)
        if sheetUp, shownTabs.contains(tabID), authSite == site {
            sheetUp = false
            authFinish?(.cancelled)
        }
    }

    /// Ends the sheets as the app does: each reports cancelled.
    func endSheets(tabID: UUID, kinds: Set<PageQuestionKind>) {
        ended.append((tabID, kinds))
        if sheetUp, shownTabs.contains(tabID) {
            sheetUp = false
            if kinds.contains(.media) { mediaFinish?(.cancelled) }
            if kinds.contains(.auth) { authFinish?(.cancelled) }
            if kinds.contains(.download) { downloadFinish?(.cancelled) }
            if kinds.contains(.dialog) { dialogFinish?(.cancelled) }
            if kinds.contains(.externalApp) { externalFinish?(.cancelled) }
        }
    }
}

@MainActor
@Suite("Page question queues")
struct PageQuestionQueuesTests {
    let tab = UUID()
    let challenge = AuthChallenge(host: "example.com", realm: "test")

    func settle(_ condition: () -> Bool) async {
        var turns = 0
        while !condition(), turns < 10_000 {
            await Task.yield()
            turns += 1
        }
    }

    /// An auth question waits while a camera question is showing, and shows once that question is answered.
    @Test func authWaitsBehindCameraThenShows() async {
        let queues = PageQuestionQueues()
        let window = FakeQuestionWindow()
        window.shownTabs = [tab]
        queues.register(window)
        let media = Task { await queues.askMedia(tabID: tab, host: "example.com", camera: true, microphone: false, isStale: { false }) }
        await settle { window.mediaShown == 1 }
        let auth = Task { await queues.askAuth(tabID: tab, challenge: challenge, isStale: { false }) }
        for _ in 0..<50 { await Task.yield() }
        queues.drainNow()
        #expect(window.authShown == 0)
        #expect(window.sheetUp)
        // The camera question is answered: its sheet comes down, the window drains, the sign-in sheet goes up.
        window.sheetUp = false
        window.mediaFinish?(.answered(MediaAnswer(allow: true, remember: false)))
        #expect(await media.value == MediaAnswer(allow: true, remember: false))
        queues.drainNow()
        #expect(window.authShown == 1)
        window.sheetUp = false
        window.authFinish?(.answered(.signedIn(AuthAnswer(user: "ann", password: "pw"))))
        #expect(await auth.value == .signedIn(AuthAnswer(user: "ann", password: "pw")))
    }

    /// One `cancel(tabID:)` covers both kinds, waiting or up, and asks every window to end the tab's sheets.
    @Test func cancelResolvesBothKinds() async {
        let queues = PageQuestionQueues()
        let window = FakeQuestionWindow()
        // The tab isn't shown: both questions wait.
        queues.register(window)
        let media = Task { await queues.askMedia(tabID: tab, host: "example.com", camera: true, microphone: true, isStale: { false }) }
        let auth = Task { await queues.askAuth(tabID: tab, challenge: challenge, isStale: { false }) }
        for _ in 0..<50 { await Task.yield() }
        #expect(window.mediaShown == 0 && window.authShown == 0)
        queues.cancel(tabID: tab)
        #expect(await media.value == nil)
        #expect(await auth.value == nil)
        #expect(window.ended.last?.1 == [.media, .auth, .download, .dialog, .externalApp])
    }

    @Test func cancelResolvesQuestionsThatAreUp() async {
        let queues = PageQuestionQueues()
        let window = FakeQuestionWindow()
        window.shownTabs = [tab]
        queues.register(window)
        let auth = Task { await queues.askAuth(tabID: tab, challenge: challenge, isStale: { false }) }
        await settle { window.authShown == 1 }
        queues.cancel(tabID: tab)
        #expect(await auth.value == nil)
        #expect(!window.sheetUp)
    }

    /// L1: a main-frame failure cancels only the sign-in questions.
    @Test func cancelAuthLeavesTheCameraQuestionAlone() async {
        let queues = PageQuestionQueues()
        let window = FakeQuestionWindow()
        queues.register(window)
        let media = Task { await queues.askMedia(tabID: tab, host: "example.com", camera: true, microphone: false, isStale: { false }) }
        let auth = Task { await queues.askAuth(tabID: tab, challenge: challenge, isStale: { false }) }
        for _ in 0..<50 { await Task.yield() }
        queues.cancelAuth(tabID: tab, site: "example.com")
        #expect(await auth.value == nil)
        #expect(window.endedAuthSites == ["example.com"])
        // The camera question still waits, and is shown when its tab is.
        window.shownTabs = [tab]
        queues.drainNow()
        #expect(window.mediaShown == 1)
        window.sheetUp = false
        window.mediaFinish?(.answered(MediaAnswer(allow: false, remember: false)))
        #expect(await media.value == MediaAnswer(allow: false, remember: false))
    }

    @Test func aStaleQuestionIsNeverShown() async {
        let queues = PageQuestionQueues()
        let window = FakeQuestionWindow()
        window.shownTabs = [tab]
        queues.register(window)
        #expect(await queues.askAuth(tabID: tab, challenge: challenge, isStale: { true }) == nil)
        #expect(window.authShown == 0)
    }

    @Test func anUnregisteredWindowShowsNothing() async {
        let queues = PageQuestionQueues()
        let window = FakeQuestionWindow()
        window.shownTabs = [tab]
        queues.register(window)
        queues.unregister(window)
        let auth = Task { await queues.askAuth(tabID: tab, challenge: challenge, isStale: { false }) }
        for _ in 0..<50 { await Task.yield() }
        #expect(window.authShown == 0)
        queues.cancel(tabID: tab)
        #expect(await auth.value == nil)
    }

    /// Item 4: a failed load cancels only the sign-ins about its own site; another site's question, waiting or up, is untouched.
    @Test func cancelAuthTouchesOnlyThatSite() async {
        let queues = PageQuestionQueues()
        let window = FakeQuestionWindow()
        queues.register(window)
        let mine = Task { await queues.askAuth(tabID: tab, challenge: AuthChallenge(host: "example.net:8443", realm: "a"), isStale: { false }) }
        let other = Task { await queues.askAuth(tabID: tab, challenge: AuthChallenge(host: "www.example.org", realm: "b"), isStale: { false }) }
        for _ in 0..<50 { await Task.yield() }
        // The site key is HostText's: no port, no www.
        queues.cancelAuth(tabID: tab, site: "example.net")
        #expect(await mine.value == nil)
        window.shownTabs = [tab]
        queues.drainNow()
        #expect(window.authShown == 1)
        window.sheetUp = false
        window.authFinish?(.answered(.signedIn(AuthAnswer(user: "ann", password: "pw"))))
        #expect(await other.value == .signedIn(AuthAnswer(user: "ann", password: "pw")))
    }

    /// Item 4: a question the system cancels has no reply; only a reply of `.cancelled` is the user's.
    @Test func systemCancelHasNoReplyAndUserCancelDoes() async {
        let queues = PageQuestionQueues()
        let window = FakeQuestionWindow()
        window.shownTabs = [tab]
        queues.register(window)
        let user = Task { await queues.askAuth(tabID: tab, challenge: challenge, isStale: { false }) }
        await settle { window.authShown == 1 }
        window.sheetUp = false
        window.authFinish?(.answered(.cancelled))
        #expect(await user.value == .cancelled)
        let system = Task { await queues.askAuth(tabID: tab, challenge: challenge, isStale: { false }) }
        await settle { window.authShown == 2 }
        queues.cancel(tabID: tab)
        #expect(await system.value == nil)
    }

    // MARK: The several-downloads question (Task 14, question 7)

    /// A question that can't be asked now is held, not refused: it waits while its tab is hidden, and is asked once the tab is shown.
    @Test func severalFilesQuestionHeldUntilItsTabIsShown() async {
        let queues = PageQuestionQueues()
        let window = FakeQuestionWindow()
        queues.register(window)
        let question = Task { await queues.askSeveralDownloads(tabID: tab, host: "example.com", isStale: { false }) }
        for _ in 0..<50 { await Task.yield() }
        queues.drainNow()
        #expect(window.downloadsShown == 0)

        window.shownTabs = [tab]
        queues.drainNow()
        #expect(window.downloadsShown == 1)
        #expect(window.downloadHosts == ["example.com"])
        window.sheetUp = false
        window.downloadFinish?(.answered(.allow))
        #expect(await question.value == .allow)
    }

    /// Another sheet on the window holds the question; it comes up when that sheet is gone.
    @Test func severalFilesQuestionWaitsBehindAnotherSheet() async {
        let queues = PageQuestionQueues()
        let window = FakeQuestionWindow()
        window.shownTabs = [tab]
        window.sheetUp = true
        queues.register(window)
        let question = Task { await queues.askSeveralDownloads(tabID: tab, host: nil, isStale: { false }) }
        for _ in 0..<50 { await Task.yield() }
        #expect(window.downloadsShown == 0)
        window.sheetUp = false
        queues.drainNow()
        #expect(window.downloadsShown == 1)
        window.sheetUp = false
        window.downloadFinish?(.answered(.dontAllow))
        #expect(await question.value == .dontAllow)
    }

    /// A new committed document, closing the page or forgetting the tab (`cancel(tabID:)`) drops the question: nil, never shown.
    @Test func heldQuestionDroppedOnNavigation() async {
        let queues = PageQuestionQueues()
        let window = FakeQuestionWindow()
        queues.register(window)
        let held = Task { await queues.askSeveralDownloads(tabID: tab, host: "example.com", isStale: { false }) }
        for _ in 0..<50 { await Task.yield() }
        queues.cancel(tabID: tab)
        #expect(await held.value == nil)
        window.shownTabs = [tab]
        queues.drainNow()
        #expect(window.downloadsShown == 0, "a dropped question is never shown later")
    }

    @Test func staleSeveralFilesQuestionIsDroppedWithoutBeingShown() async {
        let queues = PageQuestionQueues()
        let window = FakeQuestionWindow()
        queues.register(window)
        var stale = false
        let held = Task { await queues.askSeveralDownloads(tabID: tab, host: "example.com", isStale: { stale }) }
        for _ in 0..<50 { await Task.yield() }
        stale = true
        window.shownTabs = [tab]
        queues.drainNow()
        #expect(await held.value == nil)
        #expect(window.downloadsShown == 0)
    }

    /// One `cancel(tabID:)` covers a question that is up too: its sheet is ended and it resolves nil.
    @Test func cancelResolvesAShownSeveralFilesQuestion() async {
        let queues = PageQuestionQueues()
        let window = FakeQuestionWindow()
        window.shownTabs = [tab]
        queues.register(window)
        let question = Task { await queues.askSeveralDownloads(tabID: tab, host: "example.com", isStale: { false }) }
        await settle { window.downloadsShown == 1 }
        queues.cancel(tabID: tab)
        #expect(await question.value == nil)
        #expect(!window.sheetUp)
    }

    // MARK: JavaScript dialogs and the external-app question (Task 15, decisions 21 and 22)

    private let message = "Hello"
    private func request(_ kind: DialogRequest.Kind = .alert) -> DialogRequest {
        DialogRequest(kind: kind, origin: "example.com", message: message, offerToStop: false)
    }

    /// An `alert()` from a tab that isn't shown is held, not answered at once: no sheet until the tab is shown, then the sheet.
    @Test func backgroundAlertWaitsUntilShown() async {
        let queues = PageQuestionQueues()
        let window = FakeQuestionWindow()
        queues.register(window)
        var answered = false
        let alert = Task { () -> DialogReply? in
            let reply = await queues.askDialog(tabID: tab, request: request(), isStale: { false })
            answered = true
            return reply
        }
        for _ in 0..<50 { await Task.yield() }
        queues.drainNow()
        #expect(window.dialogsShown.isEmpty)
        #expect(!answered, "the page's script stays blocked, as in Chrome and Firefox")

        // Another tab being shown changes nothing.
        window.shownTabs = [UUID()]
        queues.drainNow()
        #expect(window.dialogsShown.isEmpty)

        window.shownTabs = [tab]
        queues.drainNow()
        #expect(window.dialogsShown == [request()])
        window.sheetUp = false
        window.dialogFinish?(.answered(DialogReply(accepted: true, text: nil, stopDialogs: false)))
        #expect(await alert.value == DialogReply(accepted: true, text: nil, stopDialogs: false))
    }

    /// A hidden tab's confirm and prompt wait the same way, and each keeps its own answer.
    @Test func backgroundConfirmAndPromptKeepTheirAnswers() async {
        let queues = PageQuestionQueues()
        let window = FakeQuestionWindow()
        queues.register(window)
        let confirm = Task { await queues.askDialog(tabID: tab, request: request(.confirm), isStale: { false }) }
        let prompt = Task { await queues.askDialog(tabID: tab, request: request(.prompt(defaultText: "x")), isStale: { false }) }
        for _ in 0..<50 { await Task.yield() }
        window.shownTabs = [tab]
        queues.drainNow()
        // One sheet at a time, oldest first.
        #expect(window.dialogsShown.map(\.kind) == [.confirm])
        window.sheetUp = false
        window.dialogFinish?(.answered(DialogReply(accepted: false, text: nil, stopDialogs: false)))
        #expect(await confirm.value?.accepted == false)
        queues.drainNow()
        #expect(window.dialogsShown.map(\.kind) == [.confirm, .prompt(defaultText: "x")])
        window.sheetUp = false
        window.dialogFinish?(.answered(DialogReply(accepted: true, text: "typed", stopDialogs: false)))
        #expect(await prompt.value?.text == "typed")
    }

    /// A tab hidden while its dialog is up sends the dialog back to waiting; it comes up again when the tab is shown.
    @Test func dialogSentBackWaitsAgain() async {
        let queues = PageQuestionQueues()
        let window = FakeQuestionWindow()
        window.shownTabs = [tab]
        queues.register(window)
        let confirm = Task { await queues.askDialog(tabID: tab, request: request(.confirm), isStale: { false }) }
        await settle { window.dialogsShown.count == 1 }
        window.sheetUp = false
        window.shownTabs = []
        window.dialogFinish?(.sentBack)
        queues.drainNow()
        #expect(window.dialogsShown.count == 1)
        window.shownTabs = [tab]
        queues.drainNow()
        #expect(window.dialogsShown.count == 2)
        window.sheetUp = false
        window.dialogFinish?(.answered(DialogReply(accepted: true, text: nil, stopDialogs: false)))
        #expect(await confirm.value?.accepted == true)
    }

    /// A navigation (a new committed document) resolves a waiting confirm with no answer, so the page's `confirm()` returns false, and the
    /// dialog is never shown later. The same for the sheet when it is up.
    @Test func navigationResolvesAWaitingConfirm() async {
        let queues = PageQuestionQueues()
        let window = FakeQuestionWindow()
        queues.register(window)
        let waiting = Task { await queues.askDialog(tabID: tab, request: request(.confirm), isStale: { false }) }
        for _ in 0..<50 { await Task.yield() }
        queues.cancel(tabID: tab)
        #expect(await waiting.value == nil)
        window.shownTabs = [tab]
        queues.drainNow()
        #expect(window.dialogsShown.isEmpty)

        let up = Task { await queues.askDialog(tabID: tab, request: request(.confirm), isStale: { false }) }
        await settle { window.dialogsShown.count == 1 }
        queues.cancel(tabID: tab)
        #expect(await up.value == nil)
        #expect(!window.sheetUp, "the dialog's sheet comes down with its document")
    }

    @Test func staleDialogIsDroppedWithoutBeingShown() async {
        let queues = PageQuestionQueues()
        let window = FakeQuestionWindow()
        queues.register(window)
        var stale = false
        let waiting = Task { await queues.askDialog(tabID: tab, request: request(), isStale: { stale }) }
        for _ in 0..<50 { await Task.yield() }
        stale = true
        window.shownTabs = [tab]
        queues.drainNow()
        #expect(await waiting.value == nil)
        #expect(window.dialogsShown.isEmpty)
    }

    /// The external-app question is the tab's: it isn't shown while the tab is hidden, and it comes back when the tab is shown again.
    @Test func externalQuestionHidesWithItsTabAndComesBack() async {
        let queues = PageQuestionQueues()
        let window = FakeQuestionWindow()
        window.shownTabs = [tab]
        queues.register(window)
        let question = Task { await queues.askExternalApp(tabID: tab, host: "example.com", url: URL(string: "mailto:a@example.com")!, appName: "Mail", isStale: { false }) }
        await settle { window.externalShown.count == 1 }
        #expect(window.externalShown.first?.host == "example.com")
        // The tab is hidden: the sheet comes down and the question waits.
        window.sheetUp = false
        window.shownTabs = []
        window.externalFinish?(.sentBack)
        queues.drainNow()
        #expect(window.externalShown.count == 1)
        // Shown again: it is asked again.
        window.shownTabs = [tab]
        queues.drainNow()
        #expect(window.externalShown.count == 2)
        window.sheetUp = false
        window.externalFinish?(.answered(true))
        #expect(await question.value == true)
    }

    /// "Bring It Here" moves the page to another window: the question is dropped, waiting or up, and no window asks it later. The tab's
    /// other questions are not touched.
    @Test func externalQuestionDroppedOnBringHere() async {
        let queues = PageQuestionQueues()
        let window = FakeQuestionWindow()
        window.shownTabs = [tab]
        queues.register(window)
        let url = URL(string: "mailto:a@example.com")!
        let up = Task { await queues.askExternalApp(tabID: tab, host: nil, url: url, appName: "Mail", isStale: { false }) }
        await settle { window.externalShown.count == 1 }
        let media = Task { await queues.askMedia(tabID: tab, host: "example.com", camera: true, microphone: false, isStale: { false }) }
        for _ in 0..<50 { await Task.yield() }
        queues.cancelExternalApp(tabID: tab)
        #expect(await up.value == nil)
        #expect(!window.sheetUp)
        // The camera question was waiting behind that sheet and is still alive: it comes up now.
        queues.drainNow()
        #expect(window.mediaShown == 1)
        window.sheetUp = false
        window.mediaFinish?(.answered(MediaAnswer(allow: true, remember: false)))
        #expect(await media.value == MediaAnswer(allow: true, remember: false))

        // A waiting one (its tab hidden) is dropped too and never shown later.
        window.shownTabs = []
        let waiting = Task { await queues.askExternalApp(tabID: tab, host: nil, url: url, appName: "Mail", isStale: { false }) }
        for _ in 0..<50 { await Task.yield() }
        queues.cancelExternalApp(tabID: tab)
        #expect(await waiting.value == nil)
        window.shownTabs = [tab]
        queues.drainNow()
        #expect(window.externalShown.count == 1)
    }

    /// A page hibernation unloads, closed or forgotten: one `cancel(tabID:)` drops every kind of question it had, dialogs and the
    /// external-app question included, so none is shown over a page that is gone.
    @Test func cancelDropsEveryKindOfQuestion() async {
        let queues = PageQuestionQueues()
        let window = FakeQuestionWindow()
        queues.register(window)
        let url = URL(string: "mailto:a@example.com")!
        let dialog = Task { await queues.askDialog(tabID: tab, request: request(.confirm), isStale: { false }) }
        let external = Task { await queues.askExternalApp(tabID: tab, host: nil, url: url, appName: "Mail", isStale: { false }) }
        let media = Task { await queues.askMedia(tabID: tab, host: "example.com", camera: true, microphone: false, isStale: { false }) }
        for _ in 0..<50 { await Task.yield() }
        queues.cancel(tabID: tab)
        #expect(await dialog.value == nil)
        #expect(await external.value == nil)
        #expect(await media.value == nil)
        window.shownTabs = [tab]
        queues.drainNow()
        #expect(window.dialogsShown.isEmpty && window.externalShown.isEmpty && window.mediaShown == 0)
    }
}
