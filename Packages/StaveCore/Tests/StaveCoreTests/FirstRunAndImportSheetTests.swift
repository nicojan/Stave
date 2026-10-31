import Foundation
import Testing
@testable import StaveCore

@MainActor
struct FirstRunAndImportSheetTests {
    @Test func continueNeedsAnEngine() {
        #expect(!FirstRun.canContinue(engine: nil))
        for engine in SearchEngine.allCases { #expect(FirstRun.canContinue(engine: engine)) }
    }

    @Test func arcOfferShowsOnlyWhenOffered() {
        #expect(FirstRun.sections(offersArcImport: true) == .init(searchEngine: true, workspaceShortcutsNote: true, arcOffer: true))
        #expect(!FirstRun.sections(offersArcImport: false).arcOffer)
        #expect(FirstRun.sections(offersArcImport: false).searchEngine)
    }

    @Test func importOpensAfterContinueOnlyWhenOfferedAndChosen() {
        #expect(FirstRun.opensImportAfterContinue(offersArcImport: true, importChosen: true))
        #expect(!FirstRun.opensImportAfterContinue(offersArcImport: true, importChosen: false))
        #expect(!FirstRun.opensImportAfterContinue(offersArcImport: false, importChosen: true))
    }

    @Test func completeFirstRunSavesEngineAndFlagTogether() throws {
        let (store, _, _) = try makeTempStore()
        #expect(try store.setting(SettingKeys.firstRunCompleted) == false)
        #expect(try store.setting(SettingKeys.searchEngine) == nil)
        try store.completeFirstRun(engine: .kagi)
        #expect(try store.setting(SettingKeys.firstRunCompleted))
        #expect(try store.setting(SettingKeys.searchEngine) == .kagi)
    }

    @Test func searchEngineSettingFollowsAndBumps() throws {
        let (store, _, _) = try makeTempStore()
        let revision = StoreRevision()
        let setting = SearchEngineSetting(store: store, revision: revision)
        #expect(setting.engine == nil)
        setting.set(.bing)
        #expect(setting.engine == .bing)
        #expect(revision.value == 1)
        setting.set(.bing)
        #expect(revision.value == 1)
    }

    private let home = URL(fileURLWithPath: "/private/tmp/stave-home", isDirectory: true)
    private let summary = ArcImportSummary(headline: "Imported from Arc", imported: ["1 workspace"], changed: [], skipped: ["x"])

    private func content(_ phase: ArcImportFlow.Phase, source: ArcImportFlow.Source? = nil) -> ArcImportSheetContent {
        ArcImportSheetContent(phase: phase, source: source ?? .arcOnThisMac(home: home), locale: Locale(identifier: "en_US"), timeZone: TimeZone(identifier: "UTC")!)
    }

    @Test func sourceDescriptionNamesTheSource() {
        #expect(ArcImportSheetContent.sourceDescription(for: .arcOnThisMac(home: home)) == "From Arc on this Mac")
        #expect(ArcImportSheetContent.sourceDescription(for: .pickedFile(URL(fileURLWithPath: "/private/tmp/x/Copy of sidebar.json"))) == "Copy of sidebar.json")
    }

    @Test func readyShowsSourceToggleNoticesAndButtons() {
        let ready = content(.ready, source: .pickedFile(URL(fileURLWithPath: "/private/tmp/a.json")))
        #expect(ready.sourceDescription == "a.json")
        #expect(ready.showsUnpinnedTabsToggle)
        #expect(ready.notices == [ArcImportCopy.loginsNotice, ArcImportCopy.keepACopy])
        #expect(ready.secondaryButton == .init(title: "Cancel", action: .cancel))
        #expect(ready.primaryButton == .init(title: "Import", action: .start))
        #expect(ready.canDismiss)
    }

    @Test func confirmRepeatShowsTheWarningFromThePhase() {
        let previous = Date(timeIntervalSince1970: 1_700_000_000)
        let repeated = content(.confirmRepeat(previous: previous))
        #expect(repeated.message == ArcImportCopy.repeatWarning(previous: previous, locale: Locale(identifier: "en_US"), timeZone: TimeZone(identifier: "UTC")!))
        #expect(repeated.primaryButton?.title == "Import Again")
        #expect(repeated.secondaryButton?.title == "Cancel")
        #expect(!repeated.showsUnpinnedTabsToggle)
        #expect(repeated.sourceDescription == nil)
    }

    @Test func importingCannotBeDismissed() {
        let importing = content(.importing)
        #expect(importing.showsProgress)
        #expect(!importing.canDismiss)
        #expect(importing.primaryButton == nil)
        #expect(importing.secondaryButton == nil)
    }

    @Test func finishedShowsOnlyNonEmptySections() {
        let finished = content(.finished(summary))
        #expect(finished.title == "Imported from Arc")
        #expect(finished.sections.map(\.title) == ["Imported", "Not imported"])
        #expect(finished.primaryButton == .init(title: "Done", action: .done))
        #expect(finished.secondaryButton == nil)
        let all = ArcImportSummary(headline: "h", imported: ["a"], changed: ["b"], skipped: ["c"])
        #expect(content(.finished(all)).sections.map(\.title) == ["Imported", "Changed to fit Stave", "Not imported"])
        let none = ArcImportSummary(headline: "Nothing was imported", imported: [], changed: [], skipped: [])
        #expect(content(.finished(none)).sections.isEmpty)
    }

    @Test func failedOffersAnotherFileAndClose() {
        let failed = content(.failed("nope"))
        #expect(failed.message == "nope")
        #expect(failed.secondaryButton == .init(title: "Choose Another File…", action: .chooseAnotherFile))
        #expect(failed.primaryButton == .init(title: "Close", action: .close))
    }
}
