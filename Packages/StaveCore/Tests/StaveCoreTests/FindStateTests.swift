import Foundation
import Testing
@testable import StaveCore

@Suite("Find state")
struct FindStateTests {
    /// ⌘F shows the bar, typing sets the query, Return and ⇧Return search forwards and back, Escape hides the bar and keeps the query, so
    /// ⌘G finds it again with the bar closed, as Safari does.
    @Test func findStateTransitions() {
        var state = FindState()
        #expect(!state.isVisible && state.query.isEmpty && state.result == nil)
        #expect(state.findNext(backwards: false) == nil) // nothing to find yet
        #expect(!state.canFindAgain)

        state.show()
        #expect(state.isVisible)
        state.setQuery("alpha")
        #expect(state.query == "alpha")
        #expect(state.canFindAgain)
        #expect(state.findNext(backwards: false) == FindSearch(query: "alpha", backwards: false))
        state.record(.found)
        #expect(state.result == .found)
        #expect(state.statusText == nil)
        #expect(state.findNext(backwards: true) == FindSearch(query: "alpha", backwards: true))
        state.record(.notFound)
        #expect(state.statusText == FindText.notFound)

        // A changed query forgets the old outcome.
        state.setQuery("alph")
        #expect(state.result == nil)

        // Escape: the bar hides, the query stays, the outcome goes.
        state.hide()
        #expect(!state.isVisible)
        #expect(state.query == "alph")
        #expect(state.result == nil)
        #expect(state.statusText == nil)

        // ⌘G with the bar closed shows it again and finds the kept query.
        #expect(state.findNext(backwards: false) == FindSearch(query: "alph", backwards: false))
        #expect(state.isVisible)

        // An empty query finds nothing and leaves the bar as it is.
        state.setQuery("")
        #expect(state.findNext(backwards: false) == nil)
        #expect(!state.canFindAgain)
    }

    /// A late answer for an older query is dropped: the bar never says "Not found" for text it no longer holds.
    @Test func staleOutcomeIgnored() {
        var state = FindState()
        state.show()
        state.setQuery("al")
        state.setQuery("alpha")
        state.record(.notFound, for: "al")
        #expect(state.result == nil)
        state.record(.notFound, for: "alpha")
        #expect(state.result == .notFound)
    }

    /// ⌘E puts the page's selection in the query without showing the bar; an empty or blank selection changes nothing; a huge one is capped.
    @Test func useSelectionForFind() {
        var state = FindState()
        state.useSelection("beta")
        #expect(state.query == "beta")
        #expect(!state.isVisible)
        #expect(state.findNext(backwards: false) == FindSearch(query: "beta", backwards: false))
        state.record(.found)

        state.useSelection("gamma")
        #expect(state.query == "gamma")
        #expect(state.result == nil)

        state.useSelection("")
        state.useSelection("  \n\t ")
        #expect(state.query == "gamma")

        state.useSelection(String(repeating: "x", count: 100_000))
        #expect(state.query.count == FindState.maxQueryLength)
        state.setQuery(String(repeating: "y", count: 100_000))
        #expect(state.query.count == FindState.maxQueryLength)
    }

    /// Find needs a page the user can see: off with no page, a sheet up, or the History view in place of the page; Find Again also needs a
    /// query.
    @Test func findMenuFollowsThePage() {
        let page = PageStatusSummary(hasPage: true)
        let free = PageMenuState.from(status: page, sheetOpen: false)
        #expect(free.canFind)
        #expect(!PageMenuState.from(status: nil, sheetOpen: false).canFind)
        #expect(!PageMenuState.from(status: page, sheetOpen: true).canFind)
        #expect(!PageMenuState.from(status: page, sheetOpen: false, historyShown: true).canFind)
        #expect(!PageMenuState.disabled.canFind)

        var state = FindState()
        #expect(FindMenuState.from(pageMenu: free, find: state) == FindMenuState(canFind: true, canFindAgain: false, canUseSelection: true))
        state.setQuery("alpha")
        #expect(FindMenuState.from(pageMenu: free, find: state) == FindMenuState(canFind: true, canFindAgain: true, canUseSelection: true))
        #expect(FindMenuState.from(pageMenu: .disabled, find: state) == .disabled)
    }

    /// The bar is per tab, as in Safari, Chrome and Firefox; the last query is shared, so a bar opened in another tab starts with it.
    @Test func findBarsArePerTab() {
        let first = UUID()
        let second = UUID()
        var sessions = FindSessions()
        sessions.update(first) { $0.show(); $0.setQuery("alpha") }
        #expect(sessions.state(for: first).isVisible)
        #expect(!sessions.state(for: second).isVisible)
        #expect(sessions.state(for: second).query == "alpha")

        sessions.update(second) { $0.show(); $0.setQuery("beta") }
        #expect(sessions.state(for: first).query == "alpha")
        #expect(sessions.lastQuery == "beta")

        sessions.update(first) { $0.hide() }
        #expect(!sessions.state(for: first).isVisible)
        // Escape keeps the hidden bar's text for ⌘G: it becomes the window's last text.
        #expect(sessions.state(for: first).query == "alpha")
        #expect(sessions.lastQuery == "alpha")

        sessions.forget(second)
        #expect(!sessions.state(for: second).isVisible)
        #expect(sessions.state(for: nil) == FindState(query: "alpha"))
    }

    @Test func findText() {
        #expect(FindText.notFound == "Not found")
    }
}
