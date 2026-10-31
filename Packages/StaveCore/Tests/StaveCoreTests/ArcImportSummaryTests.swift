import Foundation
import Testing
@testable import StaveCore

struct ArcImportSummaryTests {
    private func summary(
        counts: ArcImportReport.Counts = .init(),
        flattened: [ArcImportReport.Flattened] = [],
        skipped: [ArcImportReport.Skipped] = []
    ) -> ArcImportSummary {
        ArcImportSummary(report: ArcImportReport(imported: counts, flattened: flattened, skipped: skipped))
    }

    @Test func importedHeadline() {
        #expect(summary(counts: .init(regularTabs: 1)).headline == "Imported from Arc")
    }

    @Test func nothingImportedHeadline() {
        #expect(summary().headline == "Nothing was imported")
        #expect(summary().imported.isEmpty)
    }

    @Test func pluralsAndOrder() {
        let counts = ArcImportReport.Counts(profiles: 1, workspaces: 2, folders: 0, pinnedTabs: 6, essentials: 1, regularTabs: 0)
        #expect(summary(counts: counts).imported == ["1 new profile", "2 workspaces", "6 pinned tabs", "1 Essential"])
    }

    @Test func allCountsSingularAndPlural() {
        let one = ArcImportReport.Counts(profiles: 1, workspaces: 1, folders: 1, pinnedTabs: 1, essentials: 1, regularTabs: 1)
        #expect(summary(counts: one).imported == ["1 new profile", "1 workspace", "1 folder", "1 pinned tab", "1 Essential", "1 tab"])
        let many = ArcImportReport.Counts(profiles: 2, workspaces: 2, folders: 2, pinnedTabs: 2, essentials: 2, regularTabs: 2)
        #expect(summary(counts: many).imported == ["2 new profiles", "2 workspaces", "2 folders", "2 pinned tabs", "2 Essentials", "2 tabs"])
    }

    @Test func folderTooDeep() {
        #expect(summary(flattened: [.folderTooDeep(space: "Work", folder: "Deep")]).changed
            == ["“Deep” in Work was inside another folder. Stave folders go one level deep, so its tabs moved up a level."])
    }

    @Test func splitViewPlaces() {
        let s = summary(flattened: [
            .splitView(place: .space("Work"), tabCount: 3),
            .splitView(place: .favorites(profile: nil), tabCount: 2),
            .splitView(place: .favorites(profile: "Side"), tabCount: 2),
        ])
        #expect(s.changed == [
            "A split view with 3 tabs in Work became 3 separate tabs.",
            "A split view with 2 tabs in your Arc Favorites became 2 separate tabs.",
            "A split view with 2 tabs in the Favorites of Arc's “Side” profile became 2 separate tabs.",
        ])
    }

    @Test func favoritesFolderAndUnpinnedFolder() {
        let s = summary(flattened: [.favoritesFolder(folder: "Tools"), .unpinnedFolder(space: "Work", folder: "Misc")])
        #expect(s.changed == [
            "The folder “Tools” in your Arc Favorites became separate Essentials.",
            "The unpinned folder “Misc” in Work became separate tabs.",
        ])
    }

    @Test func nonWebURL() {
        let s = summary(skipped: [
            .nonWebURL(place: .space("Work"), title: "Notes", scheme: "arc"),
            .nonWebURL(place: .favorites(profile: nil), title: "Blank", scheme: ""),
            .nonWebURL(place: .space("Work"), title: "", scheme: "file"),
        ])
        #expect(s.skipped == [
            "“Notes” in Work isn't a web page (arc:), so it wasn't imported.",
            "“Blank” in your Arc Favorites isn't a web page (no address), so it wasn't imported.",
            "An item in Work isn't a web page (file:), so it wasn't imported.",
        ])
    }

    @Test func unsupportedItem() {
        let s = summary(skipped: [
            .unsupportedItem(place: .space("Work"), kind: "easel", title: "Sketch"),
            .unsupportedItem(place: .space("Work"), kind: "welcomeToArc", title: nil),
            .unsupportedItem(place: .favorites(profile: "Side"), kind: "widget", title: ""),
            .unsupportedItem(place: .space("Work"), kind: "note", title: "Todo"),
        ])
        #expect(s.skipped == [
            "“Sketch” in Work is an Arc Easel, which Stave doesn't have.",
            "An item in Work is an Arc welcome page, which Stave doesn't have.",
            "An item in the Favorites of Arc's “Side” profile is an Arc item of kind “widget”, which Stave doesn't have.",
            "“Todo” in Work is an Arc item of kind “note”, which Stave doesn't have.",
        ])
    }

    @Test func remainingSkippedLines() {
        let s = summary(skipped: [
            .unpinnedTabs(space: "Work", count: 4),
            .unrecognizedProfile(space: "Work"),
            .duplicateItem(count: 2),
            .unrecognizedFavoritesProfile,
            .spaceContentsMissing(space: "Work"),
        ])
        #expect(s.skipped == [
            "4 unpinned tabs in Work weren't imported. Turn on “Also import unpinned tabs” to bring them.",
            "Work belonged to an Arc profile Stave couldn't identify, so it went into your first profile.",
            "2 items appeared twice in Arc's file and were imported once.",
            "Some Arc Favorites belonged to a profile Stave couldn't identify, so they became Essentials in your first profile.",
            "Work was imported, but Arc's file didn't say what was in it.",
        ])
    }

    @Test func singularCountsInSkipped() {
        let s = summary(skipped: [.unpinnedTabs(space: "Work", count: 1), .duplicateItem(count: 1)])
        #expect(s.skipped == [
            "1 unpinned tab in Work weren't imported. Turn on “Also import unpinned tabs” to bring them.",
            "1 item appeared twice in Arc's file and were imported once.",
        ])
    }

    @Test func fixedCopy() {
        #expect(ArcImportCopy.loginsNotice == "Logins, passwords and cookies can't be imported from Arc, so you'll sign in to sites again. If your passwords are in iCloud Keychain, the Passwords app can copy them for you. Passkeys will work in Stave once Apple approves it.")
        #expect(ArcImportCopy.keepACopy == "Arc may stop opening on December 22, 2026. To import later, keep a copy of Arc's sidebar file: ~/Library/Application Support/Arc/StorableSidebar.json.")
    }

    @Test func repeatWarningDate() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        let date = calendar.date(from: DateComponents(year: 2026, month: 10, day: 29, hour: 12))!
        #expect(ArcImportCopy.repeatWarning(previous: date, locale: Locale(identifier: "en_US"), timeZone: TimeZone(identifier: "UTC")!)
            == "You imported from Arc on October 29, 2026. Importing again adds a second copy of everything it brings in. Nothing you have now is changed.")
    }

    @Test func errorMessages() {
        #expect(ArcImportCopy.errorMessage(for: ArcImportError.fileTooLarge) == "This file is over 64 MB, far larger than any Arc sidebar file, so Stave didn't open it.")
        #expect(ArcImportCopy.errorMessage(for: ArcImportError.notJSON) == "This isn't an Arc sidebar file. Stave couldn't read it as JSON.")
        #expect(ArcImportCopy.errorMessage(for: ArcImportError.noSidebar) == "This file doesn't contain an Arc sidebar.")
        #expect(ArcImportCopy.errorMessage(for: ArcImportError.tooDeep) == "This file's folders are nested deeper than Arc allows, so Stave didn't import it.")
        #expect(ArcImportCopy.errorMessage(for: ArcImportError.unreadable) == "Stave couldn't read this file.")
        struct Other: Error {}
        #expect(ArcImportCopy.errorMessage(for: Other()) == "Stave couldn't save the import. Nothing was changed.")
    }
}
