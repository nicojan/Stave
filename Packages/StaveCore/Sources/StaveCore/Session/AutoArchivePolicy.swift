import Foundation

/// "Archive idle tabs after" (decision 34, question 27): off by default, following Arc.
public enum AutoArchiveAfter: String, Codable, Sendable, CaseIterable {
    case never, hours12, day1, days7, days30

    /// The setting's label in Settings ▸ Tabs.
    public static let settingTitle = "Archive idle tabs after"

    public var title: String {
        switch self {
        case .never: "Never"
        case .hours12: "12 hours"
        case .day1: "1 day"
        case .days7: "7 days"
        case .days30: "30 days"
        }
    }

    /// How long a tab may go unviewed; nil for `.never`, which archives nothing.
    public var interval: TimeInterval? {
        let hour: TimeInterval = 3600
        switch self {
        case .never: return nil
        case .hours12: return 12 * hour
        case .day1: return 24 * hour
        case .days7: return 7 * 24 * hour
        case .days30: return 30 * 24 * hour
        }
    }
}

/// What the policy needs to know about one tab; read from the store by `archiveIdleTabs`.
public struct AutoArchiveCandidate: Sendable, Equatable {
    public let tabID: UUID
    public let section: SlotSection
    public let slotKind: SlotKind
    public let lastActiveAt: Date

    public init(tabID: UUID, section: SlotSection, slotKind: SlotKind, lastActiveAt: Date) {
        self.tabID = tabID; self.section = section; self.slotKind = slotKind; self.lastActiveAt = lastActiveAt
    }
}

/// Which tabs go to the archive when idle. Pure.
public enum AutoArchivePolicy {
    /// Only a regular tab in a plain slot, not viewed for longer than the limit. Never a pinned tab, an Essential, a tab shown in any
    /// window, or a busy one (playing media, holding pop-ups, downloading, a JavaScript dialog waiting). A split slot stays out until
    /// split-slot archiving (2.x): `closeTab` deletes the whole slot and would take the partner tab with it, unarchived. Nothing for `.never`.
    public static func toArchive(
        _ candidates: [AutoArchiveCandidate], now: Date, limit: AutoArchiveAfter, shown: Set<UUID>, busy: Set<UUID>
    ) -> [UUID] {
        guard let interval = limit.interval else { return [] }
        return candidates
            .filter { candidate in
                candidate.section == .regular && candidate.slotKind == .tab
                    && now.timeIntervalSince(candidate.lastActiveAt) > interval
                    && !shown.contains(candidate.tabID) && !busy.contains(candidate.tabID)
            }
            .map(\.tabID)
    }
}

/// Orders the check against launch: one asked for before the saved windows are restored (and their selected tabs registered with
/// `LivePageRegistry`) runs nothing, and is run once, when launch completes. The app's timer calls it, so the ordering is tested without the app.
@MainActor
public final class AutoArchiveSchedule {
    /// How often the check runs while Stave is open.
    public static let interval: TimeInterval = 900

    private let check: @MainActor () -> Void
    private var isLaunchComplete = false
    private var isCheckWaiting = false

    public init(check: @escaping @MainActor () -> Void) {
        self.check = check
    }

    /// Runs the check now, or (before launch completes) remembers to run it then.
    public func requestCheck() {
        guard isLaunchComplete else { isCheckWaiting = true; return }
        check()
    }

    /// The saved windows are restored. Runs a check that was asked for earlier, once; later calls run nothing.
    public func launchCompleted() {
        guard !isLaunchComplete else { return }
        isLaunchComplete = true
        guard isCheckWaiting else { return }
        isCheckWaiting = false
        check()
    }
}

/// Notices a wall clock that jumped between two checks (the user changed it, or a bad network time arrived), because idle time is measured
/// with the wall clock and a jump forward would make every tab look old at once. The monotonic clock is the reference: it keeps counting
/// through sleep, so a Mac that slept overnight is not a jump (sleep still counts as idle, decision 34). A jump skips that check and the
/// next one starts from the new reading. Pure: the caller passes both clocks in.
public struct ClockJumpGuard: Sendable {
    public enum Verdict: Sendable, Equatable {
        case proceed
        case skip(Reason)
    }

    public enum Reason: Sendable, Equatable {
        case wallClockWentBack
        case wallClockJumpedForward
    }

    /// How much more the wall clock may advance than the monotonic clock before it counts as a jump.
    public static let allowedExtra: TimeInterval = 3600

    private var lastWall: Date?
    private var lastInstant: ContinuousClock.Instant?

    public init() {}

    /// The verdict for a check at these two readings, which also become the reference for the next one. The first check has no
    /// reference and proceeds.
    public mutating func verdict(wall: Date, instant: ContinuousClock.Instant) -> Verdict {
        defer { lastWall = wall; lastInstant = instant }
        guard let lastWall, let lastInstant else { return .proceed }
        let wallElapsed = wall.timeIntervalSince(lastWall)
        if wallElapsed < 0 { return .skip(.wallClockWentBack) }
        let (seconds, attoseconds) = lastInstant.duration(to: instant).components
        let continuousElapsed = TimeInterval(seconds) + TimeInterval(attoseconds) / 1e18
        if wallElapsed > continuousElapsed + Self.allowedExtra { return .skip(.wallClockJumpedForward) }
        return .proceed
    }
}
