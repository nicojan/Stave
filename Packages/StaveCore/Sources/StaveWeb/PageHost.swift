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

    @ObservationIgnored private let stores: WebDataStores
    @ObservationIgnored private let contentBlocker: ContentBlockerManager
    @ObservationIgnored private let siteSettings: SiteSettingsSource
    @ObservationIgnored private let applicationName: String
    @ObservationIgnored private let now: () -> Date
    @ObservationIgnored private lazy var faviconRelay = FaviconRelay(host: self)
    /// In memory only (decision 16).
    @ObservationIgnored private var snapshots: [UUID: NSImage] = [:]
    /// The latest snapshot asked for per tab; an older or cancelled one never lands.
    @ObservationIgnored private var snapshotTokens: [UUID: UUID] = [:]
    @ObservationIgnored private var hibernationTask: Task<Void, Never>?
    /// Seam for tests: whether a page is playing media or using the camera or microphone.
    @ObservationIgnored var mediaCheck: @MainActor (WKWebView) async -> Bool = PageHost.isBusyWithMedia

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
            ruleLists: blocking ? contentBlocker.enabledLists() : [],
            applicationName: applicationName,
            messageHandler: faviconRelay
        )
        let webView = WKWebView(frame: .zero, configuration: configuration)
        let page = LivePage(request: request, webView: webView, writer: writer, isContentBlockingOn: blocking, now: now)
        insert(page)
        page.start(request)
        return page
    }

    public func existingPage(_ tabID: UUID) -> LivePage? {
        pages[tabID]
    }

    /// Takes over a web view WebKit created (a linked tab or pop-up), keeping its configuration and opener.
    public func adopt(_ webView: WKWebView, as request: PageRequest, writer: PageWriter) -> LivePage {
        if pages[request.tabID] != nil { close(request.tabID) }
        // The configuration (and its rule lists) came from the opener and is left as WebKit made it.
        let page = LivePage(request: request, webView: webView, writer: writer, isContentBlockingOn: blockingWanted(for: request), now: now)
        insert(page)
        return page
    }

    public func markShown(_ tabID: UUID, _ shown: Bool) {
        guard let page = pages[tabID] else { return }
        page.isShown = shown
        page.lastShownAt = now()
    }

    /// Flushes pending state, keeps a snapshot, then tears the page down.
    public func unload(_ tabID: UUID) {
        guard let page = pages.removeValue(forKey: tabID) else { return }
        page.flush()
        page.close()
        captureSnapshot(of: page, thenTearDown: true)
    }

    /// Ends the page without flushing: its tab is gone, so nothing more is written for it.
    public func close(_ tabID: UUID) {
        guard let page = pages.removeValue(forKey: tabID) else { return }
        page.close()
        snapshots[tabID] = nil
        snapshotTokens[tabID] = nil
        Self.tearDown(page)
    }

    /// The last snapshot of the tab's page, kept in memory.
    public func snapshot(for tabID: UUID) -> NSImage? {
        snapshots[tabID]
    }

    /// Replaces the tab's snapshot with what its page shows now (when its window shows another tab or resigns key).
    public func captureSnapshot(_ tabID: UUID) {
        guard let page = pages[tabID] else { return }
        captureSnapshot(of: page, thenTearDown: false)
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
            infos.append(LivePageInfo(id: page.tabID, isShown: page.isShown, lastShownAt: page.lastShownAt, isBusyWithMedia: busy))
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
        page.webView.reload()
    }

    /// Attaches lists that compiled after pages were made; they apply from each page's next load.
    public func reattachRuleLists() {
        for page in pages.values where page.isContentBlockingOn {
            attachRuleLists(to: page)
        }
    }

    func blockingWanted(for request: PageRequest) -> Bool {
        guard let profileID = request.siteSettingsProfileID, let host = SiteHost.normalized(request.url) else { return true }
        return siteSettings.decision(profileID: profileID, host: host, key: .contentBlocking) != .deny
    }

    private func attachRuleLists(to page: LivePage) {
        let content = page.webView.configuration.userContentController
        content.removeAllContentRuleLists()
        guard page.isContentBlockingOn else { return }
        for list in contentBlocker.enabledLists() { content.add(list) }
    }

    // MARK: Internals

    func receivedFavicon(_ href: String, from webView: WKWebView?) {
        guard let webView, let page = pages.values.first(where: { $0.webView === webView }) else { return }
        page.record(.favicon(href))
    }

    private func insert(_ page: LivePage) {
        pages[page.tabID] = page
        startHibernationIfNeeded()
    }

    /// Snapshots the page; when `thenTearDown`, the web view is kept until the snapshot is taken, then torn down.
    private func captureSnapshot(of page: LivePage, thenTearDown: Bool) {
        let token = UUID()
        let tabID = page.tabID
        snapshotTokens[tabID] = token
        Task { [weak self] in
            let image = try? await page.webView.takeSnapshot(configuration: nil)
            if let self, self.snapshotTokens[tabID] == token {
                self.snapshotTokens[tabID] = nil
                if let image { self.snapshots[tabID] = image }
            }
            if thenTearDown { PageHost.tearDown(page) }
        }
    }

    private static func tearDown(_ page: LivePage) {
        page.webView.stopLoading()
        page.webView.removeFromSuperview()
    }
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
