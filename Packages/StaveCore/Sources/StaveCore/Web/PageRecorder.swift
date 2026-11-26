import Foundation

public enum PageEvent: Sendable, Equatable {
    case committed(url: String), title(String), favicon(String?), finished, stateChanged
    /// The URL changed within the same document (a fragment or `pushState`): title and favicon stay.
    case sameDocument(url: String)
}

public enum PageWrite: Sendable, Equatable {
    case navigation(url: String, title: String, faviconURL: String?)
    /// The caller reads `webView.interactionState` now and writes it.
    case interactionState
}

/// Turns page events into store writes (plan 3, decision 4): identical repeats are skipped, `interactionState` writes are throttled, and
/// title-only writes are coalesced to one per `titleInterval` (plan 5, Task 15), so a page that rewrites its title many times a second
/// costs the store a couple of writes. A value type that holds no references; the caller supplies the clock (`at:`) and a trailing write
/// (`pendingTitleDelay`) so nothing here sleeps.
public struct PageRecorder: Sendable {
    /// At most one title-only write per this many seconds.
    public static let titleInterval: TimeInterval = 0.5

    /// What the page shows now (the latest events).
    private var url: String
    private var title: String
    private var faviconURL: String?
    /// What was last written: a pending title that comes back to this is never written.
    private var written: Written
    private let stateInterval: TimeInterval
    private var lastStateWriteAt: Date?
    private var statePending = false
    private var lastNavigationWriteAt: Date?
    private var titlePending = false
    private var isClosed = false

    private struct Written: Equatable, Sendable {
        var url: String
        var title: String
        var faviconURL: String?
    }

    public init(url: String, title: String, faviconURL: String?, stateInterval: TimeInterval = 2) {
        self.url = url
        self.title = title
        self.faviconURL = faviconURL
        written = Written(url: url, title: title, faviconURL: faviconURL)
        self.stateInterval = stateInterval
    }

    /// A title-only change is waiting for its window to end. Its trailing write is due in `pendingTitleDelay`.
    public var hasPendingTitle: Bool { titlePending && !isClosed }

    /// Seconds until the pending title may be written (never negative), nil when none is pending.
    public func pendingTitleDelay(at now: Date) -> TimeInterval? {
        guard hasPendingTitle else { return nil }
        guard let last = lastNavigationWriteAt else { return 0 }
        return max(0, Self.titleInterval - now.timeIntervalSince(last))
    }

    public mutating func record(_ event: PageEvent, at now: Date) -> [PageWrite] {
        guard !isClosed else { return [] }
        switch event {
        case .committed(let newURL):
            return updatePage(url: newURL, title: "", faviconURL: nil, at: now)
        case .sameDocument(let newURL):
            return updatePage(url: newURL, title: title, faviconURL: faviconURL, at: now)
        case .title(let newTitle):
            return updatePage(url: url, title: newTitle, faviconURL: faviconURL, at: now)
        case .favicon(let newFavicon):
            return updatePage(url: url, title: title, faviconURL: newFavicon, at: now)
        case .finished:
            return flush(at: now)
        case .stateChanged:
            if let last = lastStateWriteAt, now.timeIntervalSince(last) < stateInterval {
                statePending = true
                return []
            }
            return emitState(at: now)
        }
    }

    /// Emits the pending title and the pending `interactionState` write, if any, whatever the interval says: a tab deselected, an unloaded
    /// page, a closing window and quit all come here, so no title is lost.
    public mutating func flush(at now: Date) -> [PageWrite] {
        guard !isClosed else { return [] }
        var writes: [PageWrite] = []
        if titlePending { writes += emitNavigation(at: now) }
        if statePending { writes += emitState(at: now) }
        return writes
    }

    /// Emits only the pending title, if any: the trailing write and a closing tab need the title, and a pending `interactionState` keeps
    /// its own two-second limit.
    public mutating func flushTitle(at now: Date) -> [PageWrite] {
        guard !isClosed, titlePending else { return [] }
        return emitNavigation(at: now)
    }

    /// After this, every `record` and `flush` returns no writes.
    public mutating func close() {
        isClosed = true
        titlePending = false
    }

    private mutating func emitState(at now: Date) -> [PageWrite] {
        statePending = false
        lastStateWriteAt = now
        return [.interactionState]
    }

    private mutating func updatePage(url newURL: String, title newTitle: String, faviconURL newFavicon: String?, at now: Date) -> [PageWrite] {
        guard newURL != url || newTitle != title || newFavicon != faviconURL else { return [] }
        // Only a title-only change waits: a new address or favicon, or a first write, goes out at once with the latest title.
        let titleOnly = newURL == url && newFavicon == faviconURL
        url = newURL
        title = newTitle
        faviconURL = newFavicon
        if titleOnly, let last = lastNavigationWriteAt, now.timeIntervalSince(last) < Self.titleInterval {
            titlePending = true
            return []
        }
        return emitNavigation(at: now)
    }

    /// Writes what the page shows now, unless that is what was last written.
    private mutating func emitNavigation(at now: Date) -> [PageWrite] {
        titlePending = false
        let current = Written(url: url, title: title, faviconURL: faviconURL)
        guard current != written else { return [] }
        written = current
        lastNavigationWriteAt = now
        return [.navigation(url: url, title: title, faviconURL: faviconURL)]
    }
}
