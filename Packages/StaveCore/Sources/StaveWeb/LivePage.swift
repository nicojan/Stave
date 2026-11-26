import Foundation
import Observation
import StaveCore
import WebKit

/// What the browser chrome shows about a page.
public struct PageStatus: Equatable, Sendable {
    public var isLoading: Bool
    public var progress: Double
    public var canGoBack: Bool
    public var canGoForward: Bool
    public var url: String
    public var title: String
    public var failure: PageFailure?

    public init(isLoading: Bool = false, progress: Double = 0, canGoBack: Bool = false, canGoForward: Bool = false, url: String = "", title: String = "", failure: PageFailure? = nil) {
        self.isLoading = isLoading
        self.progress = progress
        self.canGoBack = canGoBack
        self.canGoForward = canGoForward
        self.url = url
        self.title = title
        self.failure = failure
    }
}

/// The `PageStatus` fields the menu bar reads (the page menu, the Find menu and the tab shortcuts), and nothing else. The menus observe this
/// instead of `status`, so a title change or a progress tick, which no menu item reads, doesn't rebuild them (plan 5, Task 15).
public struct PageMenuFields: Equatable, Sendable {
    public var isLoading: Bool
    public var canGoBack: Bool
    public var canGoForward: Bool
    public var url: String
    public var hasFailure: Bool

    public init(isLoading: Bool, canGoBack: Bool, canGoForward: Bool, url: String, hasFailure: Bool) {
        self.isLoading = isLoading
        self.canGoBack = canGoBack
        self.canGoForward = canGoForward
        self.url = url
        self.hasFailure = hasFailure
    }

    init(_ status: PageStatus) {
        self.init(isLoading: status.isLoading, canGoBack: status.canGoBack, canGoForward: status.canGoForward, url: status.url, hasFailure: status.failure != nil)
    }
}

/// Everything the host needs to make or adopt a tab's page.
public struct PageRequest: Sendable, Equatable {
    public var tabID: UUID
    public var store: DataStoreKey
    /// Nil in a private window.
    public var siteSettingsProfileID: UUID?
    public var url: String
    public var title: String
    public var faviconURL: String?
    public var interactionState: Data?
    /// The user opened this page just now (a ⌘-click or "Open Link in New Tab" link). False for a page Stave reopens by itself (a tab
    /// restored at launch, a stored tab shown again), which then downloads nothing until the user acts on it.
    public var openedByUser: Bool

    public init(tabID: UUID, store: DataStoreKey, siteSettingsProfileID: UUID?, url: String, title: String, faviconURL: String?, interactionState: Data?, openedByUser: Bool = false) {
        self.tabID = tabID
        self.store = store
        self.siteSettingsProfileID = siteSettingsProfileID
        self.url = url
        self.title = title
        self.faviconURL = faviconURL
        self.interactionState = interactionState
        self.openedByUser = openedByUser
    }
}

/// Where a page's writes go. The writer drops `StoreError.notFound` (a tab that no longer exists) silently.
public protocol PageWriter: AnyObject {
    @MainActor func writeNavigation(tabID: UUID, url: String, title: String, faviconURL: String?)
    @MainActor func writeInteractionState(tabID: UUID, _ state: Data?)
    /// A visit to a web page committed (decision 9). Never called for a private page (no `siteSettingsProfileID`).
    @MainActor func recordVisit(profileID: UUID, url: String, title: String, at date: Date)
    /// The page reported the title of the visit last recorded for `url`.
    @MainActor func updateVisitTitle(profileID: UUID, url: String, title: String)
}

/// One tab's web view: KVO turns into `status` and, through the `PageRecorder`, into writes.
@MainActor
@Observable
public final class LivePage {
    public let tabID: UUID
    public let webView: WKWebView
    public let store: DataStoreKey
    /// Nil in a private window.
    public let siteSettingsProfileID: UUID?
    public internal(set) var status: PageStatus {
        didSet { syncMenuFields() }
    }
    /// The part of `status` the menus read. Written only when it changes, so observing it ignores every other status change.
    public private(set) var menuFields: PageMenuFields
    public internal(set) var isContentBlockingOn: Bool
    /// The page's zoom (`pageZoom`), set only through `setZoom` so the menus can follow it (decision 12).
    public private(set) var zoom = ZoomLevels.defaultLevel

    @ObservationIgnored weak var writer: PageWriter?
    @ObservationIgnored private var recorder: PageRecorder
    @ObservationIgnored private var observations: [NSKeyValueObservation] = []
    @ObservationIgnored private let now: () -> Date
    /// Asks for `work` to run after the given seconds (the title's trailing write). The host sets it, so tests can run it by hand.
    @ObservationIgnored var scheduleTitleFlush: @MainActor (TimeInterval, @escaping @MainActor () -> Void) -> Void = LivePage.sleepThenRun
    /// A trailing title write has been asked for and hasn't run yet: no second one is asked for.
    @ObservationIgnored private var titleFlushScheduled = false
    @ObservationIgnored public private(set) var isClosed = false
    /// Test hook: the stored `interactionState` was set on the web view instead of loading the URL.
    @ObservationIgnored private(set) var didRestoreState = false
    /// While true, KVO changes are ignored and nothing is written: the restored item was refused or is
    /// still being checked, or the web content process crashed. The next commit ends it.
    @ObservationIgnored private var holdsWrites = false
    /// The next main-frame navigation is the one a restored `interactionState` starts; the page
    /// delegate judges it with source `.restored` (ruling R7).
    @ObservationIgnored var restorePending = false
    /// The site whose content-blocking setting the page's rule lists follow (ruling R6).
    @ObservationIgnored var blockingHost: String?
    /// The last URL written as committed; a URL change with nothing loading is a same-document one.
    @ObservationIgnored private var lastCommittedURL: String?
    /// How many main-frame commits this page has seen: a new value is a new document (the app's dialog gate resets on it).
    @ObservationIgnored public private(set) var commitCount = 0
    @ObservationIgnored var isShown = false
    /// Stave loaded this page by itself (a restored tab, or a stored tab shown again), and the user hasn't clicked, typed, reloaded or
    /// navigated in it since: it may not download (walkthrough fix 2), so a reopened page can't save a file with no click.
    @ObservationIgnored public private(set) var awaitsUserAction = false
    @ObservationIgnored var lastShownAt: Date
    /// The folder (or the file alone) this tab's opened file may read, set by `PageHost.loadFile`. In memory only, never stored: a user-clicked
    /// `file:` link inside it opens (decision 6).
    @ObservationIgnored public internal(set) var grantedFolder: String?
    /// The resolved path of the file `PageHost.loadFile` just started loading: its navigation is judged as `.openedFile`.
    @ObservationIgnored var pendingOpenedFile: String?
    /// The address of the visit this document recorded, and the title last written for it; nil when the document is no visit.
    @ObservationIgnored private var visitURL: String?
    @ObservationIgnored private var visitTitle = ""

    init(request: PageRequest, webView: WKWebView, writer: PageWriter, isContentBlockingOn: Bool, now: @escaping () -> Date) {
        tabID = request.tabID
        self.webView = webView
        store = request.store
        siteSettingsProfileID = request.siteSettingsProfileID
        let initial = PageStatus(url: request.url, title: request.title)
        status = initial
        menuFields = PageMenuFields(initial)
        self.isContentBlockingOn = isContentBlockingOn
        self.writer = writer
        recorder = PageRecorder(url: request.url, title: request.title, faviconURL: request.faviconURL)
        self.now = now
        lastShownAt = now()
        blockingHost = SiteHost.normalized(request.url)
        observe()
        (webView as? PageWebView)?.onUserAction = { [weak self] in self?.userActed() }
    }

    /// The user clicked or typed in the page, or reloaded, went back or forward, or typed an address for it. The app calls it for a user
    /// command that loads the page without `reload()` (Reload after a failed first load).
    public func userActed() {
        awaitsUserAction = false
    }

    /// Restores the stored back/forward list, or loads the stored URL once the navigation policy allows it.
    func start(_ request: PageRequest) {
        awaitsUserAction = !request.openedByUser && (request.interactionState != nil || !request.url.isEmpty)
        if let state = request.interactionState, restore(state) { return }
        guard !request.url.isEmpty else { return }
        switch NavigationPolicy.decide(request.url, isMainFrame: true, source: .stored) {
        case .allow:
            guard let url = URL(string: request.url) else {
                status.failure = .refused(url: request.url)
                return
            }
            webView.load(URLRequest(url: url))
        case .refuse(let failure):
            status.failure = failure ?? .refused(url: request.url)
        case .askToOpenExternally:
            // A stored URL never hands off to another app.
            status.failure = .refused(url: request.url)
        }
    }

    /// Sets the stored back/forward list and gates its current item like any restored URL. The page
    /// delegate decides the restore navigation (`restorePending`) before it loads (stopping it afterwards is
    /// too late: a `data:` page has already run). KVO is held until the item is allowed; a refused item is
    /// shown as refused and the hold stays until a later navigation commits, so nothing about it is written.
    /// False when the state holds no current item, or no delegate is there to gate it, so the stored URL is
    /// used instead.
    private func restore(_ state: Data) -> Bool {
        guard webView.navigationDelegate is PageDelegate else { return false }
        holdsWrites = true
        restorePending = true
        webView.interactionState = state
        didRestoreState = true
        guard let current = webView.backForwardList.currentItem?.url.absoluteString else {
            webView.stopLoading()
            restorePending = false
            holdsWrites = false
            return false
        }
        if case .refuse(let failure) = NavigationPolicy.decide(current, isMainFrame: true, source: .restored) {
            status.failure = failure ?? .refused(url: current)
            return true
        }
        holdsWrites = false
        status.url = current
        updateNavigationState()
        return true
    }

    /// A main-frame navigation committed (ruling R5: the stored URL and title change here, not when the
    /// URL first changes, so a load that fails never blanks them). Ends any hold and clears the failure.
    func committed() {
        guard !isClosed else { return }
        commitCount += 1
        restorePending = false
        holdsWrites = false
        status.failure = nil
        updateNavigationState()
        guard let url = webView.url?.absoluteString, !url.isEmpty else { return }
        status.url = url
        lastCommittedURL = url
        record(.committed(url: url))
        record(.stateChanged)
        recordVisit(url)
    }

    /// History (decision 9): an http or https commit in a normal window is a visit. A private page (no profile) never records one, and
    /// neither does a page Stave loaded by itself (a restored tab, a stored tab shown again) until the user acts on it. The title follows
    /// in `updateVisitTitle`, once the page reports it.
    private func recordVisit(_ url: String) {
        visitURL = nil
        visitTitle = ""
        guard let profileID = siteSettingsProfileID, !awaitsUserAction, HistoryRules.isRecordable(url), let writer else { return }
        visitURL = url
        writer.recordVisit(profileID: profileID, url: url, title: "", at: now())
    }

    private func updateVisitTitle(_ title: String) {
        guard let profileID = siteSettingsProfileID, let url = visitURL, !title.isEmpty, title != visitTitle, let writer else { return }
        visitTitle = title
        writer.updateVisitTitle(profileID: profileID, url: url, title: title)
    }

    func setZoom(_ level: Double) {
        zoom = level
        webView.pageZoom = level
    }

    /// The site key (`SiteHost.normalized`) of the document the web view holds, else of the address shown; nil with no web site.
    var siteKey: String? {
        SiteHost.normalized(webView.url?.absoluteString ?? status.url)
    }

    /// The site the per-site panel is for: the host of the address the page shows (`status.url`, the field the View menu and the address
    /// field's site button read), so the panel, the button and the menu item always agree. Nil with no web site.
    var panelSiteKey: String? { SitePanelSite.host(forPageURL: status.url) }

    /// The web content process ended. Shown as crashed; nothing is written until a new load commits.
    func processTerminated() {
        guard !isClosed else { return }
        holdsWrites = true
        restorePending = false
        status.failure = .crashed
        status.isLoading = false
    }

    /// Feeds one event to the recorder and passes its writes on. Does nothing once closed, or while writes are held (a refused restore,
    /// a crashed page): such a page writes nothing until a new load commits.
    func record(_ event: PageEvent) {
        guard !isClosed, !holdsWrites else { return }
        perform(recorder.record(event, at: now()))
        scheduleTitleFlushIfNeeded()
    }

    /// A title-only change that waited gets one trailing write when its window ends, so the stored title never lags for long.
    private func scheduleTitleFlushIfNeeded() {
        guard !titleFlushScheduled, let delay = recorder.pendingTitleDelay(at: now()) else { return }
        titleFlushScheduled = true
        scheduleTitleFlush(delay) { [weak self] in
            guard let self else { return }
            titleFlushScheduled = false
            flushTitle()
        }
    }

    static func sleepThenRun(_ seconds: TimeInterval, _ work: @escaping @MainActor () -> Void) {
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(seconds))
            work()
        }
    }

    private func syncMenuFields() {
        let fields = PageMenuFields(status)
        if fields != menuFields { menuFields = fields }
    }

    /// Writes any throttled `interactionState` now. Nothing while writes are held: the web view's state then is the crashed or refused
    /// page's, not one worth keeping.
    func flush() {
        guard !isClosed, !holdsWrites else { return }
        perform(recorder.flush(at: now()))
    }

    /// Writes only the pending title now (the trailing write, a tab about to be archived). Its pending `interactionState` is left to its
    /// own two-second limit.
    func flushTitle() {
        guard !isClosed, !holdsWrites else { return }
        perform(recorder.flushTitle(at: now()))
    }

    /// Stops every write and observation. Nothing pending is flushed.
    func close() {
        recorder.close()
        isClosed = true
        observations.forEach { $0.invalidate() }
        observations = []
        writer = nil
    }

    private func perform(_ writes: [PageWrite]) {
        guard let writer else { return }
        for write in writes {
            switch write {
            case .navigation(let url, let title, let faviconURL):
                writer.writeNavigation(tabID: tabID, url: url, title: title, faviconURL: faviconURL)
            case .interactionState:
                writer.writeInteractionState(tabID: tabID, webView.interactionState as? Data)
            }
        }
    }

    private func observe() {
        observations = [
            webView.observe(\.url, options: [.new]) { [weak self] _, _ in
                MainActor.assumeIsolated { self?.urlChanged() }
            },
            webView.observe(\.title, options: [.new]) { [weak self] _, _ in
                MainActor.assumeIsolated { self?.titleChanged() }
            },
            webView.observe(\.isLoading, options: [.new]) { [weak self] _, _ in
                MainActor.assumeIsolated { self?.loadingChanged() }
            },
            webView.observe(\.estimatedProgress, options: [.new]) { [weak self] _, _ in
                MainActor.assumeIsolated { self?.updateNavigationState() }
            },
            webView.observe(\.canGoBack, options: [.new]) { [weak self] _, _ in
                MainActor.assumeIsolated { self?.updateNavigationState() }
            },
            webView.observe(\.canGoForward, options: [.new]) { [weak self] _, _ in
                MainActor.assumeIsolated { self?.updateNavigationState() }
            },
        ]
    }

    /// The URL shown follows KVO. A load's URL is written on commit; a change with nothing loading is a
    /// same-document one (fragment, `pushState`), written here keeping title and favicon.
    private func urlChanged() {
        guard !isClosed, !holdsWrites, let url = webView.url?.absoluteString, !url.isEmpty else { return }
        status.url = url
        guard !webView.isLoading else { return }
        recordSameDocument(url)
    }

    /// A same-document URL change (pushState, a fragment) ends the recorded visit's title window: a single-page site's later titles
    /// belong to its later addresses, never to the committed one's row. Those addresses are no visits (decision 9 records commits).
    private func recordSameDocument(_ url: String) {
        guard lastCommittedURL != nil, url != lastCommittedURL else { return }
        visitURL = nil
        visitTitle = ""
        lastCommittedURL = url
        record(.sameDocument(url: url))
        record(.stateChanged)
    }

    private func titleChanged() {
        guard !isClosed, !holdsWrites else { return }
        let title = webView.title ?? ""
        status.title = title
        record(.title(title))
        updateVisitTitle(title)
    }

    private func loadingChanged() {
        guard !isClosed, !holdsWrites else { return }
        updateNavigationState()
        // Nothing committed (the first load failed): the stored URL, title and state stay as they are.
        guard !webView.isLoading, lastCommittedURL != nil else { return }
        // A same-document change made while the page was still loading.
        if let url = webView.url?.absoluteString, !url.isEmpty { recordSameDocument(url) }
        // A same-URL commit (reload) blanks the recorder's title; this heals it (ruling R4).
        record(.title(webView.title ?? ""))
        updateVisitTitle(webView.title ?? "")
        record(.stateChanged)
        record(.finished)
    }

    private func updateNavigationState() {
        guard !isClosed, !holdsWrites else { return }
        status.isLoading = webView.isLoading
        status.progress = webView.estimatedProgress
        status.canGoBack = webView.canGoBack
        status.canGoForward = webView.canGoForward
    }
}
