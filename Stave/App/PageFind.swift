import AppKit
import Observation
import StaveCore
import StaveWeb

/// One window's find in page (decision 11): Stave's own bar above the page, with WebKit's public find. Every rule (what shows, what a key
/// does, when a late answer is dropped) is `FindState`'s and `FindSessions`'; this runs the searches and moves the focus.
/// The Task 8 spike found that WKWebView answers no `performTextFinderAction(_:)`, so the system find bar isn't available.
@MainActor @Observable
final class PageFind {
    private(set) var sessions = FindSessions()
    /// Bumped each time a bar's field should take the keyboard (⌘F), after the window took it from the page.
    private(set) var fieldFocus = 0
    /// The tab whose bar should take the keyboard, until that bar takes it (`takeFocus`). A bar shown again by a tab switch doesn't.
    @ObservationIgnored private var focusPending: UUID?

    @ObservationIgnored private weak var window: NSWindow?
    @ObservationIgnored private let shownPage: () -> LivePage?
    @ObservationIgnored private let focusPage: (UUID) -> Void

    init(window: NSWindow, shownPage: @escaping () -> LivePage?, focusPage: @escaping (UUID) -> Void) {
        self.window = window
        self.shownPage = shownPage
        self.focusPage = focusPage
    }

    /// The bar of the page this window shows (hidden with the last text when there is none), for the menus.
    var current: FindState { sessions.state(for: shownPage()?.tabID) }

    func state(for tabID: UUID) -> FindState { sessions.state(for: tabID) }

    // MARK: - Menu commands (the key window's shown page)

    /// ⌘F: shows the shown page's bar and puts the keyboard in its field.
    func show() {
        guard let tabID = shownPage()?.tabID else { return }
        sessions.update(tabID) { $0.show() }
        window?.makeFirstResponder(nil) // the web view keeps the keyboard otherwise; the field takes it on the next turn
        focusPending = tabID
        fieldFocus += 1
    }

    /// True once after ⌘F for that tab's bar, which then focuses its field.
    func takeFocus(for tabID: UUID) -> Bool {
        guard focusPending == tabID else { return false }
        focusPending = nil
        return true
    }

    /// ⌘G and ⇧⌘G: finds the kept text again, showing the bar.
    func findAgain(backwards: Bool) {
        guard let tabID = shownPage()?.tabID else { return }
        findNext(in: tabID, backwards: backwards)
    }

    /// ⌘E: the page's selection becomes the text; a shown bar searches for it at once.
    func useSelection() {
        guard let page = shownPage() else { return }
        let tabID = page.tabID
        Task { @MainActor [weak self, weak page] in
            guard let page, let text = await PageTools.selectedText(in: page.webView), let self else { return }
            self.sessions.update(tabID) { $0.useSelection(text) }
            if self.sessions.state(for: tabID).isVisible { self.findNext(in: tabID, backwards: false) }
        }
    }

    // MARK: - The bar

    /// Typing searches as it goes, as in Safari; an emptied field just clears the outcome.
    func setQuery(_ text: String, in tabID: UUID) {
        let before = sessions.state(for: tabID).query
        sessions.update(tabID) { $0.setQuery(text) }
        guard sessions.state(for: tabID).query != before else { return }
        findNext(in: tabID, backwards: false)
    }

    /// Return, ⇧Return and the bar's arrows.
    func findNext(in tabID: UUID, backwards: Bool) {
        var search: FindSearch?
        sessions.update(tabID) { search = $0.findNext(backwards: backwards) }
        guard let search, let page = shownPage(), page.tabID == tabID else { return }
        Task { @MainActor [weak self, weak page] in
            guard let page else { return }
            let outcome = await PageTools.find(search.query, backwards: search.backwards, in: page.webView)
            guard let self, self.sessions.state(for: tabID).isVisible else { return }
            self.sessions.update(tabID) { $0.record(outcome, for: search.query) }
        }
    }

    /// Escape and Done: the bar goes, its text stays for ⌘G, and the keyboard goes back to the page.
    func hide(in tabID: UUID) {
        sessions.update(tabID) { $0.hide() }
        focusPage(tabID)
    }

    /// The tab closed: its bar goes with it.
    func forget(_ tabID: UUID) { sessions.forget(tabID) }
}
