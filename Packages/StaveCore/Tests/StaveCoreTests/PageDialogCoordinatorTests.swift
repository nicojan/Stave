import Foundation
import Testing

@testable import StaveCore

/// M1: the dialog gate, the reply mapping and the prompt draft, which the app's `PageQuestionCenter` and `PagePrompts` used to hold. A
/// revert of any of these in `PageDialogCoordinator` turns a test here red.
@MainActor
@Suite("Page dialog coordinator")
struct PageDialogCoordinatorTests {
    private final class Page {}

    private func make() -> (PageDialogCoordinator, PageQuestionQueues, FakeQuestionWindow, UUID, Page) {
        let queues = PageQuestionQueues()
        let window = FakeQuestionWindow()
        let tab = UUID()
        window.shownTabs = [tab]
        queues.register(window)
        return (PageDialogCoordinator(queues: queues), queues, window, tab, Page())
    }

    private func answer(_ window: FakeQuestionWindow, _ reply: DialogReply) async {
        window.sheetUp = false
        window.dialogFinish?(.answered(reply))
        await Task.yield()
    }

    @Test func confirmMapsTheReply() async {
        let (coordinator, _, window, tab, page) = make()
        let asked = Task { await coordinator.confirm(tabID: tab, page: page, navigation: 1, origin: nil, message: "m", isStale: { false }) }
        await Task.yield()
        await answer(window, DialogReply(accepted: true, text: nil, stopDialogs: false))
        #expect(await asked.value == true)
        let cancelled = Task { await coordinator.confirm(tabID: tab, page: page, navigation: 1, origin: nil, message: "m", isStale: { false }) }
        await Task.yield()
        await answer(window, DialogReply(accepted: false, text: nil, stopDialogs: false))
        #expect(await cancelled.value == false)
    }

    @Test func promptMapsTextCancelAndEmpty() async {
        let (coordinator, _, window, tab, page) = make()
        func ask() -> Task<String?, Never> {
            Task { await coordinator.prompt(tabID: tab, page: page, navigation: 1, origin: nil, message: "m", defaultText: "d", isStale: { false }) }
        }
        var task = ask()
        await Task.yield()
        await answer(window, DialogReply(accepted: true, text: "typed", stopDialogs: false))
        #expect(await task.value == "typed")
        task = ask()
        await Task.yield()
        await answer(window, DialogReply(accepted: true, text: nil, stopDialogs: false))
        #expect(await task.value == "", "OK with no text is the empty string, not nil")
        task = ask()
        await Task.yield()
        await answer(window, DialogReply(accepted: false, text: "ignored", stopDialogs: false))
        #expect(await task.value == nil, "Cancel is nil whatever was typed")
    }

    /// A page that loops alert() is offered "Don't show more", and once the user ticks it later dialogs return at once, unshown, until a
    /// new document commits.
    @Test func stoppedPageResolvesAtOnceUntilANewDocument() async {
        let (coordinator, _, window, tab, page) = make()
        for round in 1...PageDialogGate.threshold {
            let asked = Task { await coordinator.alert(tabID: tab, page: page, navigation: 1, origin: nil, message: "m\(round)", isStale: { false }) }
            await Task.yield()
            let last = round == PageDialogGate.threshold
            #expect(window.dialogsShown.last?.offerToStop == last)
            await answer(window, DialogReply(accepted: true, text: nil, stopDialogs: last))
            await asked.value
        }
        let shownBefore = window.dialogsShown.count
        let again = Task { await coordinator.alert(tabID: tab, page: page, navigation: 1, origin: nil, message: "again", isStale: { false }) }
        await Task.yield()
        #expect(window.dialogsShown.count == shownBefore, "stopped: returns at once, shows nothing")
        if window.dialogsShown.count != shownBefore { await answer(window, DialogReply(accepted: true, text: nil, stopDialogs: false)) }
        await again.value
        let next = Task { await coordinator.alert(tabID: tab, page: page, navigation: 2, origin: nil, message: "new doc", isStale: { false }) }
        await Task.yield()
        #expect(window.dialogsShown.count == shownBefore + 1, "a new document asks again")
        await answer(window, DialogReply(accepted: true, text: nil, stopDialogs: false))
        await next.value
    }

    /// A page remade for the tab gets its own gate: the old page's stop doesn't carry over.
    @Test func aRemadePageHasAFreshGate() async {
        let (coordinator, _, window, tab, page) = make()
        let first = Task { await coordinator.alert(tabID: tab, page: page, navigation: 1, origin: nil, message: "m", isStale: { false }) }
        await Task.yield()
        await answer(window, DialogReply(accepted: true, text: nil, stopDialogs: true))
        await first.value
        let remade = Page()
        let second = Task { await coordinator.alert(tabID: tab, page: remade, navigation: 1, origin: nil, message: "m", isStale: { false }) }
        await Task.yield()
        #expect(window.dialogsShown.count == 2)
        await answer(window, DialogReply(accepted: true, text: nil, stopDialogs: false))
        await second.value
    }

    @Test func staleQuestionReturnsTheSafeAnswers() async {
        let (coordinator, _, window, tab, page) = make()
        #expect(await coordinator.confirm(tabID: tab, page: page, navigation: 1, origin: nil, message: "m", isStale: { true }) == false)
        #expect(await coordinator.prompt(tabID: tab, page: page, navigation: 1, origin: nil, message: "m", defaultText: nil, isStale: { true }) == nil)
        #expect(window.dialogsShown.isEmpty)
    }

    /// L1: what was typed belongs to the question it was typed for, and goes with the tab's questions.
    @Test func draftBelongsToItsQuestionAndGoesOnCancel() {
        let (coordinator, _, _, tab, _) = make()
        let request = DialogRequest(kind: .prompt(defaultText: nil), origin: "a.example", message: "name?", offerToStop: false)
        let other = DialogRequest(kind: .prompt(defaultText: nil), origin: "b.example", message: "name?", offerToStop: false)
        coordinator.keepDraft("half typed", for: tab, request: request)
        #expect(coordinator.draft(for: tab, request: request) == "half typed")
        #expect(coordinator.draft(for: tab, request: other) == nil, "a later prompt from another site doesn't start with it")
        coordinator.cancel(tabID: tab)
        #expect(coordinator.draft(for: tab, request: request) == nil)
        coordinator.keepDraft("again", for: tab, request: request)
        coordinator.keepDraft(nil, for: tab, request: request)
        #expect(coordinator.draft(for: tab, request: request) == nil)
    }

    /// R1-7: cancelling a tab's dialogs also drops its prompt draft, so a later prompt doesn't start with the answered one's text.
    @Test func cancelDialogsDropsThePromptDraft() {
        let (coordinator, _, _, tab, _) = make()
        let request = DialogRequest(kind: .prompt(defaultText: nil), origin: "a.example", message: "name?", offerToStop: false)
        coordinator.keepDraft("half typed", for: tab, request: request)
        coordinator.cancelDialogs(tabID: tab)
        #expect(coordinator.draft(for: tab, request: request) == nil)
    }

    /// H2: a closed window's background tab's waiting dialog is answered (cancelled) without touching its other questions.
    @Test func cancelDialogsAnswersOnlyDialogs() async {
        let (coordinator, queues, window, _, page) = make()
        let hidden = UUID()
        let dialog = Task { await coordinator.confirm(tabID: hidden, page: page, navigation: 1, origin: nil, message: "m", isStale: { false }) }
        let external = Task { await queues.askExternalApp(tabID: hidden, host: nil, url: URL(string: "mailto:a@example.com")!, appName: "Mail", isStale: { false }) }
        await Task.yield()
        #expect(window.dialogsShown.isEmpty)
        coordinator.cancelDialogs(tabID: hidden)
        #expect(await dialog.value == false)
        window.shownTabs = [hidden]
        queues.drainNow()
        #expect(window.externalShown.count == 1, "its external-app question still waits")
        coordinator.cancel(tabID: hidden)
        #expect(await external.value == nil)
    }
}
