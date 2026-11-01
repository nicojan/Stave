import Foundation

public struct LivePageInfo: Sendable, Equatable {
    public let id: UUID
    public let isShown: Bool
    public let lastShownAt: Date
    public let isBusyWithMedia: Bool
    /// The page opened pop-ups that are still open; their `window.opener` needs it (ruling R14).
    public let hasOpenPopups: Bool

    public init(id: UUID, isShown: Bool, lastShownAt: Date, isBusyWithMedia: Bool, hasOpenPopups: Bool = false) {
        self.id = id
        self.isShown = isShown
        self.lastShownAt = lastShownAt
        self.isBusyWithMedia = isBusyWithMedia
        self.hasOpenPopups = hasOpenPopups
    }
}

/// Which unshown live pages to unload (plan 3, decision 8).
public enum HibernationPolicy {
    public static let idleLimit: TimeInterval = 1800
    public static let liveLimit = 24
    public static let interval: TimeInterval = 60

    /// Each ID at most once, oldest `lastShownAt` first. Shown pages, pages busy with media and openers with open pop-ups are never returned.
    public static func pagesToUnload(_ pages: [LivePageInfo], now: Date) -> [UUID] {
        let eligible = pages
            .filter { !$0.isShown && !$0.isBusyWithMedia && !$0.hasOpenPopups }
            .sorted { $0.lastShownAt < $1.lastShownAt }
        let idle = eligible.filter { now.timeIntervalSince($0.lastShownAt) >= idleLimit }
        let overflow = max(0, pages.count - idle.count - liveLimit)
        let extra = eligible.filter { page in !idle.contains { $0.id == page.id } }.prefix(overflow)
        return (idle + extra).sorted { $0.lastShownAt < $1.lastShownAt }.map(\.id)
    }
}
