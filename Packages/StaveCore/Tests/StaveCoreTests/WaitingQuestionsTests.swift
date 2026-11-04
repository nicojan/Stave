import Foundation
import Testing
@testable import StaveCore

/// Stands in for a window: `canShow` is whether a question can be shown now, and each shown question's `finish` is kept for the test to call.
@MainActor
private final class FakeShower {
    var canShow = false
    var shown: [(tabID: UUID, finish: (WaitingQuestions<String>.Result) -> Void)] = []

    func show(_ tabID: UUID) -> WaitingQuestions<String>.Show {
        { [unowned self] finish in
            guard canShow else { return false }
            shown.append((tabID, finish))
            return true
        }
    }
}

@MainActor
private final class Flag {
    var isSet = false
}

@MainActor
@Suite("Waiting questions")
struct WaitingQuestionsTests {
    private func settle() async { for _ in 0..<5 { await Task.yield() } }

    @Test func aQuestionThatCannotBeShownWaitsThenShowsWhenItCan() async {
        let queue = WaitingQuestions<String>()
        let shower = FakeShower()
        let tab = UUID()
        let resolved = Flag()
        let task = Task { @MainActor () -> String? in
            let answer = await queue.ask(tabID: tab, show: shower.show(tab))
            resolved.isSet = true
            return answer
        }
        await settle()
        #expect(shower.shown.isEmpty)
        #expect(!resolved.isSet)

        shower.canShow = true
        queue.drain()
        #expect(shower.shown.count == 1)
        shower.shown[0].finish(.answered("yes"))
        #expect(await task.value == "yes")
        #expect(resolved.isSet)
    }

    /// A question whose page went away (unloaded, navigated, remade) resolves with nil and is never shown, however it is checked.
    @Test func aStaleQuestionResolvesNilWithoutBeingShown() async {
        let queue = WaitingQuestions<String>()
        let shower = FakeShower()
        let tab = UUID()
        let stale = Flag()
        let task = Task { @MainActor in await queue.ask(tabID: tab, isStale: { stale.isSet }, show: shower.show(tab)) }
        await settle()
        stale.isSet = true
        shower.canShow = true
        queue.drain()
        #expect(await task.value == nil)
        #expect(shower.shown.isEmpty)
    }

    @Test func aQuestionAlreadyStaleWhenAskedIsNeverShown() async {
        let queue = WaitingQuestions<String>()
        let shower = FakeShower()
        shower.canShow = true
        let tab = UUID()
        #expect(await queue.ask(tabID: tab, isStale: { true }, show: shower.show(tab)) == nil)
        #expect(shower.shown.isEmpty)
    }

    /// A question sent back is checked again before it is shown the second time.
    @Test func aQuestionSentBackThenStaleIsNotShownAgain() async {
        let queue = WaitingQuestions<String>()
        let shower = FakeShower()
        shower.canShow = true
        let tab = UUID()
        let stale = Flag()
        let task = Task { @MainActor in await queue.ask(tabID: tab, isStale: { stale.isSet }, show: shower.show(tab)) }
        await settle()
        shower.shown[0].finish(.sentBack)
        stale.isSet = true
        queue.drain()
        #expect(await task.value == nil)
        #expect(shower.shown.count == 1)
    }

    @Test func aQuestionThatCanBeShownShowsAtOnce() async {
        let queue = WaitingQuestions<String>()
        let shower = FakeShower()
        shower.canShow = true
        let tab = UUID()
        let task = Task { @MainActor in await queue.ask(tabID: tab, show: shower.show(tab)) }
        await settle()
        #expect(shower.shown.count == 1)
        shower.shown[0].finish(.answered("ok"))
        #expect(await task.value == "ok")
    }

    @Test func aQuestionSentBackWaitsAgainAndIsNotResolved() async {
        let queue = WaitingQuestions<String>()
        let shower = FakeShower()
        shower.canShow = true
        let tab = UUID()
        let task = Task { @MainActor in await queue.ask(tabID: tab, show: shower.show(tab)) }
        await settle()
        shower.shown[0].finish(.sentBack)
        shower.canShow = false
        queue.drain()
        await settle()
        #expect(shower.shown.count == 1)

        shower.canShow = true
        queue.drain()
        #expect(shower.shown.count == 2)
        shower.shown[1].finish(.answered("later"))
        #expect(await task.value == "later")
    }

    @Test func aFinishFromAnEarlierShowIsIgnored() async {
        let queue = WaitingQuestions<String>()
        let shower = FakeShower()
        shower.canShow = true
        let tab = UUID()
        let task = Task { @MainActor in await queue.ask(tabID: tab, show: shower.show(tab)) }
        await settle()
        shower.shown[0].finish(.sentBack)
        queue.drain()
        #expect(shower.shown.count == 2)
        // The first sheet reports again, late: it must not answer the second one's question.
        shower.shown[0].finish(.answered("stale"))
        shower.shown[1].finish(.answered("fresh"))
        #expect(await task.value == "fresh")
    }

    @Test func cancellingATabResolvesItsWaitingQuestionsOnly() async {
        let queue = WaitingQuestions<String>()
        let shower = FakeShower()
        let (a, b) = (UUID(), UUID())
        let first = Task { @MainActor in await queue.ask(tabID: a, show: shower.show(a)) }
        let second = Task { @MainActor in await queue.ask(tabID: b, show: shower.show(b)) }
        await settle()
        queue.cancel(tabID: a)
        #expect(await first.value == nil)

        shower.canShow = true
        queue.drain()
        #expect(shower.shown.map(\.tabID) == [b])
        shower.shown[0].finish(.answered("b"))
        #expect(await second.value == "b")
    }

    @Test func cancellingATabResolvesAQuestionThatIsUpAndIgnoresItsLateAnswer() async {
        let queue = WaitingQuestions<String>()
        let shower = FakeShower()
        shower.canShow = true
        let tab = UUID()
        let task = Task { @MainActor in await queue.ask(tabID: tab, show: shower.show(tab)) }
        await settle()
        queue.cancel(tabID: tab)
        #expect(await task.value == nil)
        shower.shown[0].finish(.answered("late"))
        queue.drain()
        #expect(shower.shown.count == 1)
    }

    @Test func aCancelledSheetResolvesNil() async {
        let queue = WaitingQuestions<String>()
        let shower = FakeShower()
        shower.canShow = true
        let tab = UUID()
        let task = Task { @MainActor in await queue.ask(tabID: tab, show: shower.show(tab)) }
        await settle()
        shower.shown[0].finish(.cancelled)
        #expect(await task.value == nil)
    }

    @Test func closingResolvesEverythingAndLaterQuestionsResolveAtOnce() async {
        let queue = WaitingQuestions<String>()
        let shower = FakeShower()
        let (a, b) = (UUID(), UUID())
        let first = Task { @MainActor in await queue.ask(tabID: a, show: shower.show(a)) }
        let second = Task { @MainActor in await queue.ask(tabID: b, show: shower.show(b)) }
        await settle()
        queue.close()
        #expect(await first.value == nil)
        #expect(await second.value == nil)

        shower.canShow = true
        #expect(await queue.ask(tabID: a, show: shower.show(a)) == nil)
        #expect(shower.shown.isEmpty)
    }

    @Test func questionsShowInTheOrderTheyWereAsked() async {
        let queue = WaitingQuestions<String>()
        let shower = FakeShower()
        let tabs = (0..<3).map { _ in UUID() }
        let tasks = tabs.map { tab in Task { @MainActor in await queue.ask(tabID: tab, show: shower.show(tab)) } }
        await settle()
        shower.canShow = true
        queue.drain()
        #expect(shower.shown.map(\.tabID) == tabs)
        for (index, entry) in shower.shown.enumerated() { entry.finish(.answered("\(index)")) }
        var answers: [String?] = []
        for task in tasks { answers.append(await task.value) }
        #expect(answers == ["0", "1", "2"])
    }
}
