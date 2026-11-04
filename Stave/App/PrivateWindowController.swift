import AppKit
import Observation
import StaveCore
import StaveWeb
import SwiftUI
import WebKit

/// Owns one private window (⇧⌘N, plan 3 decision 15): a `PrivateWindowModel` in memory, its own non-persistent website data store
/// (`.privateWindow(windowID)`), and the pages, pop-ups, questions and download rows of its tabs. Nothing it does reaches the store: its
/// pages write to the model only, site settings are never read or written (`siteSettingsProfileID: nil`), and the window is never handed to
/// `WindowSession` and is not restorable. Closing it (or quitting) closes every page without a flush, closes their pop-ups, ends their
/// questions, then drops the data store and the download rows.
@MainActor
final class PrivateWindowController: NSObject, NSWindowDelegate {
    let model: PrivateWindowModel
    let window: NSWindow
    let presenter = SidebarPresenter()
    let prompts: PagePrompts
    private let environment: AppEnvironment
    private let onClose: (PrivateWindowController) -> Void
    /// Addresses typed for a tab whose page did not exist yet; the page is made empty and given the address as a typed load.
    private var pendingTyped: [UUID: String] = [:]
    private var focusTask: Task<Void, Never>?
    private(set) var isClosed = false

    var windowID: UUID { model.windowID }

    init(environment: AppEnvironment, near parent: NSWindow?, onClose: @escaping (PrivateWindowController) -> Void) {
        // Read once, never written: a search engine picked in this window stays in it.
        let searchEngine = Self.read(SettingKeys.searchEngine, from: environment.store) ?? nil
        let edge = Self.read(SettingKeys.newTabEdge, from: environment.store) ?? SettingKeys.newTabEdge.defaultValue
        let model = PrivateWindowModel(searchEngine: searchEngine, newTabEdge: edge)
        self.model = model
        self.environment = environment
        self.onClose = onClose
        window = NSWindow(
            contentRect: NSRect(origin: .zero, size: WindowFrameRestore.defaultSize),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered, defer: false
        )
        let host = environment.pageHost
        prompts = PagePrompts(window: window, pageHost: host, shows: { [weak model, weak host] tabID in
            guard let model, let host, model.selectedTabID == tabID else { return false }
            return host.existingPage(tabID) != nil
        })
        super.init()
        configureWindow(near: parent)
        model.pages = self
        model.loadTyped = { [weak self] tabID, url in self?.loadTyped(url, in: tabID) ?? false }
        observeModel()
    }

    private static func read<Value: Codable & Sendable & Equatable>(_ key: SettingKey<Value>, from store: OrganizationStore) -> Value? {
        do {
            return try store.setting(key)
        } catch {
            NSLog("Stave: could not read a setting for a private window: \(error)")
            return nil
        }
    }

    // MARK: - Window

    private func configureWindow(near parent: NSWindow?) {
        window.isReleasedWhenClosed = false
        window.isRestorable = false
        window.tabbingMode = .disallowed
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.minSize = WindowFrameRestore.minimumSize
        window.delegate = self
        window.title = PrivateWindowText.windowTitle(selected: nil)
        let actions = PageAreaActions(reload: { [weak self] in self?.reloadPage() }, back: { [weak self] in self?.goBack() })
        let hosting = NSHostingView(rootView: PrivateWindowView(
            model: model, presenter: presenter, pageHost: environment.pageHost, downloads: environment.downloads,
            sidebarWidth: environment.sidebarWidth.width, actions: actions
        ))
        hosting.sizingOptions = []
        window.contentView = hosting
        if let parent {
            var frame = parent.frame
            frame.origin.x += 24
            frame.origin.y -= 24
            window.setFrame(frame, display: false)
        } else {
            window.center()
        }
    }

    func show() { window.makeKeyAndOrderFront(nil) }

    /// ⌘T and ⌘L: the bar with only the typed row.
    func openCommandBar(_ mode: CommandBarMode) { presenter.openCommandBar(mode, for: model) }

    /// Re-arms itself after each change: the selection or its address changed, so the window shows that tab's page and title.
    private func observeModel() {
        withObservationTracking {
            _ = model.selectedTabID
            _ = model.selectedTab
        } onChange: { [weak self] in
            Task { @MainActor in
                guard let self, !self.isClosed else { return }
                self.showSelected()
                self.observeModel()
            }
        }
    }

    // MARK: - Pages

    private var pageHost: PageHost { environment.pageHost }

    /// The selected tab's page, if it has one.
    var shownPage: LivePage? { model.selectedTabID.flatMap { pageHost.existingPage($0) } }

    /// Whether the page (a tab or a pop-up opened from one) belongs to this window.
    func owns(_ pageID: UUID) -> Bool {
        let tab = environment.popups.openerTab(of: pageID)
        return model.tabs.contains { $0.id == tab }
    }

    /// Gives the selected tab its page: the existing one, or a new one on this window's private store that loads the tab's address (a page
    /// hibernation unloaded comes back this way, without its history). A blank tab gets no page until something is typed for it.
    private func showSelected() {
        window.title = PrivateWindowText.windowTitle(selected: model.selectedTab)
        guard !isClosed, let tab = model.selectedTab else { return }
        let typed = pendingTyped.removeValue(forKey: tab.id)
        if pageHost.existingPage(tab.id) == nil {
            guard typed != nil || !tab.url.isEmpty else { return }
            _ = pageHost.page(for: request(tabID: tab.id, url: typed == nil ? tab.url : "", title: typed == nil ? tab.title : ""), writer: self)
        }
        if let typed { pageHost.loadTyped(typed, in: tab.id) }
        pageHost.markShown(tab.id, true)
    }

    private func request(tabID: UUID, url: String, title: String) -> PageRequest {
        PageRequest(
            tabID: tabID, store: .privateWindow(windowID), siteSettingsProfileID: nil,
            url: url, title: title, faviconURL: nil, interactionState: nil
        )
    }

    /// The model's `loadTyped`; as in a browser window, focus then moves into the page.
    private func loadTyped(_ url: String, in tabID: UUID) -> Bool {
        if pageHost.existingPage(tabID) != nil {
            pageHost.loadTyped(url, in: tabID)
        } else if model.selectedTabID == tabID {
            pendingTyped[tabID] = url
            showSelected()
        } else {
            return false
        }
        presenter.pageWillTakeFocus()
        focusPage(tabID)
        return true
    }

    private func focusPage(_ tabID: UUID) {
        focusTask?.cancel()
        focusTask = Task { @MainActor [weak self] in
            for _ in 0..<40 {
                try? await Task.sleep(for: .milliseconds(25))
                guard let self, !Task.isCancelled, !self.isClosed, let page = self.pageHost.existingPage(tabID) else { return }
                if page.webView.window === self.window {
                    self.window.makeFirstResponder(page.webView)
                    return
                }
            }
        }
    }

    // MARK: - Page commands

    func goBack() { shownPage?.webView.goBack() }
    func goForward() { shownPage?.webView.goForward() }
    func stopLoading() { shownPage?.webView.stopLoading() }

    func reloadPage() {
        guard let page = shownPage else { return }
        page.userActed()
        if page.webView.url != nil {
            page.webView.reload()
        } else if NavigationPolicy.decide(page.status.url, isMainFrame: true, source: .stored) == .allow, let url = URL(string: page.status.url) {
            page.webView.load(URLRequest(url: url))
        }
    }

    /// Switches blocking for this page only: a private page has no profile, so nothing is remembered for the site.
    func toggleContentBlocking() {
        guard let page = shownPage else { return }
        pageHost.setContentBlocking(!page.isContentBlockingOn, for: page.tabID)
    }

    // MARK: - Events (routed here by `PageEventsRouter`)

    /// A link that opens a new tab lands below its opener in this window, never in a browser window and never stored.
    func openLinkedTab(opener: UUID, url: String, select: Bool, webView: WKWebView?) -> UUID? {
        guard NavigationPolicy.decide(url, isMainFrame: true, source: .page(userGesture: true)) == .allow else { return nil }
        let id = model.open(url: url, below: opener, select: false)
        var request = request(tabID: id, url: url, title: "")
        request.openedByUser = pageHost.linkOpenedByUser(opener: opener)
        if let webView {
            _ = pageHost.adopt(webView, as: request, writer: self)
        } else {
            _ = pageHost.page(for: request, writer: self)
        }
        if select { model.select(id) }
        return id
    }

    /// A sized `window.open`: a pop-up owned by the opener tab, which closes with it (and with this window).
    func openPopup(opener: UUID, webView: WKWebView, features: WKWindowFeatures) {
        PopupWindowController.open(opener: opener, webView: webView, features: features, near: window, environment: environment)
    }

    /// `window.close()` from any of this window's tabs closes that tab (a private window has no archive: the tab just goes, as its window's
    /// tabs all do when it closes).
    func closePage(_ tabID: UUID) { model.close(tabID) }

    // MARK: - Closing

    /// Ends every page of the window and drops what it held. Runs once: at window close, or at quit.
    func tearDown() {
        guard !isClosed else { return }
        isClosed = true
        focusTask?.cancel()
        prompts.close()
        for tab in model.tabs {
            environment.popups.closeAll(openedBy: tab.id)
            pageHost.close(tab.id)
        }
        pendingTyped = [:]
        // `close` also drops each page's snapshot, kept even for a page hibernation unloaded; the window's media answers go here.
        pageHost.forgetPrivate(windowID: windowID)
        environment.webStores.releasePrivate(windowID)
        // Running downloads stop and their partial files go; finished files stay in ~/Downloads. Then the rows go.
        environment.downloads.cancelRunning(owner: .privateWindow(windowID))
        environment.downloads.dropOwner(.privateWindow(windowID))
    }

    func windowWillClose(_ notification: Notification) {
        tearDown()
        onClose(self)
    }
}

// MARK: - PageLifecycle

extension PrivateWindowController: PageLifecycle {
    /// The tab is gone: its questions end, its pop-ups close, and its page closes without a flush.
    func tabClosed(_ id: UUID) {
        prompts.end { $0.tabID == id }
        prompts.forget(id)
        environment.popups.closeAll(openedBy: id)
        pendingTyped[id] = nil
        pageHost.close(id)
    }

    func tabUnloaded(_ id: UUID) {}

    /// The page stays live but is no longer shown, so hibernation may unload it later.
    func tabDeselected(_ id: UUID) {
        prompts.end { $0.tabID == id }
        pageHost.markShown(id, false)
    }

    func tabNavigated(_ id: UUID) {}
}

// MARK: - PageWriter

/// A private page writes to the window's model only: its address and title show in the tab list, and its history stays in the web view.
extension PrivateWindowController: PageWriter {
    func writeNavigation(tabID: UUID, url: String, title: String, faviconURL: String?) {
        model.update(tabID, url: url, title: title)
    }

    func writeInteractionState(tabID: UUID, _ state: Data?) {}
}
