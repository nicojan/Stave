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

    public init(tabID: UUID, store: DataStoreKey, siteSettingsProfileID: UUID?, url: String, title: String, faviconURL: String?, interactionState: Data?) {
        self.tabID = tabID
        self.store = store
        self.siteSettingsProfileID = siteSettingsProfileID
        self.url = url
        self.title = title
        self.faviconURL = faviconURL
        self.interactionState = interactionState
    }
}

/// Where a page's writes go. The writer drops `StoreError.notFound` (a tab that no longer exists) silently.
public protocol PageWriter: AnyObject {
    @MainActor func writeNavigation(tabID: UUID, url: String, title: String, faviconURL: String?)
    @MainActor func writeInteractionState(tabID: UUID, _ state: Data?)
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
    public internal(set) var status: PageStatus
    public internal(set) var isContentBlockingOn: Bool

    @ObservationIgnored weak var writer: PageWriter?
    @ObservationIgnored private var recorder: PageRecorder
    @ObservationIgnored private var observations: [NSKeyValueObservation] = []
    @ObservationIgnored private let now: () -> Date
    @ObservationIgnored private(set) var isClosed = false
    /// Test hook: the stored `interactionState` was set on the web view instead of loading the URL.
    @ObservationIgnored private(set) var didRestoreState = false
    @ObservationIgnored var isShown = false
    @ObservationIgnored var lastShownAt: Date

    init(request: PageRequest, webView: WKWebView, writer: PageWriter, isContentBlockingOn: Bool, now: @escaping () -> Date) {
        tabID = request.tabID
        self.webView = webView
        store = request.store
        siteSettingsProfileID = request.siteSettingsProfileID
        status = PageStatus(url: request.url, title: request.title)
        self.isContentBlockingOn = isContentBlockingOn
        self.writer = writer
        recorder = PageRecorder(url: request.url, title: request.title, faviconURL: request.faviconURL)
        self.now = now
        lastShownAt = now()
        observe()
    }

    /// Restores the stored back/forward list, or loads the stored URL once the navigation policy allows it.
    func start(_ request: PageRequest) {
        if let state = request.interactionState {
            webView.interactionState = state
            didRestoreState = true
            return
        }
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

    /// Feeds one event to the recorder and passes its writes on. Does nothing once closed.
    func record(_ event: PageEvent) {
        guard !isClosed else { return }
        perform(recorder.record(event, at: now()))
    }

    /// Writes any throttled `interactionState` now.
    func flush() {
        guard !isClosed else { return }
        perform(recorder.flush(at: now()))
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

    private func urlChanged() {
        guard !isClosed, let url = webView.url?.absoluteString, !url.isEmpty else { return }
        status.url = url
        record(.committed(url: url))
        record(.stateChanged)
    }

    private func titleChanged() {
        guard !isClosed else { return }
        let title = webView.title ?? ""
        status.title = title
        record(.title(title))
    }

    private func loadingChanged() {
        guard !isClosed else { return }
        updateNavigationState()
        guard !webView.isLoading else { return }
        // A same-URL commit (reload) blanks the recorder's title; this heals it (ruling R4).
        record(.title(webView.title ?? ""))
        record(.stateChanged)
        record(.finished)
    }

    private func updateNavigationState() {
        guard !isClosed else { return }
        status.isLoading = webView.isLoading
        status.progress = webView.estimatedProgress
        status.canGoBack = webView.canGoBack
        status.canGoForward = webView.canGoForward
    }
}
