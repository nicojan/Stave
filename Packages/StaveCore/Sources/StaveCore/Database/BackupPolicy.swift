import Foundation

/// What made a backup copy. `regular` is a launch or hourly copy; `premigration` is the copy made just before a schema migration.
public enum BackupKind: Sendable, Hashable {
    case regular
    case premigration
}

/// One copy file in `Backups/`. The kind travels with the date, so two copies made in the same second stay apart.
public struct BackupCopy: Sendable, Hashable {
    public let fileName: String
    public let date: Date
    public let kind: BackupKind

    public init(fileName: String, date: Date, kind: BackupKind) {
        self.fileName = fileName
        self.date = date
        self.kind = kind
    }
}

/// Why a backup copy failed.
public enum BackupError: Error, Equatable, Sendable {
    /// The `Backups/` folder could not be made.
    case folderUnavailable
    /// The copy itself, or the clean-up of the copy, failed; the text is SQLite's or the file system's.
    case copyFailed(String)
    /// The finished copy did not pass `PRAGMA quick_check`.
    case checkFailed
    /// The checked copy could not be moved to its final name.
    case renameFailed
}

/// The names and the keep rule of the rolling backups (plan 5 decision 1). Days are UTC calendar days, as in the file names, and
/// "the last 3 days" are today and the two days before it, relative to `now`.
public enum BackupPolicy {
    public static let folderName = "Backups"
    /// One regular copy an hour while Stave runs.
    public static let interval: TimeInterval = 3600
    /// Tables whose rows a copy leaves out (history and the downloads list, added by later tasks), so Clear History is never undone
    /// by an old copy. A table that doesn't exist in the file is skipped.
    public static let excludedTables: [String] = []

    private static let prefix = "stave-"
    private static let premigrationMarker = "-premigration"
    private static let fileExtension = ".sqlite"
    private static let partialSuffixes = [".partial", ".partial-wal", ".partial-shm", ".partial-journal"]

    private static let utcCalendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar
    }()

    /// `stave-YYYYMMDD-HHMMSS.sqlite`, or `stave-YYYYMMDD-HHMMSS-premigration.sqlite`, in UTC.
    public static func fileName(at date: Date, kind: BackupKind) -> String {
        let parts = utcCalendar.dateComponents([.year, .month, .day, .hour, .minute, .second], from: date)
        let stamp = String(
            format: "%04d%02d%02d-%02d%02d%02d",
            parts.year ?? 0, parts.month ?? 0, parts.day ?? 0, parts.hour ?? 0, parts.minute ?? 0, parts.second ?? 0
        )
        let marker = kind == .premigration ? premigrationMarker : ""
        return prefix + stamp + marker + fileExtension
    }

    /// The copy a file name stands for, or nil for anything that isn't exactly one of Stave's two patterns.
    public static func copy(fromFileName name: String) -> BackupCopy? {
        guard name.hasPrefix(prefix), name.hasSuffix(fileExtension) else { return nil }
        var middle = String(name.dropFirst(prefix.count).dropLast(fileExtension.count))
        var kind = BackupKind.regular
        if middle.hasSuffix(premigrationMarker) {
            kind = .premigration
            middle = String(middle.dropLast(premigrationMarker.count))
        }
        guard let date = date(fromStamp: middle) else { return nil }
        // The round trip rejects out-of-range fields (month 13, second 99) that the calendar would otherwise roll over.
        guard fileName(at: date, kind: kind) == name else { return nil }
        return BackupCopy(fileName: name, date: date, kind: kind)
    }

    /// A copy left half-written by a crash or a failed check: Stave's pattern followed by `.partial` (or its journal files).
    public static func isStalePartial(fileName: String) -> Bool {
        partialSuffixes.contains { suffix in
            fileName.hasSuffix(suffix) && copy(fromFileName: String(fileName.dropLast(suffix.count))) != nil
        }
    }

    /// The copies to delete: everything except the `hourly` newest regular copies, the newest regular copy of each of the last
    /// `dailyDays` UTC days, and the newest pre-migration copy (however old; it never takes a regular slot). A subset of `existing`.
    public static func toDelete(existing: [BackupCopy], now: Date, hourly: Int = 10, dailyDays: Int = 3) -> [BackupCopy] {
        let keep = keptRegular(existing.filter { $0.kind == .regular }, now: now, hourly: hourly, dailyDays: dailyDays)
            .union(newest(existing.filter { $0.kind == .premigration }).map { [$0] } ?? [])
        return existing.filter { !keep.contains($0) }
    }

    private static func keptRegular(_ regular: [BackupCopy], now: Date, hourly: Int, dailyDays: Int) -> Set<BackupCopy> {
        let newestFirst = regular.sorted { $0.date > $1.date }
        let hourlyKept = Set(newestFirst.prefix(max(hourly, 0)))
        let today = utcCalendar.startOfDay(for: now)
        let days = (0..<max(dailyDays, 0)).compactMap { utcCalendar.date(byAdding: .day, value: -$0, to: today) }
        let dailyKept = days.compactMap { day in
            newestFirst.first { utcCalendar.isDate($0.date, inSameDayAs: day) }
        }
        return hourlyKept.union(dailyKept)
    }

    private static func newest(_ copies: [BackupCopy]) -> BackupCopy? {
        copies.max { $0.date < $1.date }
    }

    /// `YYYYMMDD-HHMMSS`, digits only, to a UTC date.
    private static func date(fromStamp stamp: String) -> Date? {
        let pieces = stamp.split(separator: "-", omittingEmptySubsequences: false)
        guard pieces.count == 2, pieces[0].count == 8, pieces[1].count == 6,
              pieces.allSatisfy({ $0.allSatisfy { $0.isASCII && $0.isNumber } }) else { return nil }
        let day = Array(pieces[0]), time = Array(pieces[1])
        func number(_ chars: ArraySlice<Character>) -> Int { Int(String(chars)) ?? -1 }
        let parts = DateComponents(
            year: number(day[0..<4]), month: number(day[4..<6]), day: number(day[6..<8]),
            hour: number(time[0..<2]), minute: number(time[2..<4]), second: number(time[4..<6])
        )
        return utcCalendar.date(from: parts)
    }
}
