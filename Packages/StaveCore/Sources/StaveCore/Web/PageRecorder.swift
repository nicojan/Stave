import Foundation

public enum PageEvent: Sendable, Equatable {
    case committed(url: String), title(String), favicon(String?), finished, stateChanged
}

public enum PageWrite: Sendable, Equatable {
    case navigation(url: String, title: String, faviconURL: String?)
    /// The caller reads `webView.interactionState` now and writes it.
    case interactionState
}

/// Turns page events into store writes (plan 3, decision 4): identical repeats are skipped and
/// `interactionState` writes are throttled. A value type that holds no references.
public struct PageRecorder: Sendable {
    private var url: String
    private var title: String
    private var faviconURL: String?
    private let stateInterval: TimeInterval
    private var lastStateWriteAt: Date?
    private var statePending = false
    private var isClosed = false

    public init(url: String, title: String, faviconURL: String?, stateInterval: TimeInterval = 2) {
        self.url = url
        self.title = title
        self.faviconURL = faviconURL
        self.stateInterval = stateInterval
    }

    public mutating func record(_ event: PageEvent, at now: Date) -> [PageWrite] {
        guard !isClosed else { return [] }
        switch event {
        case .committed(let newURL):
            return updatePage(url: newURL, title: "", faviconURL: nil)
        case .title(let newTitle):
            return updatePage(url: url, title: newTitle, faviconURL: faviconURL)
        case .favicon(let newFavicon):
            return updatePage(url: url, title: title, faviconURL: newFavicon)
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

    /// Emits the pending `interactionState` write, if any.
    public mutating func flush(at now: Date) -> [PageWrite] {
        guard !isClosed, statePending else { return [] }
        return emitState(at: now)
    }

    /// After this, every `record` and `flush` returns no writes.
    public mutating func close() {
        isClosed = true
    }

    private mutating func emitState(at now: Date) -> [PageWrite] {
        statePending = false
        lastStateWriteAt = now
        return [.interactionState]
    }

    private mutating func updatePage(url newURL: String, title newTitle: String, faviconURL newFavicon: String?) -> [PageWrite] {
        guard newURL != url || newTitle != title || newFavicon != faviconURL else { return [] }
        url = newURL
        title = newTitle
        faviconURL = newFavicon
        return [.navigation(url: url, title: title, faviconURL: faviconURL)]
    }
}
