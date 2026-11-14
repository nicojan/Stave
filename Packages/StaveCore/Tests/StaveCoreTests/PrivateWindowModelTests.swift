import Foundation
import GRDB
import Testing
@testable import StaveCore

@MainActor
struct PrivateWindowModelTests {
    /// Records what the model tells the page host.
    @MainActor private final class Pages: PageLifecycle {
        var closed: [UUID] = []
        var deselected: [UUID] = []
        func tabClosed(_ id: UUID) { closed.append(id) }
        func tabUnloaded(_ id: UUID) {}
        func tabDeselected(_ id: UUID) { deselected.append(id) }
        func tabNavigated(_ id: UUID) {}
    }

    @Test func privateTabsLiveInMemoryOnly() throws {
        let (store, database, _) = try makeTempStore()
        _ = try store.ensureDefaultProfile()
        let model = PrivateWindowModel()
        let first = model.open(url: "https://example.com/one", below: nil, select: true)
        let middle = model.open(url: "https://example.com/two", below: first, select: true)
        _ = model.open(url: "https://example.com/three", below: middle, select: false)
        model.close(middle)
        model.update(first, url: "https://example.com/one#top", title: "One")

        #expect(model.tabs.count == 2)
        #expect(model.tabs.first?.title == "One")
        let counts = try database.writer.read { db in (tabs: try Tab.fetchCount(db), archived: try ArchivedTab.fetchCount(db)) }
        #expect(counts.tabs == 0)
        #expect(counts.archived == 0)
    }

    @Test func linkOpensBelowOpener() {
        let model = PrivateWindowModel(newTabEdge: .top)
        let a = model.open(url: "https://example.com/a", below: nil, select: true)
        let b = model.open(url: "https://example.com/b", below: nil, select: true)
        // b went to the top edge; a link from a lands directly below a, not at the edge.
        let link = model.open(url: "https://example.com/link", below: a, select: false)
        #expect(model.tabs.map(\.id) == [b, a, link])
        #expect(model.selectedTabID == b)
        let selectedLink = model.open(url: "https://example.com/link2", below: b, select: true)
        #expect(model.tabs.map(\.id) == [b, selectedLink, a, link])
        #expect(model.selectedTabID == selectedLink)
    }

    @Test func linkFromAMissingOpenerGoesToTheEdge() {
        let model = PrivateWindowModel(newTabEdge: .bottom)
        let a = model.open(url: "https://example.com/a", below: nil, select: true)
        let orphan = model.open(url: "https://example.com/b", below: UUID(), select: false)
        #expect(model.tabs.map(\.id) == [a, orphan])
    }

    @Test func closeSelectsBelowThenAbove() {
        let pages = Pages()
        let model = PrivateWindowModel(newTabEdge: .bottom)
        model.pages = pages
        let a = model.open(url: "https://example.com/a", below: nil, select: false)
        let b = model.open(url: "https://example.com/b", below: nil, select: false)
        let c = model.open(url: "https://example.com/c", below: nil, select: false)
        model.select(b)
        model.close(b)
        #expect(model.selectedTabID == c)
        model.close(c)
        #expect(model.selectedTabID == a)
        model.close(a)
        #expect(model.selectedTabID == nil)
        #expect(model.tabs.isEmpty)
        #expect(pages.closed == [b, c, a])
        // Closing an unselected tab leaves the selection alone.
        let d = model.open(url: "https://example.com/d", below: nil, select: true)
        let e = model.open(url: "https://example.com/e", below: nil, select: false)
        model.close(e)
        #expect(model.selectedTabID == d)
    }

    @Test func selectingAnotherTabDeselectsTheOld() {
        let pages = Pages()
        let model = PrivateWindowModel()
        model.pages = pages
        let a = model.open(url: "https://example.com/a", below: nil, select: true)
        let b = model.open(url: "https://example.com/b", below: nil, select: false)
        model.select(b)
        model.select(b)
        model.select(UUID()) // not a tab: ignored
        #expect(model.selectedTabID == b)
        #expect(pages.deselected == [a])
    }

    @Test func updateOfAClosedTabIsDropped() {
        let model = PrivateWindowModel()
        let a = model.open(url: "https://example.com/a", below: nil, select: true)
        model.close(a)
        model.update(a, url: "https://example.com/late", title: "Late")
        #expect(model.tabs.isEmpty)
    }

    @Test func privateCommandBarHasOnlyTypedRow() {
        let model = PrivateWindowModel()
        _ = model.open(url: "https://example.com/exam", below: nil, select: true)
        let bar = CommandBarModel(mode: .newTab, candidates: model.commandCandidates, currentURL: nil)
        bar.query = "exam"
        #expect(bar.results == [.search(query: "exam")])
        bar.query = ""
        #expect(bar.results.isEmpty)
    }

    @Test func typedAddressIsNormalisedAndLoadedTyped() {
        let model = PrivateWindowModel()
        var loads: [(UUID, String)] = []
        model.loadTyped = { id, url in loads.append((id, url)); return true }
        let bar = CommandBarModel(mode: .newTab, candidates: model.commandCandidates, currentURL: nil)
        bar.query = "localhost:3000"
        #expect(bar.activate(in: model) == .close(.done))
        let tab = model.selectedTab
        #expect(tab?.url == "http://localhost:3000")
        #expect(loads.count == 1)
        #expect(loads.first?.0 == tab?.id)
        #expect(loads.first?.1 == "http://localhost:3000")
    }

    @Test func currentTabAddressGoesToThatTab() {
        let model = PrivateWindowModel()
        var loaded = false
        model.loadTyped = { _, _ in loaded = true; return true }
        let a = model.open(url: "https://example.com/a", below: nil, select: true)
        let bar = CommandBarModel(
            mode: .currentTab, candidates: model.commandCandidates, currentURL: model.selectedTab?.url, currentTabID: model.selectedTabID
        )
        bar.query = "example.org"
        _ = bar.activate(in: model)
        #expect(model.tabs.count == 1)
        #expect(loaded)
        // No page took it: the model keeps the address, so the page made later loads it.
        model.loadTyped = { _, _ in false }
        let second = CommandBarModel(mode: .currentTab, candidates: model.commandCandidates, currentURL: nil, currentTabID: a)
        second.query = "example.net"
        _ = second.activate(in: model)
        #expect(model.selectedTab?.url == "https://example.net")
    }

    @Test func searchWithNoEngineAsksAndKeepsTheChoiceInMemory() {
        let model = PrivateWindowModel(searchEngine: nil)
        let bar = CommandBarModel(mode: .newTab, candidates: model.commandCandidates, currentURL: nil)
        bar.query = "exam"
        #expect(bar.activate(in: model) == .stay)
        #expect(bar.isChoosingEngine)
        bar.selectEngine(at: SearchEngine.allCases.firstIndex(of: .duckDuckGo) ?? 0)
        #expect(bar.activate(in: model) == .close(.done))
        #expect(model.searchEngine == .duckDuckGo)
        #expect(model.selectedTab?.url == SearchEngine.duckDuckGo.searchURL(for: "exam"))
    }

    @Test func searchWithAnEngineOpensItsPage() {
        let model = PrivateWindowModel(searchEngine: .kagi)
        let bar = CommandBarModel(mode: .newTab, candidates: model.commandCandidates, currentURL: nil, searchEngine: model.searchEngine)
        bar.query = "exam"
        #expect(bar.activate(in: model) == .close(.done))
        #expect(model.selectedTab?.url == SearchEngine.kagi.searchURL(for: "exam"))
    }
}
