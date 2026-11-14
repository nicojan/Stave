import Foundation

/// Links from other apps that arrive before launch completes (decision 7). They are opened, in arrival order, once the saved windows are
/// restored, or handed back for the report when launch fails: never dropped.
@MainActor
public final class PendingLinks {
    private var queued: [URL] = []

    public init() {}

    public func enqueue(_ urls: [URL]) {
        queued = queued + urls
    }

    /// The queued links in arrival order; the queue is empty afterwards. Called once the saved windows are restored.
    public func drain() -> [URL] {
        let links = queued
        queued = []
        return links
    }

    /// Every queued link, for the launch-failure report; the queue is empty afterwards.
    public func failAll() -> [URL] {
        drain()
    }
}
