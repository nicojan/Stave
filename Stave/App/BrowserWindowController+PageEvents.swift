import AppKit
import StaveCore
import StaveWeb
import WebKit

/// A page's question shown as a sheet on its window.
struct PagePanel {
    let tabID: UUID?
    let alert: NSAlert
}

/// What this window's pages ask of it, routed here by `PageEventsRouter`. Every question resolves: answered, or refused, denied or cancelled
/// when its tab or this window closes while it is up, so a page (and the delegate's single-flight external-app prompt) never waits forever.
/// The sheets here are plain `NSAlert`s; Task 10 replaces the ones marked with real dialog sheets and the permission, pop-up and file UI.
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

    /// Task 10: pop-up windows. Until then the web view is left unadopted, which the delegate refuses, so the pop-up is blocked.
    func openPopup(opener: UUID, webView: WKWebView, features: WKWindowFeatures) {}

    /// `window.close()` from a page Stave opened closes its tab, as the close shortcut would.
    func closePage(_ tabID: UUID) {
        model.close(tabID)
    }

    // MARK: - Questions

    func confirmExternalApp(url: URL, appName: String) async -> Bool {
        let alert = NSAlert()
        alert.messageText = PageText.externalAppQuestion(appName: appName)
        alert.informativeText = url.absoluteString
        alert.addButton(withTitle: PageText.openButton)
        alert.addButton(withTitle: PageText.cancelButton)
        return await present(alert, for: nil) == .alertFirstButtonReturn
    }

    /// Task 10: the camera and microphone sheet. Until then every request is denied and nothing is remembered.
    func askMedia(tabID: UUID, host: String, camera: Bool, microphone: Bool) async -> (allow: Bool, remember: Bool) {
        (false, false)
    }

    /// Task 10 replaces with its dialog sheet.
    func alert(tabID: UUID, message: String) async {
        let alert = NSAlert()
        alert.messageText = message
        alert.addButton(withTitle: PageText.okButton)
        _ = await present(alert, for: tabID)
    }

    /// Task 10 replaces with its dialog sheet.
    func confirm(tabID: UUID, message: String) async -> Bool {
        let alert = NSAlert()
        alert.messageText = message
        alert.addButton(withTitle: PageText.okButton)
        alert.addButton(withTitle: PageText.cancelButton)
        return await present(alert, for: tabID) == .alertFirstButtonReturn
    }

    /// Task 10 replaces with its dialog sheet.
    func prompt(tabID: UUID, message: String, defaultText: String?) async -> String? {
        let alert = NSAlert()
        alert.messageText = message
        let field = NSTextField(string: defaultText ?? "")
        field.frame = NSRect(x: 0, y: 0, width: 280, height: 24)
        alert.accessoryView = field
        alert.addButton(withTitle: PageText.okButton)
        alert.addButton(withTitle: PageText.cancelButton)
        alert.window.initialFirstResponder = field
        return await present(alert, for: tabID) == .alertFirstButtonReturn ? field.stringValue : nil
    }

    /// Task 10: the file picker. Until then every upload is cancelled.
    func chooseFiles(tabID: UUID, allowsMultiple: Bool, allowsDirectories: Bool) async -> [URL]? {
        nil
    }

    // MARK: - Downloads

    func downloadOwner(tabID: UUID) -> DownloadOwner { .profile(model.snapshot.profile.id) }

    var downloads: DownloadList { environment.downloads }

    var downloadsDirectory: URL { AppEnvironment.downloadsDirectory }

    // MARK: - Sheets

    /// Shows the alert as a sheet and waits for its answer. A tab's question is asked only while this window shows that tab and nothing else is
    /// on the window; otherwise it resolves at once as cancelled (`.abort`), as it does when `endPanels` ends it.
    private func present(_ alert: NSAlert, for tabID: UUID?) async -> NSApplication.ModalResponse {
        guard !isClosed, window.attachedSheet == nil else { return .abort }
        if let tabID, shownPage?.tabID != tabID { return .abort }
        let id = UUID()
        panels[id] = PagePanel(tabID: tabID, alert: alert)
        let response = await withCheckedContinuation { (continuation: CheckedContinuation<NSApplication.ModalResponse, Never>) in
            alert.beginSheetModal(for: window) { response in continuation.resume(returning: response) }
        }
        panels[id] = nil
        return response
    }

    /// Ends the matching sheets as cancelled; each one's waiting question then resolves.
    func endPanels(where matches: (PagePanel) -> Bool) {
        for (id, panel) in panels where matches(panel) {
            panels[id] = nil
            window.endSheet(panel.alert.window, returnCode: .abort)
        }
    }
}
