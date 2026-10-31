import Foundation
import Observation

/// The rules and copy of the first-run sheet. The view renders what this says.
public enum FirstRun {
    public static let title = "Welcome to Stave"
    public static let enginePrompt = "Choose a search engine"
    public static let continueTitle = "Continue"
    public static let arcOfferText = "Bring your Arc spaces, pinned tabs and Favorites into Stave."
    public static let arcButtonTitle = "Import from Arc…"
    public static let arcChosenText = "Stave will open the import when you continue."

    public struct Sections: Equatable, Sendable {
        public var searchEngine: Bool
        public var workspaceShortcutsNote: Bool
        public var arcOffer: Bool
    }

    /// The engine list and the ⌃1–9 note always show; the Arc offer only when Arc's file is there and nothing was imported.
    public static func sections(offersArcImport: Bool) -> Sections {
        Sections(searchEngine: true, workspaceShortcutsNote: true, arcOffer: offersArcImport)
    }

    /// Continue waits for an engine: nothing is preselected.
    public static func canContinue(engine: SearchEngine?) -> Bool { engine != nil }

    /// The import opens after Continue only when it was offered and chosen.
    public static func opensImportAfterContinue(offersArcImport: Bool, importChosen: Bool) -> Bool {
        offersArcImport && importChosen
    }
}

/// The Search engine setting for Settings: reads the store under the revision, so it follows a choice made in the command bar or first run.
@MainActor @Observable
public final class SearchEngineSetting {
    @ObservationIgnored private let store: OrganizationStore
    @ObservationIgnored private let revision: StoreRevision
    @ObservationIgnored public var onSaveError: (@MainActor (Error) -> Void)?

    public init(store: OrganizationStore, revision: StoreRevision) {
        self.store = store
        self.revision = revision
    }

    public var engine: SearchEngine? {
        _ = revision.value
        return (try? store.setting(SettingKeys.searchEngine)) ?? nil
    }

    public func set(_ engine: SearchEngine) {
        guard engine != self.engine else { return }
        do {
            try store.setSetting(SettingKeys.searchEngine, engine)
            revision.bump()
        } catch {
            onSaveError?(error)
        }
    }

    public static let title = "Search engine"
    public static let unchosenTitle = "Choose a search engine"
}
