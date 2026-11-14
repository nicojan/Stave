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
        case .backupFailed: "Stave couldn't back up your data before updating it, so it didn't open it. Free some disk space and try again."
        default: fallback
        }
    }
}
