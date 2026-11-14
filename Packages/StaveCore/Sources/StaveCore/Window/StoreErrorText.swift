import Foundation

/// The one place store errors become words for the user.
public enum StoreErrorText {
    public static let fallback = "Something went wrong saving that change."

    public static func message(for error: Error) -> String {
        switch error as? StoreError {
        case .lastWorkspace: "A profile needs at least one workspace."
        case .folderTooDeep: "Folders go only one level deep."
        case .crossProfileMove: "That belongs to another profile. Move it by opening it there."
        case .notFound: "That item no longer exists."
        case .notPinned: "Only pinned tabs and Essentials have a pinned page."
        case .importChanged: "Stave imported from Arc while this was open, so it didn't import a second time. Nothing was changed."
        case .backupFailed: "Stave couldn't back up your data before updating it, so it didn't open it. Free some disk space and try again."
        default: fallback
        }
    }
}

/// The alerts the app shows when its data can't be opened or saved at launch and first run.
public extension StoreErrorText {
    /// The first-run choice could not be written.
    static let saveChoiceFailed = "Stave couldn't save your choice."

    /// The launch alert for a store that would not open: the headline, and the detail when there is one.
    static func openFailure(_ error: Error) -> (message: String, detail: String?) {
        switch error as? StoreError {
        case .newerSchema?: ("This copy of Stave is older than the one that last used your data. Install the newest Stave to open it.", nil)
        case .backupFailed?: (message(for: StoreError.backupFailed), nil)
        default: ("Stave could not open its data.", "\(error)")
        }
    }

    /// The launch alert for a `-StaveDataDirectory` or `-StaveArcHome` flag that can't be used.
    static func unusableLaunchArgument(_ flag: String) -> (message: String, detail: String) {
        (
            "Stave did not start: \(flag) needs an absolute path.",
            "The flag was given with no value, a value starting with \"-\", or a relative path. Fix it or remove it; Stave will not fall back to your real folders."
        )
    }
}
