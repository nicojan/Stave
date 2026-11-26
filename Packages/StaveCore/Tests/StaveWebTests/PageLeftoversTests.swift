import Foundation
import Observation
import StaveCore
import Testing
import WebKit

@testable import StaveWeb

/// Plan 5, Task 15: the external-app question's heading and lifetime, hibernation, coalesced title writes and the menu's page fields.
extension WebKitTests.PageDelegateTests {
    /// The sheet names the frame that clicked when WebKit gives it, not the top page: an ad frame can't borrow the page's name, and a
    /// frame can't hide behind it. With no frame information the top page's site is named, as before.
    @Test func externalQuestionNamesTheClickingFrame() async throws {
        let host = makeHost()
        let apps = FakeExternalApps()
        apps.app = URL(fileURLWithPath: "/System/Applications/Mail.app")
        host.externalApps = apps.seam
        let page = host.page(for: request(), writer: writer)
        page.status.url = "https://www.example.com/contact"
        let delegate = try delegate(of: page)
        _ = delegate.decide(NavigationRequest("mailto:a@example.com", sourceHost: "Ads.Example.net"))
        await delegate.externalTask?.value
        #expect(events.externalAskers.last?.host == "ads.example.net")
        clock.date += PageDelegate.externalCooldown + 0.1
        _ = delegate.decide(NavigationRequest("mailto:a@example.com", sourceHost: nil))
        await delegate.externalTask?.value
        #expect(events.externalAskers.last?.host == "example.com")
        // A typed address is the user's own: it names no one, whatever frame data exists.
        clock.date += PageDelegate.externalCooldown + 0.1
        host.loadTyped("mailto:b@example.com", in: page.tabID)
        await delegate.externalTask?.value
        #expect(events.externalAskers.last?.host == nil)
        host.close(page.tabID)
    }

    /// A typed `mailto:` reaches the external-app question through the host, as in Safari; with no app it says so.
    @Test func typedMailtoReachesTheQuestion() async throws {
        let host = makeHost()
        let apps = FakeExternalApps()
        apps.app = URL(fileURLWithPath: "/System/Applications/Mail.app")
        host.externalApps = apps.seam
        let page = host.page(for: request(), writer: writer)
        let delegate = try delegate(of: page)
        guard case .externalLink(let typed) = AddressInput.classify("mailto:a@example.com") else {
            Issue.record("a typed mailto: is not an external link")
            return
        }
        host.loadTyped(typed, in: page.tabID)
        await delegate.externalTask?.value
        #expect(events.externalQuestions.count == 1)
        #expect(events.externalQuestions.first?.0 == URL(string: "mailto:a@example.com"))
        #expect(events.externalAskers.first?.host == nil)
        #expect(apps.opened.isEmpty, "declined by default: nothing opens")
        apps.app = nil
        clock.date += PageDelegate.externalCooldown + 0.1
        host.loadTyped("tel:5551234", in: page.tabID)
        await delegate.externalTask?.value
        #expect(page.status.failure == .noAppForLink(url: "tel:5551234"))
        host.close(page.tabID)
    }

    /// The page navigated while the question was up (the app drops it then): the link is not opened for the page it didn't come from, and
    /// the drop is not the user's No, so no cooldown follows.
    @Test func externalQuestionDroppedByNavigationOpensNothingAndHasNoCooldown() async throws {
        let host = makeHost()
        let apps = FakeExternalApps()
        apps.app = URL(fileURLWithPath: "/System/Applications/Mail.app")
        host.externalApps = apps.seam
        events.externalAnswer = true
        let page = host.page(for: request(), writer: writer)
        let delegate = try delegate(of: page)
        events.whileConfirming = { delegate.webView(page.webView, didCommit: nil) }
        _ = delegate.decide(NavigationRequest("mailto:a@example.com"))
        await delegate.externalTask?.value
        #expect(events.externalQuestions.count == 1)
        #expect(apps.opened.isEmpty)
        events.whileConfirming = nil
        // Same clock reading: a cooldown would drop this request.
        _ = delegate.decide(NavigationRequest("mailto:b@example.com"))
        await delegate.externalTask?.value
        #expect(events.externalQuestions.count == 2)
        #expect(apps.opened == [URL(string: "mailto:b@example.com")!])
        host.close(page.tabID)
    }

    /// L3: a question the system drops (Bring It Here) is not the user's No: nothing opens and no cooldown starts, so the next link asks at
    /// once; the user's own Cancel does start the cooldown.
    @Test func droppedExternalQuestionStartsNoCooldownButCancelDoes() async throws {
        let host = makeHost()
        let apps = FakeExternalApps()
        apps.app = URL(fileURLWithPath: "/System/Applications/Mail.app")
        host.externalApps = apps.seam
        let page = host.page(for: request(), writer: writer)
        let delegate = try delegate(of: page)
        events.externalDropped = true
        events.externalAnswer = true
        _ = delegate.decide(NavigationRequest("mailto:a@example.com"))
        await delegate.externalTask?.value
        #expect(apps.opened.isEmpty)
        events.externalDropped = false
        _ = delegate.decide(NavigationRequest("mailto:b@example.com"))
        await delegate.externalTask?.value
        #expect(events.externalQuestions.count == 2, "no cooldown after a dropped question")
        events.externalAnswer = false
        _ = delegate.decide(NavigationRequest("mailto:c@example.com"))
        await delegate.externalTask?.value
        _ = delegate.decide(NavigationRequest("mailto:d@example.com"))
        await delegate.externalTask?.value
        #expect(events.externalQuestions.count == 3, "the user's Cancel does start the cooldown")
        #expect(QuestionAnswer(externalAppReply: true) == .allowed)
        #expect(QuestionAnswer(externalAppReply: false) == .declined)
        #expect(QuestionAnswer(externalAppReply: nil) == .unasked)
        host.close(page.tabID)
    }

    /// H1: the clicking frame is now read through key-value coding, in the external branch only. A real clicked mailto: link must still
    /// reach the question and name the frame's site. (A nil source frame, which is what traps on older macOS, can't be made on this one;
    /// the `sourceHost: nil` case in `externalQuestionNamesTheClickingFrame` covers the fallback.)
    /// R1-4: the KVC read itself. The raw `NavigationRequest` made from a real clicked-link action must carry the clicking frame's host. This
    /// is checked on the request, not through the question, because the question falls back to the top page's host when the read gives nil
    /// (which would hide a broken read); with the read returning nil this test sees nil.
    @Test func realClickedLinkActionCarriesTheFramesHost() async throws {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        let webView = WKWebView(frame: .zero, configuration: configuration)
        let recorder = ActionRecorder()
        webView.navigationDelegate = recorder
        webView.loadHTMLString("<title>T</title>", baseURL: URL(string: "https://frame.example.net/"))
        let loaded = try await waitUntil { recorder.finishedLoads == 1 }
        #expect(loaded)
        _ = try await webView.evaluateJavaScript("var a = document.createElement('a'); a.href = 'mailto:a@example.com'; document.body.appendChild(a); a.click(); 1")
        let seen = try await waitUntil { recorder.mailtoHosts.count == 1 }
        #expect(seen)
        #expect(recorder.mailtoHosts.first == .some("frame.example.net"))
    }

    @Test func clickedMailtoNamesTheFrameThroughKVC() async throws {
        let host = makeHost()
        let apps = FakeExternalApps()
        apps.app = URL(fileURLWithPath: "/System/Applications/Mail.app")
        host.externalApps = apps.seam
        let page = host.page(for: request(), writer: writer)
        page.webView.loadHTMLString("<title>T</title>", baseURL: URL(string: "https://www.example.com/"))
        let loaded = try await waitUntil { page.status.title == "T" && !page.webView.isLoading }
        #expect(loaded)
        _ = try await page.webView.evaluateJavaScript("var a = document.createElement('a'); a.href = 'mailto:a@example.com'; document.body.appendChild(a); a.click(); 1")
        let asked = try await waitUntil { !events.externalQuestions.isEmpty }
        #expect(asked)
        #expect(events.externalAskers.last?.host == "example.com")
        host.close(page.tabID)
    }
}

/// Records what `NavigationRequest` reads from each real navigation action to a `mailto:` link, and cancels it.
@MainActor
private final class ActionRecorder: NSObject, WKNavigationDelegate {
    var mailtoHosts: [String?] = []
    var finishedLoads = 0

    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction) async -> WKNavigationActionPolicy {
        guard navigationAction.request.url?.scheme == "mailto" else { return .allow }
        mailtoHosts.append(NavigationRequest(navigationAction).sourceHost)
        return .cancel
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) { finishedLoads += 1 }
}

/// `onChange` runs on whichever thread made the change; the tests change on the main actor, where it runs at once.
private final class FireCounter: @unchecked Sendable {
    var count = 0
}

@MainActor
private final class DoneFlag {
    var isSet = false
}

@MainActor
extension WebKitTests.PageHostTests {
    /// Runs `work` on its own task and waits for it with the generous event-driven wait, so a call that never returns fails the test
    /// instead of hanging it.
    private func finishes(_ work: @escaping @MainActor () async -> Void) async throws -> Bool {
        let done = DoneFlag()
        Task { @MainActor in
            await work()
            done.isSet = true
        }
        return try await waitUntil { done.isSet }
    }

    /// The host's events for tests that read what it told the app.
    private func hostWithEvents() -> (PageHost, FakeEvents) {
        let host = makeHost()
        let events = FakeEvents()
        host.events = events
        events.host = host
        return (host, events)
    }

    /// Hibernation unloads the page and the app's real queues drop what the page had waiting: a dialog or an external-app question for the
    /// hidden tab ends with its safe answer, never shown over a page that is gone. (Wires the host to `PageQuestionQueues.cancel`, which
    /// covers the two kinds Task 15 added; the host's own call into `cancelWaitingQuestions` is older.)
    @Test func hibernationForgetsPrompts() async throws {
        let host = makeHost()
        let queues = PageQuestionQueues()
        let (_, events) = (host, FakeEvents())
        events.onCancelWaiting = { queues.cancel(tabID: $0) }
        host.events = events
        let idle = host.page(for: request(url: ""), writer: writer)
        let shown = host.page(for: request(url: ""), writer: writer)
        host.markShown(shown.tabID, true)
        host.mediaCheck = { _ in false }
        let idleID = idle.tabID
        let dialog = Task { await queues.askDialog(tabID: idleID, request: DialogRequest(kind: .confirm, origin: nil, message: "m", offerToStop: false), isStale: { false }) }
        let external = Task { await queues.askExternalApp(tabID: idleID, host: nil, url: URL(string: "mailto:a@example.com")!, appName: "Mail", isStale: { false }) }
        await Task.yield()
        clock.date += HibernationPolicy.idleLimit + 1
        await host.hibernateIdle()
        #expect(host.existingPage(idleID) == nil)
        var results: (DialogReply?, Bool?)?
        let answered = try await finishes { results = await (dialog.value, external.value) }
        #expect(answered, "the waiting questions end when the page is unloaded")
        #expect(results?.0 == nil)
        #expect(results?.1 == nil)
        #expect(events.cancelledTabs == [idleID], "only the unloaded page's questions are dropped")
        host.close(shown.tabID)
    }

    /// Pop-ups are read after every media check has finished: a pop-up opened while a later page was being checked still keeps its opener.
    /// Each read is recorded with how many checks had finished, so the guard before the unload can't hide a read made too early.
    @Test func hibernationReadsPopupsAfterTheMediaChecks() async {
        let host = makeHost()
        let a = host.page(for: request(url: ""), writer: writer)
        let b = host.page(for: request(url: ""), writer: writer)
        var finished = 0
        var readsAt: [Int] = []
        host.mediaCheck = { _ in
            finished += 1
            return false
        }
        host.hasOpenPopups = { _ in
            readsAt.append(finished)
            return true
        }
        clock.date += HibernationPolicy.idleLimit + 1
        await host.hibernateIdle()
        #expect(finished == 2)
        #expect(!readsAt.isEmpty && readsAt.allSatisfy { $0 == 2 }, "every pop-up read comes after both checks: \(readsAt)")
        #expect(host.existingPage(a.tabID) === a)
        #expect(host.existingPage(b.tabID) === b)
        host.close(a.tabID)
        host.close(b.tabID)
    }

    /// A pop-up opened while the checks ran, for a page that was already checked, is read at the end too, right before the unload.
    @Test func hibernationRechecksPopupsRightBeforeUnloading() async {
        let host = makeHost()
        let page = host.page(for: request(url: ""), writer: writer)
        host.mediaCheck = { _ in false }
        var reads = 0
        host.hasOpenPopups = { _ in
            reads += 1
            // Closed at the first read, open at the second: the unload must not go ahead on the first answer.
            return reads >= 2
        }
        clock.date += HibernationPolicy.idleLimit + 1
        await host.hibernateIdle()
        #expect(reads >= 2)
        #expect(host.existingPage(page.tabID) === page)
        host.close(page.tabID)
    }

    /// H2: a hidden page blocked in a real `alert()` that nobody answers. Hibernation neither asks it about media (WebKit may never answer
    /// a page whose script is stopped there) nor unloads it, and it returns. The media-check seam only records which pages are asked, so an ask of the blocked page would show.
    @Test func hibernationSkipsAPageBlockedInADialog() async throws {
        let (host, events) = hostWithEvents()
        events.holdAlerts = true
        let blocked = host.page(for: request(url: ""), writer: writer)
        blocked.webView.loadHTMLString("<title>T</title><script>setTimeout(function(){ alert('stuck') }, 0)</script>", baseURL: URL(string: "https://example.com/"))
        let asked = try await waitUntil { events.heldAlerts.count == 1 }
        #expect(asked)
        let other = host.page(for: request(url: ""), writer: writer)
        var checked: [WKWebView] = []
        host.mediaCheck = { webView in
            checked.append(webView)
            return false
        }
        clock.date += HibernationPolicy.idleLimit + 1
        let returned = try await finishes { await host.hibernateIdle() }
        #expect(returned, "hibernation returns although a page is blocked in alert()")
        #expect(!checked.contains { $0 === blocked.webView }, "a page with a dialog waiting is not asked about media")
        #expect(host.existingPage(blocked.tabID) === blocked, "and it is not hibernated")
        #expect(host.existingPage(other.tabID) == nil, "other pages still are")
        events.releaseAlerts()
        host.close(blocked.tabID)
    }

    /// H2: a media check that never answers is cut off after the limit (small here); the page counts as busy and the other pages' checks
    /// still count. The limit is injected, and nothing here depends on how fast WebKit answers.
    @Test func hibernationCutsOffAMediaCheckThatNeverAnswers() async throws {
        let host = makeHost()
        host.mediaCheckLimit = .milliseconds(20)
        let stuck = host.page(for: request(url: ""), writer: writer)
        let idle = host.page(for: request(url: ""), writer: writer)
        let stuckView = stuck.webView
        host.mediaCheck = { webView in
            if webView === stuckView { await withCheckedContinuation { (_: CheckedContinuation<Void, Never>) in } }
            return false
        }
        clock.date += HibernationPolicy.idleLimit + 1
        let returned = try await finishes { await host.hibernateIdle() }
        #expect(returned, "hibernation returns although one check never answers")
        #expect(host.existingPage(stuck.tabID) === stuck, "a check that timed out counts as busy")
        #expect(host.existingPage(idle.tabID) == nil, "one stuck page doesn't stall the others")
        host.close(stuck.tabID)
    }

    /// R1-6: a page whose earlier media check never returned is not asked again; checks don't pile up round after round.
    @Test func hibernationDoesNotAskAgainWhileAnEarlierCheckIsOut() async throws {
        let host = makeHost()
        host.mediaCheckLimit = .milliseconds(20)
        let stuck = host.page(for: request(url: ""), writer: writer)
        var asked = 0
        host.mediaCheck = { _ in
            asked += 1
            await withCheckedContinuation { (_: CheckedContinuation<Void, Never>) in }
            return false
        }
        clock.date += HibernationPolicy.idleLimit + 1
        let first = try await finishes { await host.hibernateIdle() }
        let second = try await finishes { await host.hibernateIdle() }
        #expect(first && second)
        #expect(asked == 1, "the second round skips the page whose check is still out")
        #expect(host.existingPage(stuck.tabID) === stuck, "and it counts as busy")
        host.close(stuck.tabID)
    }

    /// H3: the host writes only a tab's pending title before the store archives it, and nothing else.
    @Test func flushTitleWritesOnlyTheTitle() {
        let host = makeHost()
        host.titleScheduler = { _, _ in }
        let page = host.page(for: request(url: ""), writer: writer)
        page.record(.committed(url: "https://example.com/"))
        page.record(.title("Late"))
        let before = writer.calls.count
        host.flushTitle(page.tabID)
        #expect(navigations(writer) == ["", "Late"])
        #expect(writer.calls.count == before + 1)
        host.flushTitle(UUID()) // unknown tab: no-op
        host.close(page.tabID)
    }

    /// L2: the trailing title write doesn't also flush the throttled `interactionState` ahead of its own limit.
    @Test func trailingTitleWriteLeavesInteractionStateAlone() {
        let host = makeHost()
        var scheduled: [@MainActor () -> Void] = []
        host.titleScheduler = { _, work in scheduled.append(work) }
        let page = host.page(for: request(url: ""), writer: writer)
        page.record(.committed(url: "https://example.com/"))
        page.record(.stateChanged)
        page.record(.stateChanged)
        page.record(.title("A"))
        let statesBefore = writer.calls.filter { if case .interactionState = $0 { true } else { false } }.count
        clock.date += PageRecorder.titleInterval
        scheduled.removeFirst()()
        let statesAfter = writer.calls.filter { if case .interactionState = $0 { true } else { false } }.count
        #expect(navigations(writer) == ["", "A"])
        #expect(statesAfter == statesBefore, "the trailing write is only the title")
        host.close(page.tabID)
    }

    // MARK: Coalesced title writes

    private func navigations(_ writer: FakeWriter) -> [String] {
        writer.calls.compactMap { if case .navigation(_, _, let title, _) = $0 { title } else { nil } }
    }

    /// At most one title write per 500 ms: the page asks its scheduler for one trailing write (never one per title), the scheduled write
    /// carries the latest title, and nothing sleeps (the scheduler and the clock are the test's).
    @Test func titleWritesCoalescedThroughThePage() {
        let host = makeHost()
        var scheduled: [(delay: TimeInterval, work: @MainActor () -> Void)] = []
        host.titleScheduler = { delay, work in scheduled.append((delay, work)) }
        let page = host.page(for: request(url: ""), writer: writer)
        page.record(.committed(url: "https://example.com/"))
        #expect(navigations(writer) == [""])
        page.record(.title("A"))
        page.record(.title("B"))
        page.record(.title("C"))
        #expect(navigations(writer) == [""], "the burst writes nothing yet")
        #expect(scheduled.count == 1, "one trailing write is asked for, not one per title")
        #expect(abs((scheduled.first?.delay ?? 0) - PageRecorder.titleInterval) < 0.001)

        clock.date += PageRecorder.titleInterval
        scheduled.removeFirst().work()
        #expect(navigations(writer) == ["", "C"])
        // The burst is over: a later title is a new one, and a title inside the next window is held again.
        page.record(.title("D"))
        #expect(navigations(writer) == ["", "C"])
        #expect(scheduled.count == 1)
        host.close(page.tabID)
    }

    /// A scheduled write that arrives after something else already wrote the title (a flush) does nothing, and one after the page closed
    /// does nothing either.
    @Test func lateTitleFlushDoesNothing() {
        let host = makeHost()
        var scheduled: [@MainActor () -> Void] = []
        host.titleScheduler = { _, work in scheduled.append(work) }
        let page = host.page(for: request(url: ""), writer: writer)
        page.record(.committed(url: "https://example.com/"))
        page.record(.title("A"))
        host.flush(page.tabID)
        #expect(navigations(writer) == ["", "A"])
        scheduled.removeFirst()()
        #expect(navigations(writer) == ["", "A"])
        page.record(.title("B"))
        host.close(page.tabID)
        scheduled.removeFirst()()
        #expect(navigations(writer) == ["", "A"], "a closed page writes nothing")
    }

    /// Deselecting a tab flushes that tab only: another tab's pending state stays pending.
    @Test func flushingOneTabLeavesTheOthersPending() {
        let host = makeHost()
        host.titleScheduler = { _, _ in }
        let a = host.page(for: request(url: ""), writer: writer)
        let b = host.page(for: request(url: ""), writer: writer)
        for page in [a, b] {
            page.record(.committed(url: "https://example.com/\(page.tabID)"))
            page.record(.title("T"))
        }
        func titles(of tab: UUID) -> [String] {
            writer.calls.compactMap { if case .navigation(tab, _, let title, _) = $0 { title } else { nil } }
        }
        #expect(titles(of: a.tabID) == [""] && titles(of: b.tabID) == [""])
        host.flush(a.tabID)
        #expect(titles(of: a.tabID) == ["", "T"])
        #expect(titles(of: b.tabID) == [""], "the other tab is not flushed")
        host.flush(UUID()) // an unknown tab is a no-op
        host.close(a.tabID)
        host.close(b.tabID)
    }

    /// Unloading flushes the title too (window close and quit unload or flush every page).
    @Test func unloadAndFlushAllWriteAPendingTitle() {
        let host = makeHost()
        host.titleScheduler = { _, _ in }
        let a = host.page(for: request(url: ""), writer: writer)
        let b = host.page(for: request(url: ""), writer: writer)
        for page in [a, b] {
            page.record(.committed(url: "https://example.com/\(page.tabID)"))
            page.record(.title("T"))
        }
        host.unload(a.tabID)
        #expect(navigations(writer).filter { $0 == "T" }.count == 1)
        host.flushAll()
        #expect(navigations(writer).filter { $0 == "T" }.count == 2)
        host.close(b.tabID)
    }

    // MARK: The menu's fields

    /// The menus read only `menuFields`: a title, progress or other status change that no menu item reads doesn't invalidate them.
    @Test func menuFieldsIgnoreTitleAndProgress() {
        let host = makeHost()
        let page = host.page(for: request(url: ""), writer: writer)
        let fired = FireCounter()
        withObservationTracking { _ = page.menuFields } onChange: { fired.count += 1 }
        page.status.title = "A title"
        page.status.progress = 0.5
        #expect(fired.count == 0)
        #expect(page.menuFields == PageMenuFields(isLoading: false, canGoBack: false, canGoForward: false, url: "", hasFailure: false))
        page.status.canGoBack = true
        #expect(fired.count == 1)
        #expect(page.menuFields.canGoBack)
        // Each field the menu reads does invalidate it.
        for change in [
            { page.status.isLoading = true }, { page.status.canGoForward = true }, { page.status.url = "https://example.com/" },
            { page.status.failure = .crashed },
        ] as [() -> Void] {
            let changed = FireCounter()
            withObservationTracking { _ = page.menuFields } onChange: { changed.count += 1 }
            change()
            #expect(changed.count == 1)
        }
        host.close(page.tabID)
    }
}
