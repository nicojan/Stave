import AppKit
import StaveCore
import StaveWeb
import WebKit

/// Showing the selected tab's live page, the page commands, typed navigation and the page lifecycle.
extension BrowserWindowController: PageLifecycle {
    private var pageHost: PageHost { environment.pageHost }

    /// The selected tab's page when this window shows it (placement `.here`), else nil.
    var shownPage: LivePage? {
        guard let id = model.selectedTabID, model.placement == .here else { return nil }
        return pageHost.existingPage(id)
    }

    // MARK: - Showing

    /// Gives the selected tab its page when this window shows it: the existing one, or a new one that restores the tab's state or loads its
    /// stored address. A blank tab (no address) gets no page until something is typed for it (decision 2). Elsewhere, the snapshot shows.
    func showSelected() {
        guard !isClosed, let tab = model.selectedTab else {
            shownTabID = nil
            return
        }
        guard model.placement == .here else {
            shownTabID = nil
            refreshSnapshotSoon()
            return
        }
        let typed = pendingTyped.removeValue(forKey: tab.id)
        if pageHost.existingPage(tab.id) == nil {
            guard typed != nil || !tab.url.isEmpty, let request = request(for: tab, typed: typed != nil) else { return }
            _ = pageHost.page(for: request, writer: environment.pageWriter)
        }
        if let typed { pageHost.loadTyped(typed, in: tab.id) }
        pageHost.markShown(tab.id, true)
        guard shownTabID != tab.id else { return }
        shownTabID = tab.id
        do {
            try environment.store.markActive(tabID: tab.id)
        } catch {
            NSLog("Stave: could not mark a tab active: \(error)")
        }
    }

    /// The request for a tab's page: its container's or profile's persistent store, and the window's profile for site settings. A page made
    /// for a typed address starts empty (no stored address, no state), so the typed load is its first navigation.
    private func request(for tab: StaveCore.Tab, typed: Bool) -> PageRequest? {
        let storeID: UUID
        do {
            storeID = try environment.store.dataStoreID(forTab: tab.id)
        } catch {
            NSLog("Stave: could not find a tab's data store: \(error)")
            return nil
        }
        return PageRequest(
            tabID: tab.id, store: .persistent(storeID), siteSettingsProfileID: model.snapshot.profile.id,
            url: typed ? "" : tab.url, title: typed ? "" : tab.title, faviconURL: typed ? nil : tab.faviconURL,
            interactionState: typed ? nil : tab.interactionState
        )
    }

    /// The other window's snapshot is taken asynchronously when it shows another tab or resigns key; the content area looks again shortly after.
    private func refreshSnapshotSoon() {
        snapshotTask?.cancel()
        snapshotTask = Task { @MainActor [weak self] in
            for delay in [150, 600] {
                try? await Task.sleep(for: .milliseconds(delay))
                guard let self, !Task.isCancelled else { return }
                self.pageViewState.snapshotRevision += 1
            }
        }
    }

    // MARK: - Typed navigation

    /// The model's `loadTyped`: the command bar's address (already a normalised http(s) URL from `AddressInput`) goes to the tab's live page
    /// as a typed navigation, and focus moves into the page (decision 14). A tab with no page yet that this window shows gets one made for
    /// the address. False when neither applies, so the model stores the address instead.
    func loadTyped(_ url: String, in tabID: UUID) -> Bool {
        if pageHost.existingPage(tabID) != nil {
            pageHost.loadTyped(url, in: tabID)
        } else if model.selectedTabID == tabID, model.placement == .here {
            pendingTyped[tabID] = url
            showSelected()
        } else {
            return false
        }
        sidebarPresenter.pageWillTakeFocus()
        focusPage(tabID)
        return true
    }

    /// Makes the tab's web view first responder once SwiftUI has put it in this window (it may still be mounting).
    func focusPage(_ tabID: UUID) {
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

    // MARK: - Page commands (View menu, failure panel)

    func goBack() { shownPage?.webView.goBack() }

    func goForward() { shownPage?.webView.goForward() }

    func stopLoading() { shownPage?.webView.stopLoading() }

    /// Reloads what the page has. A page that never committed (its first load failed) loads its address again, judged as stored, so a refused
    /// address stays refused.
    func reloadPage() {
        guard let page = shownPage else { return }
        if page.webView.url != nil {
            page.webView.reload()
        } else if NavigationPolicy.decide(page.status.url, isMainFrame: true, source: .stored) == .allow, let url = URL(string: page.status.url) {
            page.webView.load(URLRequest(url: url))
        }
    }

    #if DEBUG
    private static let killSelector = NSSelectorFromString("_killWebContentProcess")

    /// Debug ▸ Crash Page Process is enabled only when WebKit still has the method.
    var canCrashPage: Bool { shownPage?.webView.responds(to: Self.killSelector) == true }

    /// Ends the shown page's web content process through WebKit itself; never by killing processes from outside.
    func crashPage() {
        guard let webView = shownPage?.webView, webView.responds(to: Self.killSelector) else { return }
        _ = webView.perform(Self.killSelector)
    }
    #endif

    // MARK: - PageLifecycle

    func tabClosed(_ id: UUID) {
        endPanels { $0.tabID == id }
        pendingTyped[id] = nil
        pageHost.close(id)
    }

    func tabUnloaded(_ id: UUID) {
        endPanels { $0.tabID == id }
        pageHost.unload(id)
    }

    /// Keeps a snapshot for "showing in another window" and writes the page's pending state. The page stays shown when another window
    /// took it over.
    func tabDeselected(_ id: UUID) {
        endPanels { $0.tabID == id }
        pageHost.captureSnapshot(id)
        pageHost.flushAll() // the host flushes every page or none; a flush with nothing pending writes nothing
        if environment.livePages.owner(of: id) == nil { pageHost.markShown(id, false) }
        if shownTabID == id { shownTabID = nil }
    }
}
