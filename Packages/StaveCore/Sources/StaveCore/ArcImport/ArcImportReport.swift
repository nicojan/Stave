import Foundation

/// What an import did, and what it could not carry over.
public struct ArcImportReport: Equatable, Sendable {
    public struct Counts: Equatable, Sendable {
        public var profiles = 0
        public var workspaces = 0
        public var folders = 0
        public var pinnedTabs = 0
        public var essentials = 0
        public var regularTabs = 0

        public init(
            profiles: Int = 0,
            workspaces: Int = 0,
            folders: Int = 0,
            pinnedTabs: Int = 0,
            essentials: Int = 0,
            regularTabs: Int = 0
        ) {
            self.profiles = profiles
            self.workspaces = workspaces
            self.folders = folders
            self.pinnedTabs = pinnedTabs
            self.essentials = essentials
            self.regularTabs = regularTabs
        }
    }

    public enum Flattened: Equatable, Sendable {
        /// Its contents moved up into the nearest allowed folder.
        case folderTooDeep(space: String, folder: String)
        /// `space` is nil for a Favorite.
        case splitView(space: String?, tabCount: Int)
        case favoritesFolder(folder: String)
    }

    public enum Skipped: Equatable, Sendable {
        /// `scheme` is "" when the URL is empty or unparseable.
        case nonWebURL(space: String?, title: String, scheme: String)
        case unsupportedItem(space: String?, kind: String, title: String?)
        /// Only when `includeUnpinnedTabs` is false and count > 0.
        case unpinnedTabs(space: String, count: Int)
        /// Ruling 4: imported into the default profile.
        case unrecognizedProfile(space: String)
        /// Once per import, when count > 0.
        case duplicateItem(count: Int)
    }

    public var imported: Counts
    public var flattened: [Flattened]
    public var skipped: [Skipped]

    public init(imported: Counts, flattened: [Flattened], skipped: [Skipped]) {
        self.imported = imported
        self.flattened = flattened
        self.skipped = skipped
    }
}
