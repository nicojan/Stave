import AppKit
import ChorusEngine
import Foundation
import Observation
import StaveCore
import WebKit

/// Remembered per-site choices, scoped to a profile.
public protocol SiteSettingsSource: AnyObject {
    @MainActor func decision(profileID: UUID, host: String, key: SiteSettingKey) -> SiteDecision?
    @MainActor func setDecision(profileID: UUID, host: String, key: SiteSettingKey, _ d: SiteDecision?)
}

/// Stave's own page pool, keyed by tab ID (plan 3, decisions 2, 3, 8, 10 and 16).
@MainActor
@Observable
public final class PageHost {
    private(set) var pages: [UUID: LivePage] = [:]
    /// Pop-ups, linked tabs, panels, permissions and downloads go here. Set by the app.
    @ObservationIgnored public weak var events: PageEvents?

    @ObservationIgnored private let stores: WebDataStores
    @ObservationIgnored private let contentBlocker: ContentBlockerManager
    @ObservationIgnored private let siteSettings: SiteSettingsSource
    @ObservationIgnored private let applicationName: String
    @ObservationIgnored private let now: () -> Date
    @ObservationIgnored private lazy var faviconRelay = FaviconRelay(host: self)
    @ObservationIgnored private lazy var fileLinkRelay = FileLinkRelay(host: self)
    /// In memory only (decision 16), at most `snapshotLimit`, least recently taken dropped first (`snapshotOrder`, oldest first).
    @ObservationIgnored private var snapshots: [UUID: NSImage] = [:]
    @ObservationIgnored private var snapshotOrder: [UUID] = []
    static let snapshotLimit = 24
    /// Snapshots are taken at most this wide: they only stand in for a page shown in another window.
    static let snapshotWidth: CGFloat = 600
    /// Seam for tests: how long an unloading page waits for its snapshot before it is torn down anyway.
    @ObservationIgnored var snapshotTimeout: Duration = .seconds(3)
    /// Seam for tests: takes a page's snapshot and calls back on the main actor (maybe never, if WebKit hangs).
    @ObservationIgnored var snapshotter: @MainActor (WKWebView, @escaping @MainActor (NSImage?) -> Void) -> Void = PageHost.takeSnapshot
    /// Set by the app: whether a window owns the tab (shows it), so its snapshot can still stand in for it elsewhere.
    @ObservationIgnored public var hasOwner: @MainActor (UUID) -> Bool = { _ in false }
    /// The latest snapshot asked for per tab; an older or cancelled one never lands.
    @ObservationIgnored private var snapshotTokens: [UUID: UUID] = [:]
    @ObservationIgnored private var hibernationTask: Task<Void, Never>?
    /// One per page; kept here because WebKit holds its delegates weakly.
    @ObservationIgnored private var delegates: [UUID: PageDelegate] = [:]
    @ObservationIgnored private let activeDownloads = ActiveDownloads()
    /// A private session's camera/microphone answers, in memory only (decision 11); they go with the session's last window.
    @ObservationIgnored private var privateMediaAnswers: [PrivateMediaKey: SiteDecision] = [:]
    /// Seam for tests: finds and opens apps for non-web links.
    @ObservationIgnored var externalApps = ExternalApps.system
    /// Test-only seam: extra rule lists added to every page this host makes (a block-all list keeps tests off the network).
    @ObservationIgnored var testRuleLists: [WKContentRuleList] = []
    /// Seam for tests: whether a page is playing media or using the camera or microphone.
    @ObservationIgnored var mediaCheck: @MainActor (WKWebView) async -> Bool = PageHost.isBusyWithMedia
    /// Set by the app: whether the tab's page has pop-ups open, which keeps it from hibernating (ruling R14).
    @ObservationIgnored public var hasOpenPopups: @MainActor (UUID) -> Bool = { _ in false }

    public init(stores: WebDataStores, contentBlocker: ContentBlockerManager, siteSettings: SiteSettingsSource, applicationName: String, now: @escaping () -> Date = Date.init) {
        self.stores = stores
        self.contentBlocker = contentBlocker
        self.siteSettings = siteSettings
        self.applicationName = applicationName
        self.now = now
    }

    // MARK: Pages

    /// The tab's live page, or a new one that restores its state or loads its stored URL.
    public func page(for request: PageRequest, writer: PageWriter) -> LivePage {
        if let existing = pages[request.tabID] { return existing }
        let blocking = blockingWanted(for: request)
        let configuration = PageConfiguration.make(
            store: stores.store(for: request.store),
            ruleLists: (blocking ? contentBlocker.enabledLists() : []) + testRuleLists,
            applicationName: applicationName,
            messageHandler: faviconRelay,
            fileLinkHandler: fileLinkRelay
        )
        let webView = PageWebView(frame: .zero, configuration: configuration)
        webView.now = now
        let page = LivePage(request: request, webView: webView, writer: writer, isContentBlockingOn: blocking, now: now)
        insert(page)
        // Before `start`: the delegate gates the restore navigation too (ruling R7).
        installDelegate(on: page)
        page.start(request)
        return page
    }

    public func existingPage(_ tabID: UUID) -> LivePage? {
        pages[tabID]
    }

    /// Whether a linked tab (⌘-click, "Open Link in New Tab") counts as opened by the user, and so may download at once: only when the
    /// user has acted on its opener. A script can fake a ⌘-click, so a page reopened by itself can't use one to get round the gate.
    public func linkOpenedByUser(opener: UUID) -> Bool {
        pages[opener].map { !$0.awaitsUserAction } ?? false
    }

    /// Takes over a web view WebKit created (a linked tab or pop-up), keeping its configuration and opener.
    public func adopt(_ webView: WKWebView, as request: PageRequest, writer: PageWriter) -> LivePage {
        if pages[request.tabID] != nil { close(request.tabID) }
        // The configuration (and its rule lists) came from the opener and is left as WebKit made it.
        let page = LivePage(request: request, webView: webView, writer: writer, isContentBlockingOn: blockingWanted(for: request), now: now)
        insert(page)
        installDelegate(on: page)
        return page
    }

    /// Opens an address the user typed (normalised by the app first), judged with source `.typed`.
    public func loadTyped(_ address: String, in tabID: UUID) {
        guard let page = pages[tabID], let delegate = delegates[tabID] else { return }
        page.userActed()
        switch NavigationPolicy.decide(address, isMainFrame: true, source: .typed) {
        case .allow:
            guard let url = URL(string: address) else {
                page.status.failure = .refused(url: address)
                return
            }
            page.webView.load(URLRequest(url: url))
        case .refuse(let failure):
            page.status.failure = failure ?? .refused(url: address)
        case .askToOpenExternally(let external):
            delegate.startExternal(external, typed: true)
        }
    }

    /// The home folder an opened file's grant is checked against (`OpenedFile.readAccessURL`). Tests set a synthetic one.
    @ObservationIgnored public var homeDirectory = FileManager.default.homeDirectoryForCurrentUser
    /// Seam for tests: hands the file and its read-access URL to WebKit.
    @ObservationIgnored var fileLoader: @MainActor (WKWebView, URL, URL) -> Void = { webView, file, access in
        webView.loadFileURL(file, allowingReadAccessTo: access)
    }

    /// Opens an HTML file the user chose (Finder, a drop, File ▸ Open File…, Open Again) through `.openedFile` (decision 6): WebKit may read
    /// its folder, or the file alone when that folder is `/` or home. The grant is the tab's, in memory only. The user opened it, so it counts
    /// as the user acting on the page.
    public func loadFile(_ file: URL, in tabID: UUID) {
        guard let page = pages[tabID] else { return }
        page.userActed()
        let resolvedFile = OpenedFile.resolved(file)
        let access = OpenedFile.readAccessURL(for: resolvedFile, home: homeDirectory)
        let folder = access.path
        guard OpenedFile.isHTML(resolvedFile),
              NavigationPolicy.decide(resolvedFile.absoluteString, isMainFrame: true, source: .openedFile(grantedFolder: folder)) == .allow else {
            page.status.failure = .refused(url: file.absoluteString)
            return
        }
        page.grantedFolder = folder
        page.pendingOpenedFile = resolvedFile.path
        page.restorePending = false
        page.status.failure = nil
        fileLoader(page.webView, resolvedFile, access)
    }

    /// Shows the refused panel for an address refused before the policy (a link from another app over the length cap); loads nothing.
    public func showRefused(_ address: String, in tabID: UUID) {
        guard let page = pages[tabID] else { return }
        page.status.failure = .refused(url: address)
    }

    func isAdopted(_ webView: WKWebView) -> Bool {
        pages.values.contains { $0.webView === webView }
    }

    public func markShown(_ tabID: UUID, _ shown: Bool) {
        guard let page = pages[tabID] else { return }
        page.isShown = shown
        page.lastShownAt = now()
    }

    /// Flushes pending state, snapshots the page (kept only while a window still shows the tab, see `storeSnapshot`), then tears it down,
    /// within `snapshotTimeout` whatever the snapshot does.
    public func unload(_ tabID: UUID) {
        guard let page = pages.removeValue(forKey: tabID) else { return }
        events?.cancelWaitingQuestions(tabID: tabID)
        delegates[tabID]?.refuseWaitingDownloads()
        page.flush()
        page.close()
        // The delegate stays until the teardown (and while a download it started runs).
        let delegate = delegates.removeValue(forKey: tabID)
        captureSnapshot(of: page, thenTearDown: true, keeping: delegate)
    }

    /// Ends the page without flushing: its tab is gone, so nothing more is written for it.
    /// The snapshot goes too, also for a page hibernation already unloaded (which `unload` left a snapshot for).
    public func close(_ tabID: UUID) {
        dropSnapshot(tabID)
        snapshotTokens[tabID] = nil
        guard let page = pages.removeValue(forKey: tabID) else { return }
        events?.cancelWaitingQuestions(tabID: tabID)
        delegates[tabID]?.refuseWaitingDownloads()
        page.close()
        delegates[tabID] = nil
        Self.tearDown(page)
    }

    /// A private window of the profile opens: it joins the profile's private session (see `WebDataStores.joinPrivateSession`).
    public func joinPrivateSession(profileID: UUID) -> UUID {
        stores.joinPrivateSession(profileID: profileID)
    }

    /// A private window of the profile closed (its pages are closed by then, which drops their snapshots). When it was the last, the
    /// session's store and its camera and microphone answers go, so the next private window starts fresh.
    public func leavePrivateSession(profileID: UUID) {
        // The session ID is read before the store registry drops it.
        let sessionID = stores.privateSessionID(profileID: profileID)
        if stores.leavePrivateSession(profileID: profileID), let sessionID {
            forgetPrivate(sessionID: sessionID)
        }
    }

    /// Drops one session's in-memory camera and microphone answers. Runs when the session's last window closes (`leavePrivateSession`).
    func forgetPrivate(sessionID: UUID) {
        let store = DataStoreKey.privateSession(sessionID)
        privateMediaAnswers = privateMediaAnswers.filter { $0.key.store != store }
    }

    /// The last snapshot of the tab's page, kept in memory.
    public func snapshot(for tabID: UUID) -> NSImage? {
        snapshots[tabID]
    }

    /// Replaces the tab's snapshot with what its page shows now (when its window shows another tab or resigns key).
    public func captureSnapshot(_ tabID: UUID) {
        guard let page = pages[tabID] else { return }
        captureSnapshot(of: page, thenTearDown: false, keeping: nil)
    }

    func currentDate() -> Date {
        now()
    }

    /// The tabs whose live pages belong to browser windows (a profile or container store), not to a private session. When the last browser
    /// window closes and Stave stays open, the app unloads these, so no page plays audio or holds a camera with no window to reach it.
    public var persistentTabIDs: [UUID] {
        pages.values.filter { if case .persistent = $0.store { true } else { false } }.map(\.tabID)
    }

    public func flushAll() {
        for page in pages.values { page.flush() }
    }

    // MARK: Hibernation

    /// Unloads the pages `HibernationPolicy` picks, after asking each unshown page about media.
    public func hibernateIdle() async {
        let candidates = Array(pages.values)
        var infos: [LivePageInfo] = []
        for page in candidates {
            let busy = page.isShown ? false : await mediaCheck(page.webView)
            infos.append(LivePageInfo(
                id: page.tabID, isShown: page.isShown, lastShownAt: page.lastShownAt, isBusyWithMedia: busy, hasOpenPopups: hasOpenPopups(page.tabID)
            ))
        }
        for id in HibernationPolicy.pagesToUnload(infos, now: now()) {
            // The pool may have changed while the media checks ran.
            guard let page = pages[id], candidates.contains(where: { $0 === page }), !page.isShown else { continue }
            unload(id)
        }
    }

    static func isBusyWithMedia(_ webView: WKWebView) async -> Bool {
        if webView.cameraCaptureState != .none || webView.microphoneCaptureState != .none { return true }
        return await webView.requestMediaPlaybackState() == .playing
    }

    private func startHibernationIfNeeded() {
        guard hibernationTask == nil else { return }
        hibernationTask = Task { [weak self] in
            while true {
                try? await Task.sleep(for: .seconds(HibernationPolicy.interval))
                guard let self, !Task.isCancelled else { return }
                await self.hibernateIdle()
                if self.pages.isEmpty {
                    self.hibernationTask = nil
                    return
                }
            }
        }
    }

    // MARK: Content blocking

    /// Turns blocking on or off for the page's site, remembers it for the profile, and reloads.
    public func setContentBlocking(_ on: Bool, for tabID: UUID) {
        guard let page = pages[tabID] else { return }
        if let profileID = page.siteSettingsProfileID, let host = SiteHost.normalized(page.status.url) {
            siteSettings.setDecision(profileID: profileID, host: host, key: .contentBlocking, on ? nil : .deny)
        }
        page.isContentBlockingOn = on
        attachRuleLists(to: page)
        // The user asked for this reload (a menu or command-bar action), so it counts as acting on the page.
        page.webView.reload()
    }

    /// Attaches lists that compiled after pages were made; they apply from each page's next load.
    public func reattachRuleLists() {
        for page in pages.values where page.isContentBlockingOn {
            attachRuleLists(to: page)
        }
    }

    func blockingWanted(for request: PageRequest) -> Bool {
        blockingWanted(profileID: request.siteSettingsProfileID, url: request.url)
    }

    func blockingWanted(profileID: UUID?, url: String) -> Bool {
        guard let profileID, let host = SiteHost.normalized(url) else { return true }
        return siteSettings.decision(profileID: profileID, host: host, key: .contentBlocking) != .deny
    }

    /// Before a main-frame load to a new site, turns the page's rule lists on or off for that site (ruling R6).
    func updateBlocking(for page: LivePage, navigatingTo url: String) {
        guard let site = SiteHost.normalized(url), site != page.blockingHost else { return }
        page.blockingHost = site
        let wanted = blockingWanted(profileID: page.siteSettingsProfileID, url: url)
        guard wanted != page.isContentBlockingOn else { return }
        // TODO(R10): a pop-up or linked tab shares its opener's WKUserContentController (WebKit's configuration
        // carries it over), so switching one's lists would silently switch the other's. Such pages keep the
        // lists they have until per-page controllers exist; the explicit menu switch still applies to both.
        guard !sharesContentController(page) else { return }
        page.isContentBlockingOn = wanted
        attachRuleLists(to: page)
    }

    private func sharesContentController(_ page: LivePage) -> Bool {
        let content = page.webView.configuration.userContentController
        return pages.values.contains { $0 !== page && $0.webView.configuration.userContentController === content }
    }

    private func attachRuleLists(to page: LivePage) {
        let content = page.webView.configuration.userContentController
        content.removeAllContentRuleLists()
        if page.isContentBlockingOn {
            for list in contentBlocker.enabledLists() { content.add(list) }
        }
        for list in testRuleLists { content.add(list) }
    }

    // MARK: Camera and microphone

    /// A profile's answers are site settings; a private window's are kept in memory for that window only.
    func rememberedMedia(for page: LivePage, host: String, key: SiteSettingKey) -> SiteDecision? {
        if let profileID = page.siteSettingsProfileID {
            return siteSettings.decision(profileID: profileID, host: host, key: key)
        }
        return privateMediaAnswers[PrivateMediaKey(store: page.store, host: host, key: key)]
    }

    func rememberMedia(_ decision: SiteDecision, for page: LivePage, host: String, key: SiteSettingKey) {
        if let profileID = page.siteSettingsProfileID {
            siteSettings.setDecision(profileID: profileID, host: host, key: key, decision)
        } else {
            privateMediaAnswers[PrivateMediaKey(store: page.store, host: host, key: key)] = decision
        }
    }

    // MARK: Downloads

    func trackDownload(_ download: WKDownload, delegate: PageDelegate) {
        activeDownloads.track(download, delegate: delegate)
    }

    func beginDownload(_ download: WKDownload, delegate: PageDelegate, rowID: UUID, list: DownloadList, destination: URL, source: URL?) {
        activeDownloads.begin(download, delegate: delegate, rowID: rowID, list: list, destination: destination, source: source)
    }

    /// Checked before every download's destination is given to WebKit, off the main thread.
    @ObservationIgnored let downloadsFolder = DownloadsFolderCheck()

    /// Seam for tests: how a download's file is quarantined.
    var markDownload: @MainActor (URL, URL?) throws -> Void {
        get { activeDownloads.mark }
        set { activeDownloads.mark = newValue }
    }

    /// Test seam: what WebKit's first progress report does, capturing the destination file's identity as this download's.
    func claimDownloadFile(_ rowID: UUID) {
        activeDownloads.claimDestination(forRow: rowID)
    }

    func downloadFinished(_ download: WKDownload) {
        activeDownloads.finished(download)
    }

    func downloadFailed(_ download: WKDownload, message: String) {
        activeDownloads.failed(download, message: message)
    }

    /// The running download behind a list row (nil once it ended or was cancelled).
    func activeDownload(_ rowID: UUID) -> WKDownload? {
        activeDownloads.download(forRow: rowID)
    }

    // MARK: Internals

    func receivedFavicon(_ href: String, from webView: WKWebView?) {
        guard let webView, let page = pages.values.first(where: { $0.webView === webView }) else { return }
        page.record(.favicon(href))
    }

    /// The user's plain click on a `file:` link in an opened file's page (`PageConfiguration.fileLinkScript`). Outside the tab's grant, WebKit
    /// drops the navigation without asking the delegate, so the policy's refused panel is shown from here; inside it, WebKit asks the
    /// delegate as usual and nothing happens here. A page with no grant gets nothing.
    func receivedFileLinkClick(_ href: String, from webView: WKWebView?) {
        guard let webView, let page = pages.values.first(where: { $0.webView === webView }), !page.isClosed, let folder = page.grantedFolder,
              case .refuse(let failure?) = NavigationPolicy.decide(href, isMainFrame: true, source: .page(userGesture: true, grantedFolder: folder))
        else { return }
        page.status.failure = failure
    }

    private func installDelegate(on page: LivePage) {
        let delegate = PageDelegate(page: page, host: self, events: nil)
        delegates[page.tabID] = delegate
        page.webView.navigationDelegate = delegate
        page.webView.uiDelegate = delegate
    }

    private func insert(_ page: LivePage) {
        pages[page.tabID] = page
        startHibernationIfNeeded()
    }

    /// Snapshots the page; when `thenTearDown`, the web view is kept until the snapshot is taken, then torn down. A snapshot that hasn't
    /// come within `snapshotTimeout` doesn't hold the page: it is torn down anyway, and the late snapshot, if it ever comes, is dropped.
    private func captureSnapshot(of page: LivePage, thenTearDown: Bool, keeping delegate: PageDelegate?) {
        let token = UUID()
        let tabID = page.tabID
        snapshotTokens[tabID] = token
        let pending = PendingTearDown(page: thenTearDown ? page : nil, delegate: delegate)
        snapshotter(page.webView) { [weak self] image in
            if let self, self.snapshotTokens[tabID] == token {
                self.snapshotTokens[tabID] = nil
                if let image { self.storeSnapshot(image, for: tabID) }
            }
            pending.run()
        }
        guard thenTearDown else { return }
        let timeout = snapshotTimeout
        Task { [weak self] in
            try? await Task.sleep(for: timeout)
            guard pending.isWaiting else { return }
            if let self, self.snapshotTokens[tabID] == token { self.snapshotTokens[tabID] = nil }
            pending.run()
        }
    }

    /// Keeps the tab's snapshot as the most recent, then drops the snapshots no window can show: a tab with no live page and no owner
    /// (hibernated, or unloaded with nobody showing it), and the least recently taken beyond `snapshotLimit`.
    func storeSnapshot(_ image: NSImage, for tabID: UUID) {
        snapshots[tabID] = image
        let (order, evicted) = RecentlyUsed.use(tabID, in: snapshotOrder, limit: Self.snapshotLimit)
        snapshotOrder = order
        for id in evicted { snapshots[id] = nil }
        for id in snapshotOrder where pages[id] == nil && !hasOwner(id) { dropSnapshot(id) }
    }

    private func dropSnapshot(_ tabID: UUID) {
        snapshots[tabID] = nil
        snapshotOrder = snapshotOrder.filter { $0 != tabID }
    }

    /// WebKit's snapshot, scaled down to at most `snapshotWidth`.
    static func takeSnapshot(_ webView: WKWebView, completion: @escaping @MainActor (NSImage?) -> Void) {
        let configuration = WKSnapshotConfiguration()
        let width = min(snapshotWidth, webView.bounds.width)
        if width > 0 { configuration.snapshotWidth = NSNumber(value: Double(width)) }
        webView.takeSnapshot(with: configuration) { image, _ in
            MainActor.assumeIsolated { completion(image) }
        }
    }

    static func tearDown(_ page: LivePage) {
        page.webView.stopLoading()
        page.webView.removeFromSuperview()
    }
}

/// An unloaded page waiting for its snapshot before it is torn down: whichever comes first (the snapshot or the timeout) tears it down,
/// once, and lets the page and its delegate go.
@MainActor
private final class PendingTearDown {
    private var page: LivePage?
    private var delegate: PageDelegate?

    init(page: LivePage?, delegate: PageDelegate?) {
        self.page = page
        self.delegate = delegate
    }

    var isWaiting: Bool { page != nil }

    func run() {
        guard let page else { return }
        self.page = nil
        delegate = nil
        PageHost.tearDown(page)
    }
}

struct PrivateMediaKey: Hashable {
    var store: DataStoreKey
    var host: String
    var key: SiteSettingKey
}

/// Receives favicon messages from the isolated `StaveFavicon` world. Holds the host weakly, because the
/// user content controller keeps its handlers alive. Pages WebKit created share their opener's controller,
/// so the message is routed by its web view.
@MainActor
final class FaviconRelay: NSObject, WKScriptMessageHandler {
    private weak var host: PageHost?
    private static let maxLength = 2048

    init(host: PageHost) {
        self.host = host
    }

    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        // Only a web address is kept; a `data:` icon would put a page's bytes into the store.
        guard let href = message.body as? String, href.count <= Self.maxLength, URLScheme.hasWebAuthority(href) else { return }
        host?.receivedFavicon(href, from: message.webView)
    }
}

/// Receives the user's clicks on `file:` links from the isolated `StaveFileLink` world, routed by web view like `FaviconRelay`.
@MainActor
final class FileLinkRelay: NSObject, WKScriptMessageHandler {
    private weak var host: PageHost?

    init(host: PageHost) {
        self.host = host
    }

    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        guard message.frameInfo.isMainFrame, let href = message.body as? String, href.utf8.count <= ExternalOpen.maximumURLLength,
              URLScheme.scheme(of: href) == "file" else { return }
        host?.receivedFileLinkClick(href, from: message.webView)
    }
}
