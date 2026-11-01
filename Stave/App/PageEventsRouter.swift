import AppKit
import StaveCore
import StaveWeb
import WebKit

/// The one `PageEvents` of the app (`PageHost.events`, held weakly there, so the app delegate keeps it). Each event goes to the window that
/// owns the page's tab (`LivePageRegistry.owner(of:)`); with no owner, to the frontmost window of the same profile. With no window at all,
/// every question resolves to its safe answer (refuse, deny, cancel) so a page is never left waiting. A pop-up's page (an ID in
/// `PopupRegistry`) asks on its own pop-up window; its links and pop-ups go to the window of the sidebar tab that opened it. A private
/// window's pages (its tabs and their pop-ups) have no store tab and no registry owner: they go to that private window, and a private page
/// whose window is gone is refused rather than handed to a browser window.
@MainActor
final class PageEventsRouter: PageEvents {
    private let environment: AppEnvironment
    private let controllers: () -> [BrowserWindowController]
    private let privateControllers: () -> [PrivateWindowController]

    init(environment: AppEnvironment, controllers: @escaping () -> [BrowserWindowController], privateControllers: @escaping () -> [PrivateWindowController]) {
        self.environment = environment
        self.controllers = controllers
        self.privateControllers = privateControllers
    }

    /// The private window that owns the page (a tab, or a pop-up opened from one).
    private func privateController(for pageID: UUID) -> PrivateWindowController? {
        privateControllers().first { !$0.isClosed && $0.owns(pageID) }
    }

    /// Whether the page (or the tab behind a pop-up) lives on a private window's store. Such a page never reaches a browser window.
    private func isPrivatePage(_ pageID: UUID) -> Bool {
        for id in [pageID, popups.openerTab(of: pageID)] {
            if case .privateWindow? = environment.pageHost.existingPage(id)?.store { return true }
        }
        return false
    }

    /// The owner window of the tab's page, else the frontmost window on the page's profile, else the frontmost window.
    private func controller(for tabID: UUID) -> BrowserWindowController? {
        guard !isPrivatePage(tabID) else { return nil }
        let all = controllers()
        if let owner = environment.livePages.owner(of: tabID), let found = all.first(where: { $0.model.windowID == owner }) { return found }
        let profileID = environment.pageHost.existingPage(tabID)?.siteSettingsProfileID
        let candidates = all.filter { profileID == nil || $0.model.snapshot.profile.id == profileID }
        for window in NSApp.orderedWindows {
            if let found = candidates.first(where: { $0.window === window }) { return found }
        }
        return candidates.first
    }

    private var popups: PopupRegistry { environment.popups }

    /// Links from a pop-up land below its opener tab (decision 6).
    func openLinkedTab(opener: UUID, url: String, select: Bool, webView: WKWebView?) -> UUID? {
        let tab = popups.openerTab(of: opener)
        if let owner = privateController(for: tab) { return owner.openLinkedTab(opener: tab, url: url, select: select, webView: webView) }
        return controller(for: tab)?.openLinkedTab(opener: tab, url: url, select: select, webView: webView)
    }

    /// `opener` may itself be a pop-up; the window of its opener tab makes the new one.
    func openPopup(opener: UUID, webView: WKWebView, features: WKWindowFeatures) {
        if let owner = privateController(for: opener) {
            owner.openPopup(opener: opener, webView: webView, features: features)
            return
        }
        controller(for: popups.openerTab(of: opener))?.openPopup(opener: opener, webView: webView, features: features)
    }

    /// `window.close()`: a pop-up closes its window; a tab closes as with the close shortcut.
    func closePage(_ tabID: UUID) {
        if let popup = popups.popup(tabID) {
            popup.close()
        } else if let owner = privateController(for: tabID) {
            owner.closePage(tabID)
        } else {
            controller(for: tabID)?.closePage(tabID)
        }
    }

    /// The sheets for a page: its pop-up's, else its window's.
    private func prompts(for tabID: UUID) -> PagePrompts? {
        popups.popup(tabID)?.prompts ?? privateController(for: tabID)?.prompts ?? controller(for: tabID)?.prompts
    }

    /// No tab ID comes with the question; the frontmost browser or pop-up window asks it.
    func confirmExternalApp(url: URL, appName: String) async -> Bool {
        let all = controllers()
        let privates = privateControllers()
        let popupList = popups.all
        let front = NSApp.orderedWindows.lazy.compactMap { window -> PagePrompts? in
            all.first { $0.window === window }?.prompts ?? privates.first { $0.window === window }?.prompts
                ?? popupList.first { $0.window === window }?.prompts
        }.first
        guard let front else { return false }
        return await front.confirmExternalApp(url: url, appName: appName)
    }

    func askMedia(tabID: UUID, host: String, camera: Bool, microphone: Bool) async -> (allow: Bool, remember: Bool) {
        guard let prompts = prompts(for: tabID) else { return (false, false) }
        return await prompts.askMedia(tabID: tabID, host: host, camera: camera, microphone: microphone)
    }

    func alert(tabID: UUID, origin: String?, message: String) async {
        await prompts(for: tabID)?.alert(tabID: tabID, origin: origin, message: message)
    }

    func confirm(tabID: UUID, origin: String?, message: String) async -> Bool {
        guard let prompts = prompts(for: tabID) else { return false }
        return await prompts.confirm(tabID: tabID, origin: origin, message: message)
    }

    func prompt(tabID: UUID, origin: String?, message: String, defaultText: String?) async -> String? {
        guard let prompts = prompts(for: tabID) else { return nil }
        return await prompts.prompt(tabID: tabID, origin: origin, message: message, defaultText: defaultText)
    }

    func chooseFiles(tabID: UUID, allowsMultiple: Bool, allowsDirectories: Bool) async -> [URL]? {
        guard let prompts = prompts(for: tabID) else { return nil }
        return await prompts.chooseFiles(tabID: tabID, allowsMultiple: allowsMultiple, allowsDirectories: allowsDirectories)
    }

    /// The page's profile; a page already gone falls back to its tab's profile in the store (a pop-up's: its opener tab's). With
    /// none of those, nil: the download is refused rather than filed under an owner that doesn't exist.
    func downloadOwner(tabID: UUID) -> DownloadOwner? {
        // A private page's download is listed in its window only, and its row goes when the window closes.
        if let owner = privateController(for: tabID) { return .privateWindow(owner.windowID) }
        if isPrivatePage(tabID) {
            NSLog("Stave: refused a download from a private page whose window is gone")
            return nil
        }
        if let profileID = environment.pageHost.existingPage(tabID)?.siteSettingsProfileID { return .profile(profileID) }
        let tab = popups.openerTab(of: tabID)
        if let profileID = environment.pageHost.existingPage(tab)?.siteSettingsProfileID { return .profile(profileID) }
        do {
            return .profile(try environment.store.profileID(forTab: tab))
        } catch {
            NSLog("Stave: refused a download with no owner: \(error)")
            return nil
        }
    }

    var downloads: DownloadList { environment.downloads }

    var downloadsDirectory: URL { AppEnvironment.downloadsDirectory }
}
