import AppKit
import StaveCore
import StaveWeb

/// View ▸ Zoom In / Zoom Out / Actual Size, File ▸ Print… and the Develop menu (decisions 12–14), on the key window's shown page.
extension AppDelegate {
    /// View ▸ Zoom In (⌘+, ⌘=), Zoom Out (⌘-) and Actual Size (⌘0): the key window's shown page, kept for its site (in memory in a private window).
    func zoomIn() { pageToolCommand(\PageMenuState.canZoomIn) { page, _ in self.environment?.pageHost.zoomIn(page.tabID) } }
    func zoomOut() { pageToolCommand(\PageMenuState.canZoomOut) { page, _ in self.environment?.pageHost.zoomOut(page.tabID) } }
    func actualSize() { pageToolCommand(\PageMenuState.canResetZoom) { page, _ in self.environment?.pageHost.resetZoom(page.tabID) } }

    /// File ▸ Print… (⌘P): the print panel as a sheet on the page's window, the job named after the page.
    func printPage() {
        pageToolCommand(\PageMenuState.canPrint) { page, window in
            let title = PageMenuText.printJobTitle(title: page.status.title, url: page.status.url)
            PageTools.print(page.webView, title: title).runModal(for: window, delegate: nil, didRun: nil, contextInfo: nil)
        }
    }

    /// View ▸ Settings for This Website: the per-site panel as a sheet on the key window, for the page it shows (in a private window too).
    func showSitePanel() {
        pageToolCommand(\PageMenuState.canShowSitePanel) { _, _ in
            if let keyPrivate = self.keyPrivate {
                keyPrivate.presenter.openSitePanel(.keyboard)
            } else {
                self.keyController?.sidebarPresenter.openSitePanel(.keyboard)
            }
        }
    }

    /// Looks the other browsers up again (View ▸ Open in Safari / Open in Chrome, decision 25): when Stave becomes active and when the
    /// store opens. The menu reads `menuState.installedBrowsers`, so building it never asks LaunchServices.
    func refreshInstalledBrowsers() {
        let found = environment?.pageHost.refreshInstalledBrowsers() ?? []
        if menuState.installedBrowsers != found { menuState.installedBrowsers = found }
    }

    /// View ▸ Open in Safari / Open in Chrome: the key window's shown page's address, and nothing else.
    func openInBrowser(_ app: OpenElsewhereApp) {
        pageToolCommand(\PageMenuState.canOpenElsewhere) { page, _ in self.environment?.pageHost.openElsewhere(app, tabID: page.tabID) }
    }

    /// Develop ▸ Show Web Inspector (⌥⌘I) and Show Page Source (⌥⌘U).
    func showWebInspector() { pageToolCommand(\PageMenuState.canInspect) { page, _ in PageTools.showInspector(page.webView) } }
    func showPageSource() { pageToolCommand(\PageMenuState.canShowSource) { page, _ in PageTools.showPageSource(page.webView) } }

    /// Runs on the key window's shown page only when the menu rule allows it now (`PageMenuState`): never with a sheet up, over the History
    /// view, or where the item is disabled, so a key equivalent can't reach a page the menu wouldn't.
    private func pageToolCommand(_ allowed: KeyPath<PageMenuState, Bool>, _ run: (LivePage, NSWindow) -> Void) {
        let target: (LivePage, NSWindow, PageMenuState)?
        if let keyPrivate {
            target = keyPrivate.shownPage.map { page in
                (page, keyPrivate.window, PageMenuState.from(status: Self.summary(of: page), sheetOpen: keyPrivate.window.attachedSheet != nil))
            }
        } else if let controller = keyController {
            target = controller.shownPage.map { page in
                (page, controller.window, PageMenuState.from(status: Self.summary(of: page), sheetOpen: isBusy(controller), historyShown: controller.model.isShowingHistory))
            }
        } else {
            target = nil
        }
        guard let (page, window, state) = target, state[keyPath: allowed] else { return }
        run(page, window)
    }
}
