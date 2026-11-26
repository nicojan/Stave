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
    /// A per-site value (zoom; from Task 16 the user agent), nil when none is stored or it can't be read. Never asked for a private page.
    @MainActor func siteValue<V: Codable>(profileID: UUID, host: String, key: SiteValueKey, as type: V.Type) -> V?
    /// Stores a per-site value; nil removes it. Never called for a private page.
    @MainActor func setSiteValue<V: Codable>(profileID: UUID, host: String, key: SiteValueKey, _ value: V?)
    /// Removes every stored answer and value for the profile and host (the site panel's Reset This Site), in one write.
    @MainActor func removeSite(profileID: UUID, host: String)
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
    @ObservationIgnored let siteSettings: SiteSettingsSource
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
    /// The store of every unloaded page whose web view still waits for its snapshot (keyed by the teardown's own token), for `usesStore`.
    @ObservationIgnored private var tearingDownStores: [UUID: DataStoreKey] = [:]
    @ObservationIgnored private var hibernationTask: Task<Void, Never>?
    /// One per page; kept here because WebKit holds its delegates weakly.
    @ObservationIgnored private var delegates: [UUID: PageDelegate] = [:]
    @ObservationIgnored let activeDownloads = ActiveDownloads()
    /// A private session's camera, microphone and content-blocking answers, in memory only (decision 11); they go with the session's last window.
    @ObservationIgnored var privateMediaAnswers: [PrivateMediaKey: SiteDecision] = [:]
    /// A private session's site values (its zoom), JSON in memory only: a private window writes no site values. They go with the session,
    /// like `privateMediaAnswers`.
    @ObservationIgnored var privateSiteValues: [PrivateSiteValueKey: Data] = [:]
    /// Whether pages in private windows get `developerExtrasEnabled` and so the inspector (decision 14, Task 9's spike).
    static let privateWindowsInspect = false
    /// Seam for tests: finds the other browsers and hands them a page's address (View ▸ Open in Safari / Chrome, decision 25).
    @ObservationIgnored var browserLauncher = BrowserLauncher.system { didSet { installedBrowsersCache = nil } }
    /// The installed browsers as last looked up: LaunchServices is asked when the panel opens and when the app becomes active, not on every
    /// menu evaluation (`refreshInstalledBrowsers`).
    @ObservationIgnored var installedBrowsersCache: [OpenElsewhereApp]?
    /// Seam for tests: finds and opens apps for non-web links.
    @ObservationIgnored var externalApps = ExternalApps.system
    /// Test-only seam: extra rule lists added to every page this host makes (a block-all list keeps tests off the network).
    @ObservationIgnored var testRuleLists: [WKContentRuleList] = []
    /// Seam for tests: whether a page is playing media or using the camera or microphone.
    @ObservationIgnored var mediaCheck: @MainActor (WKWebView) async -> Bool = PageHost.isBusyWithMedia
    /// Seam for tests: how long one hidden page may take to answer the media check before it counts as busy.
    @ObservationIgnored var mediaCheckLimit: Duration = .seconds(5)
    /// Pages whose media check from an earlier hibernation round has not returned (by identity, so a remade page is asked afresh).
    @ObservationIgnored private var unfinishedMediaChecks: Set<ObjectIdentifier> = []
    /// Seam for tests: runs a page's trailing title write after its delay. The default sleeps; tests run the work by hand.
    @ObservationIgnored var titleScheduler: @MainActor (TimeInterval, @escaping @MainActor () -> Void) -> Void = LivePage.sleepThenRun
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
            fileLinkHandler: fileLinkRelay,
            developerExtras: request.siteSettingsProfileID != nil || Self.privateWindowsInspect
        )
        let webView = PageWebView(frame: .zero, configuration: configuration)
        webView.now = now
        let page = LivePage(request: request, webView: webView, writer: writer, isContentBlockingOn: blocking, now: now)
        insert(page)
        // Before `start`: the delegate gates the restore navigation too (ruling R7).
        installDelegate(on: page)
        // A stored address or a restored tab loads with its site's agent already on (decision 24), not set while the policy runs.
        updateUserAgent(for: page, navigatingTo: request.url)
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
            // Before the load, not in the policy check: the request is built first (WebKit bug 313542, fixed only on newer systems).
            updateUserAgent(for: page, navigatingTo: address)
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
    /// session's store and its in-memory site answers and values go, so the next private window starts fresh.
    public func leavePrivateSession(profileID: UUID) {
        // The session ID is read before the store registry drops it.
        let sessionID = stores.privateSessionID(profileID: profileID)
        if stores.leavePrivateSession(profileID: profileID), let sessionID {
            forgetPrivate(sessionID: sessionID)
        }
    }

    /// Drops one session's in-memory site answers (camera, microphone, content blocking) and site values. Runs when the session's last window closes (`leavePrivateSession`).
    func forgetPrivate(sessionID: UUID) {
        let store = DataStoreKey.privateSession(sessionID)
        privateMediaAnswers = privateMediaAnswers.filter { $0.key.store != store }
        privateSiteValues = privateSiteValues.filter { $0.key.store != store }
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

    /// How long to wait for unloaded pages to let go of a store before removing it: their snapshot timeout plus a second for the teardown
    /// to run. Derived from `snapshotTimeout`, so the two can't drift apart.
    public var teardownWaitLimit: Duration { snapshotTimeout + .seconds(1) }

    /// Whether any page still holds one of these stores. Callers poll this up to `teardownWaitLimit`.
    public func usesAnyStore(_ ids: [UUID]) -> Bool { ids.contains { usesStore($0) } }

    /// Whether any page holds the persistent store `id`: a live page (a pop-up's included), or one unloaded whose teardown still waits for
    /// its snapshot, since the web view lives until then. A store in use can't be removed (`WebDataStores.remove`).
    public func usesStore(_ id: UUID) -> Bool {
        let key = DataStoreKey.persistent(id)
        return pages.values.contains { $0.store == key } || tearingDownStores.values.contains(key)
    }

    public func flushAll() {
        for page in pages.values { page.flush() }
    }

    /// Writes one tab's pending title and state now (the tab was deselected); other tabs stay as they are. No page: nothing to do.
    public func flush(_ tabID: UUID) {
        pages[tabID]?.flush()
    }

    /// Writes the tab's pending title now, before the store archives it, so the archive keeps the latest title. No page: nothing to do.
    public func flushTitle(_ tabID: UUID) {
        pages[tabID]?.flushTitle()
    }

    // MARK: Hibernation

    /// Unloads the pages `HibernationPolicy` picks, after asking each unshown page about media. Pop-ups are read after every media check
    /// has finished (a pop-up can open while a later page is being checked), and again right before each unload. Unloading drops the
    /// page's questions in every window kind (`unload` tells the app).
    public func hibernateIdle() async {
        let candidates = Array(pages.values)
        // Every check runs at once and each is time-limited, so one page that never answers can't hold up the others.
        let checks = candidates.map { page in Task { @MainActor in await self.isBusy(page) } }
        var busyPages: [UUID: Bool] = [:]
        for (page, check) in zip(candidates, checks) { busyPages[page.tabID] = await check.value }
        let infos = candidates.map { page in
            LivePageInfo(
                id: page.tabID, isShown: page.isShown, lastShownAt: page.lastShownAt,
                isBusyWithMedia: busyPages[page.tabID] ?? false, hasOpenPopups: hasOpenPopups(page.tabID)
            )
        }
        for id in HibernationPolicy.pagesToUnload(infos, now: now()) {
            // The pool may have changed while the media checks ran.
            guard let page = pages[id], candidates.contains(where: { $0 === page }), !page.isShown, !hasOpenPopups(id) else { continue }
            unload(id)
        }
    }

    /// Whether an unshown page can't be hibernated now. A page with a JavaScript dialog waiting is busy without being asked: its script is
    /// blocked in WebKit's completion handler and the media question may never come back. Any other check that takes longer than
    /// `mediaCheckLimit` counts as busy too (try again next round).
    private func isBusy(_ page: LivePage) async -> Bool {
        if page.isShown { return false }
        if delegates[page.tabID]?.pendingDialogs ?? 0 > 0 { return true }
        // R1-6: a check from an earlier round that never returned is still out; asking again would only pile up abandoned checks.
        let checked = ObjectIdentifier(page)
        if unfinishedMediaChecks.contains(checked) { return true }
        unfinishedMediaChecks.insert(checked)
        let check = mediaCheck, webView = page.webView, limit = mediaCheckLimit
        return await withCheckedContinuation { (continuation: CheckedContinuation<Bool, Never>) in
            let once = ResumeOnce(continuation)
            Task { @MainActor in
                let busy = await check(webView)
                self.unfinishedMediaChecks.remove(checked)
                once.resume(busy)
            }
            Task { @MainActor in
                try? await Task.sleep(for: limit)
                once.resume(true)
            }
        }
    }

    /// Resumes a continuation the first time it is told, ignores the rest.
    @MainActor
    private final class ResumeOnce {
        private var continuation: CheckedContinuation<Bool, Never>?
        init(_ continuation: CheckedContinuation<Bool, Never>) { self.continuation = continuation }
        func resume(_ value: Bool) {
            continuation?.resume(returning: value)
            continuation = nil
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
        // A profile's choice is stored; a private session's is kept in memory, so the next page of the site in that session follows it.
        if let host = SiteHost.normalized(page.status.url) {
            setRemembered(on ? nil : .deny, in: page.siteScope, host: host, key: .contentBlocking)
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
        blockingWanted(in: SiteScope(profileID: request.siteSettingsProfileID, store: request.store), url: request.url)
    }

    func blockingWanted(in scope: SiteScope, url: String) -> Bool {
        guard let host = SiteHost.normalized(url) else { return true }
        return rememberedDecision(in: scope, host: host, key: .contentBlocking) != .deny
    }

    /// Before a main-frame load to a new site, turns the page's rule lists on or off for that site (ruling R6).
    func updateBlocking(for page: LivePage, navigatingTo url: String) {
        guard let site = SiteHost.normalized(url), site != page.blockingHost else { return }
        page.blockingHost = site
        let wanted = blockingWanted(in: page.siteScope, url: url)
        guard wanted != page.isContentBlockingOn else { return }
        // TODO(R10): a pop-up or linked tab shares its opener's WKUserContentController (WebKit's configuration
        // carries it over), so switching one's lists would silently switch the other's. Such pages keep the
        // lists they have until per-page controllers exist; the explicit menu switch still applies to both.
        guard !sharesContentController(page) else { return }
        page.isContentBlockingOn = wanted
        attachRuleLists(to: page)
    }

    func sharesContentController(_ page: LivePage) -> Bool {
        let content = page.webView.configuration.userContentController
        return pages.values.contains { $0 !== page && $0.webView.configuration.userContentController === content }
    }

    func attachRuleLists(to page: LivePage) {
        let content = page.webView.configuration.userContentController
        content.removeAllContentRuleLists()
        if page.isContentBlockingOn {
            for list in contentBlocker.enabledLists() { content.add(list) }
        }
        for list in testRuleLists { content.add(list) }
    }

    // MARK: Zoom (decision 12)

    /// View ▸ Zoom In (⌘+): the next of Safari's levels, kept for the page's site.
    public func zoomIn(_ tabID: UUID) { changeZoom(tabID) { ZoomLevels.next(after: $0) } }

    /// View ▸ Zoom Out (⌘-).
    public func zoomOut(_ tabID: UUID) { changeZoom(tabID) { ZoomLevels.previous(before: $0) } }

    /// View ▸ Actual Size (⌘0): 100 %, and the site's stored zoom is removed.
    public func resetZoom(_ tabID: UUID) { changeZoom(tabID) { _ in ZoomLevels.defaultLevel } }

    /// Sets the page's zoom, keeps it for its site (100 % keeps nothing; a page with no web site keeps nothing), and moves the other open
    /// pages of that site and profile (or private session) to it at once, as Chrome does.
    private func changeZoom(_ tabID: UUID, _ step: (Double) -> Double) {
        guard let page = pages[tabID], !page.isClosed else { return }
        let level = step(page.zoom)
        page.setZoom(level)
        guard let site = page.siteKey else { return }
        setSiteValue(ZoomLevels.storedValue(level), for: page, host: site, key: .zoom)
        for other in pages.values where other !== page && other.siteScope == page.siteScope && other.siteKey == site {
            other.setZoom(level)
        }
    }

    /// On every main-frame commit: the committed site's stored zoom, or 100 % when none is stored.
    func applyStoredZoom(to page: LivePage) {
        guard !page.isClosed else { return }
        let stored = page.siteKey.flatMap { siteValue(for: page, host: $0, key: .zoom, as: Double.self) }
        let level = ZoomLevels.sanitized(stored)
        if page.zoom != level || page.webView.pageZoom != level { page.setZoom(level) }
    }

    // MARK: User agent (decision 24)

    /// Before every main-frame load: the destination site's stored agent, or WebKit's own string when none is stored (a file, a blank page
    /// and any other scheme have no site), so an agent never leaks to another site. Loads Stave starts itself (typed, stored, restored,
    /// linked tabs) call it before `load`, because the request's User-Agent header is built before the navigation policy runs on some systems
    /// (WebKit bug 313542). A page-started navigation is judged in `PageDelegate`, which sets it for the destination there (correct on macOS 27 and later, see `allowMainFrame`).
    func updateUserAgent(for page: LivePage, navigatingTo url: String) {
        page.setUserAgent(userAgentString(in: page.siteScope, url: url))
    }

    /// The `customUserAgent` a page of the scope gets for an address: nil for the default.
    func userAgentString(in scope: SiteScope, url: String) -> String? {
        guard let site = SiteHost.normalized(url) else { return nil }
        let agent = SiteUserAgent(stored: siteValue(in: scope, host: site, key: .userAgent, as: String.self))
        return UserAgent.string(for: agent, applicationName: applicationName, now: now())
    }

    // MARK: Site values

    /// A profile's values are stored; a private session's are kept in memory for the session only.
    func siteValue<V: Codable>(for page: LivePage, host: String, key: SiteValueKey, as type: V.Type) -> V? {
        siteValue(in: page.siteScope, host: host, key: key, as: type)
    }

    func setSiteValue<V: Codable>(_ value: V?, for page: LivePage, host: String, key: SiteValueKey) {
        setSiteValue(value, in: page.siteScope, host: host, key: key)
    }

    func siteValue<V: Codable>(in scope: SiteScope, host: String, key: SiteValueKey, as type: V.Type) -> V? {
        switch scope {
        case .profile(let profileID):
            return siteSettings.siteValue(profileID: profileID, host: host, key: key, as: type)
        case .privateSession(let store):
            return privateSiteValues[PrivateSiteValueKey(store: store, host: host, key: key)].flatMap { try? JSONDecoder().decode(V.self, from: $0) }
        }
    }

    func setSiteValue<V: Codable>(_ value: V?, in scope: SiteScope, host: String, key: SiteValueKey) {
        switch scope {
        case .profile(let profileID):
            siteSettings.setSiteValue(profileID: profileID, host: host, key: key, value)
        case .privateSession(let store):
            privateSiteValues[PrivateSiteValueKey(store: store, host: host, key: key)] = value.flatMap { try? JSONEncoder().encode($0) }
        }
    }

    // MARK: Camera, microphone and content blocking answers

    /// A profile's answers are site settings; a private window's are kept in memory for that window only.
    func rememberedMedia(for page: LivePage, host: String, key: SiteSettingKey) -> SiteDecision? {
        rememberedDecision(in: page.siteScope, host: host, key: key)
    }

    func rememberMedia(_ decision: SiteDecision, for page: LivePage, host: String, key: SiteSettingKey) {
        setRemembered(decision, in: page.siteScope, host: host, key: key)
    }

    func rememberedDecision(in scope: SiteScope, host: String, key: SiteSettingKey) -> SiteDecision? {
        switch scope {
        case .profile(let profileID): siteSettings.decision(profileID: profileID, host: host, key: key)
        case .privateSession(let store): privateMediaAnswers[PrivateMediaKey(store: store, host: host, key: key)]
        }
    }

    /// Nil removes the answer (the site asks again).
    func setRemembered(_ decision: SiteDecision?, in scope: SiteScope, host: String, key: SiteSettingKey) {
        switch scope {
        case .profile(let profileID):
            siteSettings.setDecision(profileID: profileID, host: host, key: key, decision)
        case .privateSession(let store):
            privateMediaAnswers[PrivateMediaKey(store: store, host: host, key: key)] = decision
        }
    }

    // MARK: Downloads

    func trackDownload(_ download: WKDownload, delegate: PageDelegate) {
        activeDownloads.track(download, delegate: delegate)
    }

    func beginDownload(_ download: WKDownload, delegate: PageDelegate, rowID: UUID, list: DownloadList, destination: URL, source: QuarantineSource?) {
        activeDownloads.begin(download, delegate: delegate, rowID: rowID, list: list, destination: destination, source: source)
    }

    /// Checked before every download's destination is given to WebKit, off the main thread.
    @ObservationIgnored let downloadsFolder = DownloadsFolderCheck()

    /// Seam for tests: whether WebKit has written bytes for a download.
    var downloadWroteBytes: @MainActor (WKDownload) -> Bool {
        get { activeDownloads.wroteBytes }
        set { activeDownloads.wroteBytes = newValue }
    }

    /// Seam for tests: how a download's file is quarantined.
    var markDownload: @MainActor (URL, QuarantineSource?) throws -> Void {
        get { activeDownloads.mark }
        set { activeDownloads.mark = newValue }
    }

    /// The names in the Downloads folder, read off the main thread. A seam so a test can hold the listing open while WebKit fails a download.
    @ObservationIgnored var folderListing: @Sendable (URL) async -> Set<String> = { await PageHost.existingNames(in: $0) }

    /// A free, reserved destination for a download's suggested name. The folder is listed off the main thread (`~/Downloads` can be slow,
    /// and the first touch may bring up macOS's folder question), then the name is chosen and reserved with no suspension in between.
    func reserveDestination(for suggestedFilename: String, in directory: URL) async -> URL {
        let listing = activeDownloads.beginListing()
        let existing = await folderListing(directory)
        return activeDownloads.reserve(DownloadFilename.sanitized(suggestedFilename), in: directory, existing: existing, listing: listing)
    }

    nonisolated static func existingNames(in directory: URL) async -> Set<String> {
        await Task.detached(priority: .userInitiated) {
            let names = (try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []
            return Set(names.map(ActiveDownloads.fold))
        }.value
    }

    func downloadHasFailedBeforeBegin(_ download: WKDownload) -> Bool {
        activeDownloads.hasFailedBeforeBegin(download)
    }

    /// Gives back a name `reserveDestination` reserved for a download that then never began.
    func releaseDestination(_ destination: URL) {
        activeDownloads.release(destination)
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
        page.scheduleTitleFlush = titleScheduler
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
        if thenTearDown {
            tearingDownStores[token] = page.store
            pending.onFinish = { [weak self] in self?.tearingDownStores[token] = nil }
        }
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
    /// Called once, when the page is torn down.
    var onFinish: (@MainActor () -> Void)?

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
        onFinish?()
        onFinish = nil
    }
}

struct PrivateMediaKey: Hashable {
    var store: DataStoreKey
    var host: String
    var key: SiteSettingKey
}

struct PrivateSiteValueKey: Hashable {
    var store: DataStoreKey
    var host: String
    var key: SiteValueKey
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
