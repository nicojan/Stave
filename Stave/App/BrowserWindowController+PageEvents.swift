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
            // The opener page's profile, not the window's: the new page shares the opener's store, so its site settings must match.
            tabID: id, store: .persistent(storeID), siteSettingsProfileID: environment.pageHost.existingPage(opener)?.siteSettingsProfileID ?? model.snapshot.profile.id,
            url: url, title: "", faviconURL: nil, interactionState: nil,
            openedByUser: environment.pageHost.linkOpenedByUser(opener: opener)
        )
        if let webView {
            _ = environment.pageHost.adopt(webView, as: request, writer: environment.pageWriter)
        } else if environment.pageHost.existingPage(id) == nil {
            _ = environment.pageHost.page(for: request, writer: environment.pageWriter)
        }
        if select { showSelected() }
        return id
    }

    /// A clicked file link inside an opened file's grant that opens a new tab (decision 6; the delegate checked the grant): a tab below the
    /// opener, loaded through the opened-file path. A background tab gets its page now, as a background ⌘-click tab does.
    func openLinkedFile(opener: UUID, file: URL, select: Bool) {
        guard let id = model.openLinkedTab(url: "", opener: opener, select: select) else { return }
        if select {
            load(.file(file), in: id)
            focusPage(id)
            return
        }
        let storeID: UUID
        do {
            storeID = try environment.store.dataStoreID(forTab: id)
        } catch {
            NSLog("Stave: could not find a linked file tab's data store: \(error)")
            return
        }
        let request = PageRequest(
            tabID: id, store: .persistent(storeID), siteSettingsProfileID: environment.pageHost.existingPage(opener)?.siteSettingsProfileID ?? model.snapshot.profile.id,
            url: "", title: "", faviconURL: nil, interactionState: nil, openedByUser: true
        )
        _ = environment.pageHost.page(for: request, writer: environment.pageWriter)
        environment.pageHost.loadFile(file, in: id)
    }

    /// "Open Link in New Window": a new window on this window's profile and workspace (the app delegate makes it), with the link as its
    /// selected tab. The URL is judged as a user-initiated page navigation first, as `openLinkedTab` does.
    func openLinkInNewWindow(opener: UUID, url: String) {
        guard NavigationPolicy.decide(url, isMainFrame: true, source: .page(userGesture: true)) == .allow else { return }
        onOpenLinkInNewWindow(self, opener, url)
    }

    /// A sized `window.open`: a pop-up window owned by its opener tab (see `PopupWindowController.open`).
    func openPopup(opener: UUID, webView: WKWebView, features: WKWindowFeatures) {
        PopupWindowController.open(opener: opener, webView: webView, features: features, near: window, environment: environment)
    }

    /// `window.close()` from any tab's page closes that tab, as the close shortcut would: it goes to the archive (as in Safari, where a
    /// script may close any tab, not only one a page opened).
    func closePage(_ tabID: UUID) {
        model.close(tabID)
    }

    // MARK: - Questions

    func confirmExternalApp(tabID: UUID, host: String?, url: URL, appName: String) async -> Bool {
        await prompts.confirmExternalApp(tabID: tabID, host: host, url: url, appName: appName)
    }

    func confirmSeveralDownloads(tabID: UUID, host: String?) async -> QuestionAnswer {
        await prompts.confirmSeveralDownloads(tabID: tabID, host: host)
    }

    func confirmDownload(tabID: UUID, host: String?) async -> QuestionAnswer {
        await prompts.confirmDownload(tabID: tabID, host: host)
    }

    func askMedia(tabID: UUID, host: String, camera: Bool, microphone: Bool) async -> (allow: Bool, remember: Bool) {
        await environment.mediaQuestions.ask(pageHost: environment.pageHost, tabID: tabID, host: host, camera: camera, microphone: microphone)
    }

    func cancelWaitingQuestions(tabID: UUID) {
        environment.mediaQuestions.cancel(tabID: tabID)
    }

    func alert(tabID: UUID, origin: String?, message: String) async {
        await prompts.alert(tabID: tabID, origin: origin, message: message)
    }

    func confirm(tabID: UUID, origin: String?, message: String) async -> Bool {
        await prompts.confirm(tabID: tabID, origin: origin, message: message)
    }

    func prompt(tabID: UUID, origin: String?, message: String, defaultText: String?) async -> String? {
        await prompts.prompt(tabID: tabID, origin: origin, message: message, defaultText: defaultText)
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
