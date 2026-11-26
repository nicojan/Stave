import Foundation

/// The Settings window's six panes (decision 17), in tab order.
public enum SettingsPane: String, CaseIterable, Sendable, Identifiable {
    case general, tabs, profiles, containers, websites, advanced

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .general: "General"
        case .tabs: "Tabs"
        case .profiles: "Profiles"
        case .containers: "Containers"
        case .websites: "Websites"
        case .advanced: "Advanced"
        }
    }

    public var symbol: String {
        switch self {
        case .general: "gearshape"
        case .tabs: "rectangle.stack"
        case .profiles: "person.2"
        case .containers: "shippingbox"
        case .websites: "globe"
        case .advanced: "slider.horizontal.3"
        }
    }
}

/// Every label in the Settings window that the new panes add; the older panes' labels stay with the setting that owns them and are listed
/// in `controlLabels` so the completeness test sees all of them. Each control also gets its accessibility label from here.
public enum SettingsCopy {
    // General
    public static let newTabEdgeTitle = "New tabs open at"
    public static func newTabEdgeChoice(_ edge: NewTabEdge) -> String { edge == .top ? "The top" : "The bottom" }
    // Tabs
    public static let archiveTrimTitle = "Archived tabs are removed after"
    public static let archiveTrimValue = "30 days"
    // Profiles
    public static let profileNameField = "Profile name"
    public static let renameProfile = "Rename"
    public static let deleteProfile = "Delete Profile…"
    public static let profilesFootnote = "Each profile has its own workspaces, tabs, history and website data."
    // Containers
    public static let createContainer = "Create Container"
    public static let editContainer = "Edit…"
    public static let deleteContainer = "Delete…"
    public static let containerNameField = "Container name"
    public static let containerColourPicker = "Container colour"
    public static let saveContainer = "Save"
    public static let cancelEdit = "Cancel"
    public static let newContainerTitle = "New Container"
    public static let editContainerTitle = "Edit Container"
    public static let noContainers = "No containers yet"
    // Websites
    public static let websitesProfilePicker = "Profile"
    public static let removeWebsite = "Remove"
    public static let removeAllWebsites = "Remove All…"
    public static let noWebsites = "Nothing is remembered for any website."
    // Advanced
    public static let backupsHeading = "Backups"
    public static let showBackups = "Show Backups in Finder"
    public static let backupsFolderNote = "Stave keeps a copy of your tabs and workspaces every hour. History isn't included."
    public static let backupsWorking = "Backups are working"
    public static let backupsNoneYet = "The first backup hasn't finished yet"
    public static let backupsFailedTitle = "Stave couldn't back up your data"

    /// How many failures in a row make Settings show `backupsFailedTitle` (decision 2).
    public static let backupFailureThreshold = 3

    // Alerts
    public static let okButton = "OK"
    /// Shown when the Backups folder can't be made or opened (Show Backups in Finder).
    public static func backupsFolderFailed(_ reason: String) -> String { "Stave couldn't open the Backups folder: \(reason)" }
    public static let backupsFolderNotOpened = "Stave couldn't open the Backups folder."

    // Accessibility labels that name their row. VoiceOver reads "Rename" for every profile otherwise.
    public static func renameProfileLabel(profileName: String) -> String { "\(renameProfile) the profile “\(profileName)”" }
    public static func deleteProfileLabel(profileName: String) -> String { "Delete the profile “\(profileName)”" }
    public static func createContainerLabel(profileName: String) -> String { "Create a container in the profile “\(profileName)”" }
    public static func editContainerLabel(name: String) -> String { "Edit the container “\(name)”" }
    public static func deleteContainerLabel(name: String) -> String { "Delete the container “\(name)”" }
    public static func removeWebsiteLabel(_ entry: SiteEntry) -> String { "\(removeWebsite) \(WebsiteEntryText.summary(entry))" }

    /// Every label a pane shows or reads out, for the completeness test: unique within the pane, never empty. The older settings' labels stay
    /// with the type that owns them and are listed here so the test sees them.
    @MainActor public static func labels(in pane: SettingsPane) -> [String] {
        switch pane {
        case .general:
            [
                ExternalOpenText.defaultBrowserButton(isDefault: false).title, ExternalOpenText.defaultBrowserButton(isDefault: true).title,
                ExternalOpenText.linkTargetTitle, SearchEngineSetting.title, newTabEdgeTitle,
                newTabEdgeChoice(.top), newTabEdgeChoice(.bottom), HistoryRetention.settingTitle,
            ]
        case .tabs:
            [WorkspaceShortcutsSetting.title, CompactModeSetting.title, archiveTrimTitle, archiveTrimValue]
        case .profiles:
            [profileNameField, renameProfile, deleteProfile, profilesFootnote]
        case .containers:
            [
                createContainer, editContainer, deleteContainer, newContainerTitle, editContainerTitle, containerNameField,
                containerColourPicker, saveContainer, cancelEdit, noContainers,
            ]
        case .websites:
            [websitesProfilePicker, removeWebsite, removeAllWebsites, noWebsites]
        case .advanced:
            [backupsHeading, showBackups, backupsFolderNote, backupsWorking, backupsNoneYet, backupsFailedTitle]
        }
    }

    /// The buttons of the alerts Settings shows (the question before a deletion, the refusals): unique among themselves.
    public static var alertLabels: [String] {
        [DeletionCopy.deleteButton, DeletionCopy.cancelButton, removeWebsite, okButton]
    }

    /// The sentence Advanced shows about the latest backups: working, not yet made, or (after three failures in a row) the failure and why.
    public static func backupStatus(consecutiveFailures: Int, failure: BackupError?, hasSucceeded: Bool) -> (text: String, isFailure: Bool) {
        if consecutiveFailures >= backupFailureThreshold {
            return ("\(backupsFailedTitle): \(reason(failure)).", true)
        }
        return (hasSucceeded ? backupsWorking : backupsNoneYet, false)
    }

    private static func reason(_ failure: BackupError?) -> String {
        switch failure {
        case .folderUnavailable?: "the Backups folder can't be made"
        case .copyFailed(let detail)?: "the copy failed (\(detail))"
        case .checkFailed?: "the copy didn't pass its check"
        case .renameFailed?: "the finished copy couldn't be saved"
        case nil: "the reason is unknown"
        }
    }
}
