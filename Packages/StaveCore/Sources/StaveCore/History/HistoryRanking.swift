import Foundation

/// What counts as a visit and how visits are kept (decision 9).
public enum HistoryRules {
    /// A repeat visit to the same address within this many seconds of its last visit updates that row instead of adding one.
    public static let mergeWindow: TimeInterval = 30 * 60
    /// Longer addresses are not recorded: a page can make its own URL arbitrarily long, and history is hostile input's to fill.
    public static let maxURLLength = 8192
    /// A page's title is stored cut to this many characters.
    public static let maxTitleLength = 512
    /// How many recent visits, one per address, the command bar searches.
    public static let commandBarLimit = 500

    /// Only http and https pages with a host are visits; `about:`, `file:`, `data:`, `javascript:`, `blob:` and over-long addresses are not.
    public static func isRecordable(_ url: String) -> Bool {
        url.utf8.count <= maxURLLength && URLScheme.hasWebAuthority(url)
    }

    /// The title as stored: trimmed of surrounding whitespace and cut to `maxTitleLength` characters.
    public static func storedTitle(_ title: String) -> String {
        String(title.trimmingCharacters(in: .whitespacesAndNewlines).prefix(maxTitleLength))
    }

    /// The first visit of each address, in the given (newest-first) order, up to `limit`.
    public static func onePerAddress(_ visits: [HistoryVisit], limit: Int) -> [HistoryVisit] {
        var seen = Set<String>()
        let unique = visits.filter { seen.insert($0.url).inserted }
        return Array(unique.prefix(max(limit, 0)))
    }
}

/// One day of the History view: its local start, its heading and its visits, newest first.
public struct HistoryDaySection: Equatable, Sendable, Identifiable {
    public var day: Date
    public var heading: String
    public var visits: [HistoryVisit]
    public var id: Date { day }

    public init(day: Date, heading: String, visits: [HistoryVisit]) {
        self.day = day; self.heading = heading; self.visits = visits
    }
}

/// Groups visits by local day for the History view (decision 9).
public enum HistoryGrouping {
    /// Visits (already newest first) split into consecutive local days; each heading is "Today", "Yesterday" or the full date.
    public static func byDay(_ visits: [HistoryVisit], now: Date, calendar: Calendar, locale: Locale) -> [HistoryDaySection] {
        var sections: [HistoryDaySection] = []
        for visit in visits {
            let day = calendar.startOfDay(for: visit.visitedAt)
            if let last = sections.last, last.day == day {
                sections[sections.count - 1].visits.append(visit)
            } else {
                let heading = HistoryText.dayHeading(day, now: now, calendar: calendar, locale: locale)
                sections.append(HistoryDaySection(day: day, heading: heading, visits: [visit]))
            }
        }
        return sections
    }
}
