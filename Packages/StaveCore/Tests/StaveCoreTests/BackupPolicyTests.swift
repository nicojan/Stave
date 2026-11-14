import Foundation
import Testing
@testable import StaveCore

@Suite struct BackupPolicyTests {
    /// A UTC date from its parts, so the tests never depend on the Mac's time zone.
    private func utc(_ year: Int, _ month: Int, _ day: Int, _ hour: Int, _ minute: Int = 0, _ second: Int = 0) -> Date {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar.date(from: DateComponents(year: year, month: month, day: day, hour: hour, minute: minute, second: second))!
    }

    private func regular(_ date: Date) -> BackupCopy {
        BackupCopy(fileName: BackupPolicy.fileName(at: date, kind: .regular), date: date, kind: .regular)
    }

    private func premigration(_ date: Date) -> BackupCopy {
        BackupCopy(fileName: BackupPolicy.fileName(at: date, kind: .premigration), date: date, kind: .premigration)
    }

    @Test func fileNamesRoundTrip() {
        let date = utc(2026, 11, 10, 7, 5, 9)
        #expect(BackupPolicy.fileName(at: date, kind: .regular) == "stave-20261110-070509.sqlite")
        #expect(BackupPolicy.fileName(at: date, kind: .premigration) == "stave-20261110-070509-premigration.sqlite")
        for kind in [BackupKind.regular, .premigration] {
            let name = BackupPolicy.fileName(at: date.addingTimeInterval(0.6), kind: kind)
            let copy = BackupPolicy.copy(fromFileName: name)
            #expect(copy?.date == date)
            #expect(copy?.kind == kind)
            #expect(copy?.fileName == name)
        }
        for stranger in ["notes.txt", "stave-old.sqlite", "stave-20261110-999999.sqlite", "stave-20261110-120000-other.sqlite", "stave-20261332-120000.sqlite", "stave-20261110-120000.sqlite.partial", ""] {
            #expect(BackupPolicy.copy(fromFileName: stranger) == nil, "\(stranger)")
        }
    }

    @Test func keepsTenHourlyAndThreeDaily() {
        let now = utc(2026, 11, 10, 23, 30)
        let start = utc(2026, 11, 9, 8)
        let hourly = (0..<40).map { regular(start.addingTimeInterval(Double($0) * 3600)) }
        let earlier = (4...8).map { regular(utc(2026, 11, $0, 12)) }
        let existing = hourly + earlier
        let deleted = BackupPolicy.toDelete(existing: existing, now: now)
        let kept = Set(existing).subtracting(deleted)
        let expectedKept = Set((14...23).map { regular(utc(2026, 11, 10, $0)) } + [regular(utc(2026, 11, 9, 23)), regular(utc(2026, 11, 8, 12))])
        #expect(kept == expectedKept)
        #expect(deleted.count == 33)
        #expect(Set(deleted).isSubset(of: Set(existing)))
    }

    @Test func newestPremigrationCopyKept() {
        let day = utc(2026, 11, 10, 8)
        // Very old pre-migration copies: only the newest stays.
        let oldest = premigration(utc(2025, 1, 1, 9))
        let older = premigration(utc(2025, 6, 1, 9))
        #expect(BackupPolicy.toDelete(existing: [older], now: day).isEmpty)
        #expect(BackupPolicy.toDelete(existing: [oldest, older], now: day) == [oldest])

        // A regular and a pre-migration copy share one second; 12 newer regular copies push the regular one out.
        let sharedRegular = regular(day)
        let sharedPremigration = premigration(day)
        let newer = (1...12).map { regular(day.addingTimeInterval(Double($0) * 3600)) }
        let now = day.addingTimeInterval(12 * 3600 + 1800)
        let names = BackupPolicy.toDelete(existing: [sharedRegular, sharedPremigration] + newer, now: now).map(\.fileName)
        #expect(names.contains(sharedRegular.fileName))
        #expect(!names.contains(sharedPremigration.fileName))
        #expect(sharedRegular.fileName != sharedPremigration.fileName)
    }

    @Test func premigrationNeverTakesARegularSlot() {
        let now = utc(2026, 11, 10, 12)
        let regulars = (0..<10).map { regular(now.addingTimeInterval(-Double($0 + 1) * 3600)) }
        let newestPremigration = premigration(now.addingTimeInterval(-60))
        #expect(BackupPolicy.toDelete(existing: regulars + [newestPremigration], now: now).isEmpty)
    }

    @Test func stalePartialsRecognised() {
        #expect(BackupPolicy.isStalePartial(fileName: "stave-20261110-120000.sqlite.partial"))
        #expect(BackupPolicy.isStalePartial(fileName: "stave-20261110-120000.sqlite.partial-wal"))
        #expect(BackupPolicy.isStalePartial(fileName: "stave-20261110-120000.sqlite.partial-shm"))
        #expect(BackupPolicy.isStalePartial(fileName: "stave-20261110-120000-premigration.sqlite.partial-journal"))
        #expect(!BackupPolicy.isStalePartial(fileName: "notes.partial"))
        #expect(!BackupPolicy.isStalePartial(fileName: "stave-20261110-120000.sqlite"))
        #expect(!BackupPolicy.isStalePartial(fileName: "stave-old.sqlite.partial"))
    }

    @Test func constants() {
        #expect(BackupPolicy.folderName == "Backups")
        #expect(BackupPolicy.interval == 3600)
        #expect(BackupPolicy.excludedTables.isEmpty)
    }
}
