import Foundation
import Testing

@testable import StaveCore

/// A question the test answers by hand: `perform` suspends until `answer` is called.
@MainActor
final class HandAnswered {
    private(set) var asked = 0
    private var waiting: [CheckedContinuation<AuthReply?, Never>] = []
    var waitingCount: Int { waiting.count }

    func perform() async -> AuthReply? {
        asked += 1
        return await withCheckedContinuation { waiting.append($0) }
    }

    func answer(_ answer: AuthReply?) {
        let all = waiting
        waiting = []
        for continuation in all { continuation.resume(returning: answer) }
    }
}

/// What a call to the gate returned, and whether it has returned yet. Lets a test start a call that should be refused without awaiting it
/// in line: without the refusal the call would wait for a hand answer and hang the test instead of failing it.
@MainActor
final class CallOutcome {
    private(set) var isDone = false
    private(set) var value: AuthAnswer?
    private var task: Task<Void, Never>?

    init(_ call: @escaping @MainActor () async -> AuthAnswer?) {
        task = Task { @MainActor in
            let result = await call()
            value = result
            isDone = true
        }
    }

    func finished() async {
        await task?.value
    }
}

@MainActor
@Suite("Sign-in question gate")
struct AuthQuestionGateTests {
    let space = AuthSpace(host: "example.com", scheme: "https", realm: "test", method: NSURLAuthenticationMethodHTTPBasic, isProxy: false)
    let ann = AuthAnswer(user: "ann", password: "pw")
    var reply: AuthReply { .signedIn(ann) }

    /// Yields until `condition` holds; bounded by turns of the main actor, never by time.
    func settle(_ condition: () -> Bool) async {
        var turns = 0
        while !condition(), turns < 10_000 {
            await Task.yield()
            turns += 1
        }
    }

    /// Starts `call`, waits (in turns, never time) until it has either returned or asked the user, then releases every question the hand
    /// holds with a real answer and returns what the call gave. A refusal returns nil with nothing asked; with the refusal removed the call
    /// asks, gets the answer, and the caller's expectations fail instead of hanging.
    func releasedOutcome(of call: @escaping @MainActor () async -> AuthAnswer?, hand: HandAnswered) async -> AuthAnswer? {
        let askedBefore = hand.asked
        let outcome = CallOutcome(call)
        await settle { outcome.isDone || hand.asked > askedBefore }
        hand.answer(reply)
        await outcome.finished()
        return outcome.value
    }

    /// H2 (a): challenges for the same protection space share one question, and every waiter gets the same answer.
    @Test func sameSpaceIsOneQuestion() async {
        let gate = AuthQuestionGate()
        let hand = HandAnswered()
        let first = Task { await gate.ask(space, document: 1) { await hand.perform() } }
        await settle { hand.waitingCount == 1 }
        let second = Task { await gate.ask(space, document: 1) { await hand.perform() } }
        let third = Task { await gate.ask(space, document: 1) { await hand.perform() } }
        await settle { gate.openCount == 1 }
        for _ in 0..<50 { await Task.yield() }
        hand.answer(reply)
        #expect(await first.value == ann)
        #expect(await second.value == ann)
        #expect(await third.value == ann)
        #expect(hand.asked == 1)
        #expect(gate.openCount == 0)
    }

    @Test func aCancelReachesEveryWaiter() async {
        let gate = AuthQuestionGate()
        let hand = HandAnswered()
        let first = Task { await gate.ask(space, document: 1) { await hand.perform() } }
        await settle { hand.waitingCount == 1 }
        let second = Task { await gate.ask(space, document: 1) { await hand.perform() } }
        for _ in 0..<50 { await Task.yield() }
        hand.answer(.cancelled)
        #expect(await first.value == nil)
        #expect(await second.value == nil)
        #expect(hand.asked == 1)
    }

    @Test func differentRealmMethodHostOrProxyAreDifferentQuestions() async {
        let gate = AuthQuestionGate()
        let hand = HandAnswered()
        let others = [
            AuthSpace(host: "example.com", scheme: "https", realm: "other", method: NSURLAuthenticationMethodHTTPBasic, isProxy: false),
            AuthSpace(host: "example.com", scheme: "https", realm: "test", method: NSURLAuthenticationMethodHTTPDigest, isProxy: false),
            AuthSpace(host: "example.org", scheme: "https", realm: "test", method: NSURLAuthenticationMethodHTTPBasic, isProxy: false),
            AuthSpace(host: "example.com", scheme: "https", realm: "test", method: NSURLAuthenticationMethodHTTPBasic, isProxy: true),
        ]
        var tasks = [Task { await gate.ask(space, document: 1) { await hand.perform() } }]
        for other in others { tasks.append(Task { await gate.ask(other, document: 1) { await hand.perform() } }) }
        await settle { hand.waitingCount == 5 }
        #expect(hand.asked == 5)
        hand.answer(reply)
        for task in tasks { #expect(await task.value == ann) }
    }

    /// H2 (b): three cancels in one document, and the fourth challenge is refused without asking, until a new document commits.
    @Test func threeCancelsStopTheQuestionsUntilANewDocument() async {
        let gate = AuthQuestionGate()
        let hand = HandAnswered()
        for _ in 0..<AuthQuestionGate.cancelLimit {
            let task = Task { await gate.ask(space, document: 1) { await hand.perform() } }
            await settle { hand.waitingCount == 1 }
            hand.answer(.cancelled)
            #expect(await task.value == nil)
        }
        #expect(hand.asked == 3)
        let space = space
        let refused = await releasedOutcome(of: { await gate.ask(space, document: 1) { await hand.perform() } }, hand: hand)
        #expect(refused == nil)
        let other = AuthSpace(host: "example.org", scheme: "https", realm: nil, method: NSURLAuthenticationMethodHTTPBasic, isProxy: false)
        let refusedOther = await releasedOutcome(of: { await gate.ask(other, document: 1) { await hand.perform() } }, hand: hand)
        #expect(refusedOther == nil)
        #expect(hand.asked == 3)
        // The main frame committed a new navigation: asking resumes.
        let next = Task { await gate.ask(space, document: 2) { await hand.perform() } }
        await settle { hand.waitingCount == 1 }
        #expect(hand.asked == 4)
        hand.answer(reply)
        #expect(await next.value == ann)
    }

    @Test func anAnswerIsNotACancel() async {
        let gate = AuthQuestionGate()
        let hand = HandAnswered()
        for _ in 0..<6 {
            let task = Task { await gate.ask(space, document: 1) { await hand.perform() } }
            await settle { hand.waitingCount == 1 }
            hand.answer(reply)
            #expect(await task.value == ann)
        }
        #expect(hand.asked == 6)
    }

    /// H2 (c): at most five different questions wait; a sixth is refused without asking, and a joiner of an open one still joins.
    @Test func sixthWaitingQuestionIsRefused() async {
        let gate = AuthQuestionGate()
        let hand = HandAnswered()
        var tasks: [Task<AuthAnswer?, Never>] = []
        for index in 0..<AuthQuestionGate.waitingLimit {
            let own = AuthSpace(host: "example.com", scheme: "https", realm: "r\(index)", method: NSURLAuthenticationMethodHTTPBasic, isProxy: false)
            tasks.append(Task { await gate.ask(own, document: 1) { await hand.perform() } })
        }
        await settle { hand.waitingCount == 5 }
        let sixth = AuthSpace(host: "example.com", scheme: "https", realm: "r5", method: NSURLAuthenticationMethodHTTPBasic, isProxy: false)
        // A joiner of an open question still joins, though the cap is reached.
        let joiner = Task { await gate.ask(AuthSpace(host: "example.com", scheme: "https", realm: "r0", method: NSURLAuthenticationMethodHTTPBasic, isProxy: false), document: 1) { await hand.perform() } }
        for _ in 0..<50 { await Task.yield() }
        #expect(gate.openCount == 5)
        // The sixth is refused: it returns nil with nothing asked, and the release answers the five open ones.
        let refusedSixth = await releasedOutcome(of: { await gate.ask(sixth, document: 1) { await hand.perform() } }, hand: hand)
        #expect(refusedSixth == nil)
        #expect(hand.asked == 5)
        for task in tasks { #expect(await task.value == ann) }
        #expect(await joiner.value == ann)
        // Room again once they are answered.
        let again = Task { await gate.ask(sixth, document: 1) { await hand.perform() } }
        await settle { hand.waitingCount == 1 }
        hand.answer(reply)
        #expect(await again.value == ann)
    }

    /// Only the user's Cancel counts: questions the system dropped (nil, no reply) never reach the limit.
    @Test func droppedQuestionsAreNotCancels() async {
        let gate = AuthQuestionGate()
        let hand = HandAnswered()
        for _ in 0..<(AuthQuestionGate.cancelLimit + 2) {
            let task = Task { await gate.ask(space, document: 1) { await hand.perform() } }
            await settle { hand.waitingCount == 1 }
            hand.answer(nil)
            #expect(await task.value == nil)
        }
        #expect(hand.asked == 5)
        // Still asking: a user's answer goes through.
        let next = Task { await gate.ask(space, document: 1) { await hand.perform() } }
        await settle { hand.waitingCount == 1 }
        hand.answer(reply)
        #expect(await next.value == ann)
        #expect(hand.asked == 6)
    }

    /// Two dropped questions and the user's cancels: only the cancels are counted.
    @Test func userCancelsCountAmongDrops() async {
        let gate = AuthQuestionGate()
        let hand = HandAnswered()
        let replies: [AuthReply?] = [.cancelled, nil, .cancelled, nil, .cancelled]
        for next in replies {
            let task = Task { await gate.ask(space, document: 1) { await hand.perform() } }
            await settle { hand.waitingCount == 1 }
            hand.answer(next)
            #expect(await task.value == nil)
        }
        #expect(hand.asked == 5)
        let space = space
        let refused = await releasedOutcome(of: { await gate.ask(space, document: 1) { await hand.perform() } }, hand: hand)
        #expect(refused == nil)
        #expect(hand.asked == 5)
    }

    /// Item 7: http and https for one host are different questions, so one answer is never shared between them.
    @Test func httpAndHttpsAreDifferentQuestions() async {
        let gate = AuthQuestionGate()
        let hand = HandAnswered()
        let plain = AuthSpace(host: "example.com", scheme: "http", realm: "test", method: NSURLAuthenticationMethodHTTPBasic, isProxy: false)
        let secure = AuthSpace(host: "example.com", scheme: "HTTPS", realm: "test", method: NSURLAuthenticationMethodHTTPBasic, isProxy: false)
        #expect(plain != secure)
        #expect(secure == space)
        let first = Task { await gate.ask(plain, document: 1) { await hand.perform() } }
        let second = Task { await gate.ask(secure, document: 1) { await hand.perform() } }
        await settle { hand.waitingCount == 2 }
        #expect(hand.asked == 2)
        hand.answer(reply)
        #expect(await first.value == ann)
        #expect(await second.value == ann)
    }
}
