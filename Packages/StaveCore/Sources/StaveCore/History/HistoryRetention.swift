import Foundation
import Observation

/// How long history is kept: Safari's "Remove history items" choices (decision 9, question 15). One year by default; `.manually` never trims.
public enum HistoryRetention: String, Codable, Sendable, CaseIterable {
    case day, week, twoWeeks, month, year, manually

    /// The setting's label.
    public static let settingTitle = "Remove history items"
    /// How often `trimHistory` runs while Stave is open, besides launch maintenance.
    public static let trimInterval: TimeInterval = 86_400

    public var title: String {
        switch self {
        case .day: "After one day"
        case .week: "After one week"
        case .twoWeeks: "After two weeks"
        case .month: "After one month"
        case .year: "After one year"
        case .manually: "Manually"
        }
    }

    /// Visits before this date are trimmed; nil for `.manually`, which keeps everything. Calendar arithmetic, so a month or a year follows
    /// the calendar rather than a fixed number of days.
    public func cutoff(now: Date, calendar: Calendar) -> Date? {
        let step: (Calendar.Component, Int)
        switch self {
        case .day: step = (.day, 1)
        case .week: step = (.day, 7)
        case .twoWeeks: step = (.day, 14)
        case .month: step = (.month, 1)
        case .year: step = (.year, 1)
        case .manually: return nil
        }
        return calendar.date(byAdding: step.0, value: -step.1, to: now)
    }
}

/// History ▸ Clear History…'s ranges, as Safari offers them (decision 9).
public enum HistoryClearRange: String, Sendable, CaseIterable {
    case lastHour, today, todayAndYesterday, all

    /// The popup's item, read after "Clear".
    public var title: String {
        switch self {
        case .lastHour: "the last hour"
        case .today: "today"
        case .todayAndYesterday: "today and yesterday"
        case .all: "all history"
        }
    }

    /// The earliest visit time the range removes; nil removes all history. "Today" starts at local midnight.
    public func since(now: Date, calendar: Calendar) -> Date? {
        switch self {
        case .lastHour: return now.addingTimeInterval(-3600)
        case .today: return calendar.startOfDay(for: now)
        case .todayAndYesterday: return calendar.date(byAdding: .day, value: -1, to: calendar.startOfDay(for: now))
        case .all: return nil
        }
    }
}

/// "Remove history items" as live state for Settings; writing it bumps `revision`. The next trim (launch or the daily one) applies it.
@MainActor @Observable
public final class HistoryRetentionSetting {
    @ObservationIgnored private let store: OrganizationStore
    @ObservationIgnored private let revision: StoreRevision
    @ObservationIgnored public var onSaveError: (@MainActor (Error) -> Void)?

    public init(store: OrganizationStore, revision: StoreRevision) {
        self.store = store
        self.revision = revision
    }

    public var retention: HistoryRetention {
        _ = revision.value
        return (try? store.setting(SettingKeys.historyRetention)) ?? SettingKeys.historyRetention.defaultValue
    }

    public func set(_ retention: HistoryRetention) {
        guard retention != self.retention else { return }
        do {
            try store.setSetting(SettingKeys.historyRetention, retention)
            revision.bump()
        } catch {
            onSaveError?(error)
        }
    }
}
