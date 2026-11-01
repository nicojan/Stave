import AppKit
import StaveCore
import StaveWeb
import WebKit

/// The one `PageEvents` of the app (`PageHost.events`, held weakly there, so the app delegate keeps it). Each event goes to the window that
/// owns the page's tab (`LivePageRegistry.owner(of:)`); with no owner, to the frontmost window of the same profile. With no window at all,
/// every question resolves to its safe answer (refuse, deny, cancel) so a page is never left waiting.
@MainActor
final class PageEventsRouter: PageEvents {
    private let environment: AppEnvironment
    private let controllers: () -> [BrowserWindowController]

    init(environment: AppEnvironment, controllers: @escaping () -> [BrowserWindowController]) {
        self.environment = environment
        self.controllers = controllers
    }

    /// The owner window of the tab's page, else the frontmost window on the page's profile, else the frontmost window.
    private func controller(for tabID: UUID) -> BrowserWindowController? {
        let all = controllers()
        if let owner = environment.livePages.owner(of: tabID), let found = all.first(where: { $0.model.windowID == owner }) { return found }
        let profileID = environment.pageHost.existingPage(tabID)?.siteSettingsProfileID
        let candidates = all.filter { profileID == nil || $0.model.snapshot.profile.id == profileID }
        for window in NSApp.orderedWindows {
            if let found = candidates.first(where: { $0.window === window }) { return found }
        }
        return candidates.first
    }

    func openLinkedTab(opener: UUID, url: String, select: Bool, webView: WKWebView?) -> UUID? {
        controller(for: opener)?.openLinkedTab(opener: opener, url: url, select: select, webView: webView)
    }

    func openPopup(opener: UUID, webView: WKWebView, features: WKWindowFeatures) {
        controller(for: opener)?.openPopup(opener: opener, webView: webView, features: features)
    }

    func closePage(_ tabID: UUID) {
        controller(for: tabID)?.closePage(tabID)
    }

    /// No tab ID comes with the question; the key browser window asks it.
    func confirmExternalApp(url: URL, appName: String) async -> Bool {
        let all = controllers()
        let front = NSApp.orderedWindows.lazy.compactMap { window in all.first { $0.window === window } }.first
        guard let front else { return false }
        return await front.confirmExternalApp(url: url, appName: appName)
    }

    func askMedia(tabID: UUID, host: String, camera: Bool, microphone: Bool) async -> (allow: Bool, remember: Bool) {
        guard let controller = controller(for: tabID) else { return (false, false) }
        return await controller.askMedia(tabID: tabID, host: host, camera: camera, microphone: microphone)
    }

    func alert(tabID: UUID, message: String) async {
        await controller(for: tabID)?.alert(tabID: tabID, message: message)
    }

    func confirm(tabID: UUID, message: String) async -> Bool {
        guard let controller = controller(for: tabID) else { return false }
        return await controller.confirm(tabID: tabID, message: message)
    }

    func prompt(tabID: UUID, message: String, defaultText: String?) async -> String? {
        guard let controller = controller(for: tabID) else { return nil }
        return await controller.prompt(tabID: tabID, message: message, defaultText: defaultText)
    }

    func chooseFiles(tabID: UUID, allowsMultiple: Bool, allowsDirectories: Bool) async -> [URL]? {
        guard let controller = controller(for: tabID) else { return nil }
        return await controller.chooseFiles(tabID: tabID, allowsMultiple: allowsMultiple, allowsDirectories: allowsDirectories)
    }

    /// The page's profile; a page already gone falls back to the owning window's profile, then the first profile.
    func downloadOwner(tabID: UUID) -> DownloadOwner {
        if let profileID = environment.pageHost.existingPage(tabID)?.siteSettingsProfileID { return .profile(profileID) }
        if let controller = controller(for: tabID) { return controller.downloadOwner(tabID: tabID) }
        let first = (try? environment.store.profiles().first?.id) ?? nil
        return .profile(first ?? UUID())
    }

    var downloads: DownloadList { environment.downloads }

    var downloadsDirectory: URL { AppEnvironment.downloadsDirectory }
}
