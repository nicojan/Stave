import AppKit
import Observation
import StaveCore
import StaveWeb
import WebKit

/// A pop-up a page opened with `window.open` and a size: its own small window around a web view WebKit made from the opener's
/// configuration. Its page is a `PageHost` page under a fresh ID that is no store tab (its writer drops every write), so a pop-up is never
/// saved or restored and never in `WindowSession`. It closes when the page calls `window.close()`, when its opener's page goes, or when the
/// user closes it; its page is closed with it.
@MainActor
final class PopupWindowController: NSObject, NSWindowDelegate {
    let id: UUID
    /// The sidebar tab that opened it (through any chain of pop-ups); links from the pop-up go below this tab (decision 6).
    let openerTabID: UUID
    let window: NSWindow
    let prompts: PagePrompts
    private let page: LivePage
    private let pageHost: PageHost
    private let onClose: (PopupWindowController) -> Void
    private(set) var isClosed = false

    init(id: UUID, openerTabID: UUID, page: LivePage, features: WKWindowFeatures, near parent: NSWindow?, pageHost: PageHost, onClose: @escaping (PopupWindowController) -> Void) {
        self.id = id
        self.openerTabID = openerTabID
        self.page = page
        self.pageHost = pageHost
        self.onClose = onClose
        let screen = parent?.screen ?? NSScreen.main
        let visible = screen?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1280, height: 800)
        let size = PopupFrame.size(width: features.width?.doubleValue, height: features.height?.doubleValue, visibleFrame: visible)
        window = NSWindow(
            contentRect: NSRect(origin: .zero, size: size),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered, defer: false
        )
        prompts = PagePrompts(window: window, pageHost: pageHost, shows: { [id] tabID in tabID == id })
        super.init()
        window.isReleasedWhenClosed = false
        window.isRestorable = false
        window.tabbingMode = .disallowed
        window.delegate = self
        window.contentView = page.webView
        place(near: parent, visible: visible)
        updateTitle()
        observeTitle()
    }

    func show() {
        window.makeKeyAndOrderFront(nil)
        window.makeFirstResponder(page.webView)
    }

    /// Closes the window (and with it the page).
    func close() {
        guard !isClosed else { return }
        window.close()
    }

    /// Centred over the opener's window, kept on its screen.
    private func place(near parent: NSWindow?, visible: NSRect) {
        guard let parent else {
            window.center()
            return
        }
        let size = window.frame.size
        var origin = NSPoint(x: parent.frame.midX - size.width / 2, y: parent.frame.midY - size.height / 2)
        origin.x = min(max(origin.x, visible.minX), visible.maxX - size.width)
        origin.y = min(max(origin.y, visible.minY), visible.maxY - size.height)
        window.setFrameOrigin(origin)
    }

    private func updateTitle() {
        window.title = PopupFrame.title(pageTitle: page.status.title, url: page.status.url)
    }

    private func observeTitle() {
        withObservationTracking {
            _ = page.status.title
            _ = page.status.url
        } onChange: { [weak self] in
            Task { @MainActor in
                guard let self, !self.isClosed else { return }
                self.updateTitle()
                self.observeTitle()
            }
        }
    }

    // MARK: - NSWindowDelegate

    func windowWillClose(_ notification: Notification) {
        guard !isClosed else { return }
        isClosed = true
        prompts.close()
        pageHost.close(id)
        onClose(self)
    }
}

extension PopupWindowController {
    /// A sized `window.open`: a pop-up window around the web view WebKit made. The view is adopted (the delegate refuses an unadopted one)
    /// under a fresh page ID that is no store tab, with the opener's data store and profile (none for a private page); its writer drops
    /// every write. It is registered under its opener tab, whose page going closes it.
    static func open(opener: UUID, webView: WKWebView, features: WKWindowFeatures, near parent: NSWindow?, environment: AppEnvironment) {
        guard let openerPage = environment.pageHost.existingPage(opener) else { return }
        let id = UUID()
        let request = PageRequest(
            tabID: id, store: openerPage.store, siteSettingsProfileID: openerPage.siteSettingsProfileID,
            url: "", title: "", faviconURL: nil, interactionState: nil
        )
        let page = environment.pageHost.adopt(webView, as: request, writer: environment.popupWriter)
        environment.pageHost.markShown(id, true)
        let popups = environment.popups
        let popup = PopupWindowController(
            id: id, openerTabID: popups.openerTab(of: opener), page: page, features: features, near: parent,
            pageHost: environment.pageHost, onClose: { closed in popups.remove(closed) }
        )
        popups.add(popup)
        popup.show()
    }
}

/// Every open pop-up, by the sidebar tab that opened it. App-wide: an opener tab may move between windows.
@MainActor
final class PopupRegistry {
    private var byOpener: [UUID: [PopupWindowController]] = [:]

    func add(_ popup: PopupWindowController) {
        byOpener[popup.openerTabID, default: []] = byOpener[popup.openerTabID, default: []] + [popup]
    }

    func remove(_ popup: PopupWindowController) {
        let kept = (byOpener[popup.openerTabID] ?? []).filter { $0 !== popup }
        byOpener[popup.openerTabID] = kept.isEmpty ? nil : kept
    }

    /// Whether the tab (or pop-up) opened pop-ups that are still open; such a page is kept from hibernating (ruling R14).
    func hasPopups(openedBy tabID: UUID) -> Bool {
        !(byOpener[tabID] ?? []).isEmpty
    }

    func popup(_ id: UUID) -> PopupWindowController? {
        byOpener.values.lazy.flatMap { $0 }.first { $0.id == id }
    }

    var all: [PopupWindowController] { byOpener.values.flatMap { $0 } }

    /// The sidebar tab behind `id`: the opener tab of a pop-up, else `id` itself.
    func openerTab(of id: UUID) -> UUID {
        popup(id)?.openerTabID ?? id
    }

    /// The opener's page went (closed, unloaded, reset): its pop-ups close with it.
    func closeAll(openedBy tabID: UUID) {
        for popup in byOpener[tabID] ?? [] { popup.close() }
    }
}
