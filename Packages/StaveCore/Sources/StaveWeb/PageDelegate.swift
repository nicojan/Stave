import AppKit
import Foundation
import StaveCore
import WebKit

/// What a page asks of the app: tabs, pop-ups, sheets and the downloads list (plan 3, Task 7).
@MainActor public protocol PageEvents: AnyObject {
    /// Nil: refused (opener gone). When `webView` is given, the app adopts it (`PageHost.adopt`) before returning.
    func openLinkedTab(opener: UUID, url: String, select: Bool, webView: WKWebView?) -> UUID?
    /// The app adopts `webView` (`PageHost.adopt`) before returning.
    func openPopup(opener: UUID, webView: WKWebView, features: WKWindowFeatures)
    /// `window.close()` from any page: a pop-up's window closes; a tab closes as with the close shortcut (it goes to the archive, as in
    /// Safari, where a script may close any tab).
    func closePage(_ tabID: UUID)
    /// "Open this link in ‹App›?" for the tab's page. `host`: the asking page's site, named in the question; nil for a typed address.
    /// Asked only while the tab is shown; otherwise false.
    func confirmExternalApp(tabID: UUID, host: String?, url: URL, appName: String) async -> Bool
    /// "‹host› wants to download several files" (Allow / Don't Allow), for a document's second download onward (`PageDownloadGate`).
    /// Asked only while the tab is shown; otherwise false.
    func confirmSeveralDownloads(tabID: UUID, host: String?) async -> Bool
    func askMedia(tabID: UUID, host: String, camera: Bool, microphone: Bool) async -> (allow: Bool, remember: Bool)
    /// `origin`: the host of the frame that asked (nil for a frame with no web origin), which the dialog names instead of the top page.
    func alert(tabID: UUID, origin: String?, message: String) async
    func confirm(tabID: UUID, origin: String?, message: String) async -> Bool
    func prompt(tabID: UUID, origin: String?, message: String, defaultText: String?) async -> String?
    func chooseFiles(tabID: UUID, allowsMultiple: Bool, allowsDirectories: Bool) async -> [URL]?
    /// Whose downloads list the page's download joins. Nil: no owner can be found, and the download is refused.
    func downloadOwner(tabID: UUID) -> DownloadOwner?
    var downloads: DownloadList { get }
    var downloadsDirectory: URL { get }
}

/// Finds and opens the app for a non-web link. A seam, so tests never launch apps.
@MainActor
struct ExternalApps {
    var appFor: (URL) -> URL?
    var open: (URL) -> Void

    static var system: ExternalApps {
        ExternalApps(
            appFor: { NSWorkspace.shared.urlForApplication(toOpen: $0) },
            open: { NSWorkspace.shared.open($0) }
        )
    }
}

/// What the delegate reads from a `WKNavigationAction`. A value, so tests can make one (WebKit's frame
/// objects can't be made outside WebKit).
struct NavigationRequest {
    var url: String
    var targetsNewWindow = false
    var isMainFrame = true
    var type: WKNavigationType = .linkActivated
    var modifiers: NSEvent.ModifierFlags = []
    /// An `<a download>` link.
    var shouldDownload = false

    @MainActor init(_ action: WKNavigationAction) {
        url = action.request.url?.absoluteString ?? ""
        targetsNewWindow = action.targetFrame == nil
        isMainFrame = action.targetFrame?.isMainFrame ?? true
        type = action.navigationType
        modifiers = action.modifierFlags
        shouldDownload = action.shouldPerformDownload
    }

    init(_ url: String, targetsNewWindow: Bool = false, isMainFrame: Bool = true, type: WKNavigationType = .linkActivated, modifiers: NSEvent.ModifierFlags = [], shouldDownload: Bool = false) {
        self.url = url
        self.targetsNewWindow = targetsNewWindow
        self.isMainFrame = isMainFrame
        self.type = type
        self.modifiers = modifiers
        self.shouldDownload = shouldDownload
    }
}

/// One page's navigation, UI and download delegate. Glue: every rule it applies lives in StaveCore.
/// The host keeps it alive (WebKit holds delegates weakly), and keeps it while a download it started runs.
/// WebKit finds these methods by selector and nothing warns about a misnamed one: add each new one to `delegateSelectors` in
/// `DelegateSelectorTests`.
@MainActor
public final class PageDelegate: NSObject, WKNavigationDelegate, WKUIDelegate, WKDownloadDelegate {
    let tabID: UUID
    weak var page: LivePage?
    weak var host: PageHost?
    private weak var ownEvents: PageEvents?
    /// The URL of the main-frame navigation last allowed, for failures whose error names no URL.
    private var pendingURL: URL?
    /// The latest external-app hand-off, kept so tests can wait for it.
    var externalTask: Task<Void, Never>?
    /// One external-app question at a time: a page clicking a `mailto:` link by script in a loop would
    /// otherwise stack sheets. Requests made while one is pending, or within the cooldown after a
    /// decline, are dropped.
    private var externalPending = false
    private var externalQuietUntil: Date?
    /// Counts the downloads of the page's current document, so a page can't save file after file with no click.
    private var downloadGate = PageDownloadGate()
    private var downloadQuestionPending = false
    static let externalCooldown: TimeInterval = 1

    /// `events` may be nil; the host's `events` is used then.
    public init(page: LivePage, host: PageHost, events: PageEvents?) {
        tabID = page.tabID
        self.page = page
        self.host = host
        ownEvents = events
    }

    var events: PageEvents? { ownEvents ?? host?.events }

    // MARK: Pure helpers

    /// The policy decision and link disposition for a navigation a page makes. A link that opens a new
    /// tab is judged as a main frame, whatever frame it was clicked in.
    static func decision(for url: String, isMainFrame: Bool, userGesture: Bool, modifiers: NSEvent.ModifierFlags, targetsNewWindow: Bool) -> (NavigationDecision, LinkDisposition) {
        let disposition = LinkDisposition.decide(command: modifiers.contains(.command), shift: modifiers.contains(.shift), targetsNewWindow: targetsNewWindow)
        let decision = NavigationPolicy.decide(url, isMainFrame: isMainFrame || disposition != .current, source: .page(userGesture: userGesture))
        return (decision, disposition)
    }

    /// A link click, or a back/forward or reload to a history item allowed when it was made, counts as a
    /// user gesture; anything else (script, form submission, redirect) doesn't.
    static func hasUserGesture(_ type: WKNavigationType) -> Bool {
        switch type {
        case .linkActivated, .backForward, .reload: true
        default: false
        }
    }

    static let certificateErrorCodes: Set<Int> = [
        NSURLErrorSecureConnectionFailed,
        NSURLErrorServerCertificateHasBadDate,
        NSURLErrorServerCertificateUntrusted,
        NSURLErrorServerCertificateHasUnknownRoot,
        NSURLErrorServerCertificateNotYetValid,
        NSURLErrorClientCertificateRejected,
        NSURLErrorClientCertificateRequired,
    ]

    /// What a load error shows. Nil for a cancelled load and for one that became a download.
    static func failure(for error: Error, fallbackURL: URL?) -> PageFailure? {
        let error = error as NSError
        if error.domain == NSURLErrorDomain, error.code == NSURLErrorCancelled { return nil }
        // WebKitErrorFrameLoadInterruptedByPolicyChange: the navigation became a download.
        if error.domain == "WebKitErrorDomain", error.code == 102 { return nil }
        let failingURL = (error.userInfo[NSURLErrorFailingURLErrorKey] as? URL)
            ?? (error.userInfo[NSURLErrorFailingURLStringErrorKey] as? String).flatMap { URL(string: $0) }
            ?? fallbackURL
        let host = failingURL?.host ?? ""
        if error.domain == NSURLErrorDomain, certificateErrorCodes.contains(error.code) { return .insecure(host: host) }
        return .loadFailed(host: host, message: error.localizedDescription)
    }

    /// A safe, unused file name in `directory`. Check-then-use: if a file appears there before WebKit
    /// writes, WebKit fails the download rather than overwriting it.
    static func destination(for suggestedFilename: String, in directory: URL) -> URL {
        DownloadFilename.unique(DownloadFilename.sanitized(suggestedFilename), in: directory) {
            FileManager.default.fileExists(atPath: $0.path)
        }
    }

    // MARK: Navigation

    public func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction) async -> WKNavigationActionPolicy {
        decide(NavigationRequest(navigationAction))
    }

    func decide(_ navigation: NavigationRequest) -> WKNavigationActionPolicy {
        guard let page, !page.isClosed else { return .cancel }
        let url = navigation.url
        let targetsNewWindow = navigation.targetsNewWindow
        let opensHere = navigation.isMainFrame && !targetsNewWindow

        if opensHere, page.restorePending {
            return decideRestore(url, page: page)
        }

        // Ruling R11: a `data:` link marked as a download is saved, never rendered, so the policy's
        // refusal of a data: page doesn't apply. Without the flag, data: stays refused.
        if navigation.shouldDownload, URLScheme.scheme(of: url) == "data" { return .download }

        let (decision, disposition) = Self.decision(
            for: url,
            isMainFrame: navigation.isMainFrame,
            userGesture: Self.hasUserGesture(navigation.type),
            modifiers: navigation.type == .linkActivated ? navigation.modifiers : [],
            targetsNewWindow: targetsNewWindow
        )
        switch decision {
        case .refuse(let failure):
            if opensHere, let failure { page.status.failure = failure }
            return .cancel
        case .askToOpenExternally(let address):
            startExternal(address, typed: false)
            return .cancel
        case .allow:
            // An `<a download>` link the policy allows downloads, whatever frame or window it targets.
            if navigation.shouldDownload { return .download }
            // A new window goes on to `createWebViewWith`; a ⌘-click opens the tab here.
            if !targetsNewWindow, case .newTab(let select) = disposition {
                _ = events?.openLinkedTab(opener: tabID, url: url, select: select, webView: nil)
                return .cancel
            }
            if opensHere { allowMainFrame(url, page: page) }
            return .allow
        }
    }

    /// The navigation a restored `interactionState` starts is judged as restored (ruling R7).
    private func decideRestore(_ url: String, page: LivePage) -> WKNavigationActionPolicy {
        page.restorePending = false
        guard NavigationPolicy.decide(url, isMainFrame: true, source: .restored) == .allow else {
            page.status.failure = .refused(url: url)
            return .cancel
        }
        allowMainFrame(url, page: page)
        return .allow
    }

    /// Content blocking follows the site being opened, before its load starts (ruling R6).
    private func allowMainFrame(_ url: String, page: LivePage) {
        pendingURL = URL(string: url)
        host?.updateBlocking(for: page, navigatingTo: url)
    }

    public func webView(_ webView: WKWebView, decidePolicyFor navigationResponse: WKNavigationResponse) async -> WKNavigationResponsePolicy {
        // A subframe never starts a download by itself.
        guard navigationResponse.isForMainFrame else { return navigationResponse.canShowMIMEType ? .allow : .cancel }
        if !navigationResponse.canShowMIMEType || Self.isAttachment(navigationResponse.response) { return .download }
        return .allow
    }

    private static func isAttachment(_ response: URLResponse) -> Bool {
        guard let http = response as? HTTPURLResponse,
              let disposition = http.value(forHTTPHeaderField: "Content-Disposition") else { return false }
        return disposition.trimmingCharacters(in: .whitespaces).lowercased().hasPrefix("attachment")
    }

    public func webView(_ webView: WKWebView, navigationAction: WKNavigationAction, didBecome download: WKDownload) {
        host?.trackDownload(download, delegate: self)
    }

    public func webView(_ webView: WKWebView, navigationResponse: WKNavigationResponse, didBecome download: WKDownload) {
        host?.trackDownload(download, delegate: self)
    }

    public func webView(_ webView: WKWebView, didCommit navigation: WKNavigation!) {
        page?.committed()
    }

    public func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        loadFailed(error)
    }

    public func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        loadFailed(error)
    }

    private func loadFailed(_ error: Error) {
        guard let page, !page.isClosed, let failure = Self.failure(for: error, fallbackURL: pendingURL) else { return }
        page.status.failure = failure
    }

    /// Shows "This page stopped working". Never reloads by itself and writes nothing (Review Focus 5).
    public func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        page?.processTerminated()
    }

    // MARK: External apps

    func startExternal(_ address: String, typed: Bool) {
        guard !externalPending else { return }
        if let quietUntil = externalQuietUntil, let now = host?.currentDate(), now < quietUntil { return }
        externalPending = true
        externalTask = Task { [weak self] in
            await self?.openExternally(address, typed: typed)
            self?.externalPending = false
        }
    }

    /// Asks before handing a link to its app. With no app, only a typed address says so.
    func openExternally(_ address: String, typed: Bool) async {
        guard let host else { return }
        guard let url = URL(string: address), let app = host.externalApps.appFor(url) else {
            if typed, let page, !page.isClosed { page.status.failure = .noAppForLink(url: address) }
            return
        }
        guard let events else { return }
        // The page that asks is named; a typed address is the user's own, so none is.
        let asking = typed ? nil : page.flatMap { SiteHost.normalized($0.status.url) }
        let confirmed = await events.confirmExternalApp(tabID: tabID, host: asking, url: url, appName: Self.appName(app))
        guard confirmed else {
            externalQuietUntil = host.currentDate().addingTimeInterval(Self.externalCooldown)
            return
        }
        // The tab may have closed (or its page been replaced) while the question was up.
        guard let page, !page.isClosed, host.existingPage(tabID) === page else { return }
        host.externalApps.open(url)
    }

    static func appName(_ app: URL) -> String {
        let bundle = Bundle(url: app)
        let name = bundle?.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String
            ?? bundle?.object(forInfoDictionaryKey: "CFBundleName") as? String
        return name ?? app.deletingPathExtension().lastPathComponent
    }

    // MARK: Downloads

    /// Every download a page starts comes through here, whatever started it (an attachment response, a type the page can't show, an
    /// `<a download>` link clicked by the user or by script): the document's first proceeds, later ones ask (`PageDownloadGate`). WebKit
    /// cancels a download given no destination.
    public func download(_ download: WKDownload, decideDestinationUsing response: URLResponse, suggestedFilename: String) async -> URL? {
        // A page Stave reopened by itself downloads nothing until the user acts on it (no question either: nobody asked for this page).
        // The refused download still counts as the document's first, so its next one asks.
        if let page, page.awaitsUserAction {
            _ = downloadGate.next(navigation: page.commitCount)
            return nil
        }
        // No owner to file it under: refused.
        guard host != nil, self.events?.downloadOwner(tabID: tabID) != nil else { return nil }
        guard await mayDownload() else { return nil }
        // The question may have been up for a while: everything is looked up again.
        guard let host, let events, let owner = events.downloadOwner(tabID: tabID) else { return nil }
        let destination = Self.destination(for: suggestedFilename, in: events.downloadsDirectory)
        let source = Self.quarantineSource(download.originalRequest?.url ?? response.url, pageURL: page?.webView.url ?? page.flatMap { URL(string: $0.status.url) })
        let rowID = events.downloads.begin(owner: owner, filename: destination.lastPathComponent, sourceHost: source?.host)
        host.beginDownload(download, delegate: self, rowID: rowID, list: events.downloads, destination: destination, source: source)
        return destination
    }

    /// Whether this download may go ahead: the document's first does; a later one asks, one question at a time (a download that arrives
    /// while one is up is refused), and the answer holds for the rest of the document. A question that can't be asked counts as refused.
    func mayDownload() async -> Bool {
        let navigation = page.map(\.commitCount)
        switch downloadGate.next(navigation: navigation) {
        case .proceed: return true
        case .refuse: return false
        case .ask:
            guard !downloadQuestionPending, let events else { return false }
            downloadQuestionPending = true
            let allowed = await events.confirmSeveralDownloads(tabID: tabID, host: page.flatMap { SiteHost.normalized($0.status.url) })
            downloadQuestionPending = false
            downloadGate.answer(allow: allowed, navigation: navigation)
            return allowed
        }
    }

    /// The URL the quarantine names as the file's source. A `data:` or `blob:` URL holds the file itself (or names nothing outside the
    /// page), so the page that made it is named instead.
    static func quarantineSource(_ source: URL?, pageURL: URL?) -> URL? {
        guard let source else { return pageURL }
        switch source.scheme?.lowercased() {
        case "data", "blob": return pageURL
        default: return source
        }
    }

    public func downloadDidFinish(_ download: WKDownload) {
        host?.downloadFinished(download)
    }

    public func download(_ download: WKDownload, didFailWithError error: Error, resumeData: Data?) {
        host?.downloadFailed(download, message: error.localizedDescription)
    }
}
