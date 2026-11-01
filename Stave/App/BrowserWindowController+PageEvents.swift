import AppKit
import StaveCore
import StaveWeb
import WebKit

/// What this window's pages ask of it, routed here by `PageEventsRouter`. Every question resolves: answered, or refused, denied or cancelled
/// when its tab or this window closes while it is up, so a page (and the delegate's single-flight external-app prompt) never waits forever.
/// The sheets are `PagePrompts` on this window; a pop-up has its own (`PopupWindowController`).
extension BrowserWindowController: PageEvents {
    // MARK: - Tabs and pop-ups

    /// A link that opens a new tab (`target=_blank`, `window.open` without size, ⌘-click). The URL is judged as a user-initiated page
    /// navigation first, so a refused one (`javascript:`, `file:`, …) is never stored. The tab lands below its opener; a web view WebKit made is
    /// adopted before returning (an unadopted one is refused by the delegate). A background ⌘-click tab gets its page now (decision 2).
    func openLinkedTab(opener: UUID, url: String, select: Bool, webView: WKWebView?) -> UUID? {
        guard NavigationPolicy.decide(url, isMainFrame: true, source: .page(userGesture: true)) == .allow,
              let id = model.openLinkedTab(url: url, opener: opener, select: select) else { return nil }
        let storeID: UUID
        do {
            storeID = try environment.store.dataStoreID(forTab: id)
        } catch {
            NSLog("Stave: could not find a linked tab's data store: \(error)")
            return webView == nil ? id : nil
        }
        let request = PageRequest(
            tabID: id, store: .persistent(storeID), siteSettingsProfileID: model.snapshot.profile.id,
            url: url, title: "", faviconURL: nil, interactionState: nil
        )
        if let webView {
            _ = environment.pageHost.adopt(webView, as: request, writer: environment.pageWriter)
        } else if environment.pageHost.existingPage(id) == nil {
            _ = environment.pageHost.page(for: request, writer: environment.pageWriter)
        }
        if select { showSelected() }
        return id
    }

    /// A sized `window.open`: a pop-up window around the web view WebKit made. The view is adopted (the delegate refuses an unadopted one)
    /// under a fresh page ID that is no store tab, with the opener's data store and profile; its writer drops every write. It is registered
    /// under its opener tab, whose page going closes it.
    func openPopup(opener: UUID, webView: WKWebView, features: WKWindowFeatures) {
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
            id: id, openerTabID: popups.openerTab(of: opener), page: page, features: features, near: window,
            pageHost: environment.pageHost, onClose: { closed in popups.remove(closed) }
        )
        popups.add(popup)
        popup.show()
    }

    /// `window.close()` from a page Stave opened closes its tab, as the close shortcut would.
    func closePage(_ tabID: UUID) {
        model.close(tabID)
    }

    // MARK: - Questions

    func confirmExternalApp(url: URL, appName: String) async -> Bool {
        await prompts.confirmExternalApp(url: url, appName: appName)
    }

    func askMedia(tabID: UUID, host: String, camera: Bool, microphone: Bool) async -> (allow: Bool, remember: Bool) {
        await prompts.askMedia(tabID: tabID, host: host, camera: camera, microphone: microphone)
    }

    func alert(tabID: UUID, message: String) async {
        await prompts.alert(tabID: tabID, message: message)
    }

    func confirm(tabID: UUID, message: String) async -> Bool {
        await prompts.confirm(tabID: tabID, message: message)
    }

    func prompt(tabID: UUID, message: String, defaultText: String?) async -> String? {
        await prompts.prompt(tabID: tabID, message: message, defaultText: defaultText)
    }

    func chooseFiles(tabID: UUID, allowsMultiple: Bool, allowsDirectories: Bool) async -> [URL]? {
        await prompts.chooseFiles(tabID: tabID, allowsMultiple: allowsMultiple, allowsDirectories: allowsDirectories)
    }

    // MARK: - Downloads

    func downloadOwner(tabID: UUID) -> DownloadOwner? { .profile(model.snapshot.profile.id) }

    var downloads: DownloadList { environment.downloads }

    var downloadsDirectory: URL { AppEnvironment.downloadsDirectory }

    // MARK: - Sheets

    /// Ends the matching sheets as cancelled; each one's waiting question then resolves.
    func endPanels(where matches: (PagePanel) -> Bool) {
        prompts.end(where: matches)
    }
}
