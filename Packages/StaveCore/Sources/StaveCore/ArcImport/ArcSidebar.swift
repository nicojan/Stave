import Foundation

public enum ArcImportError: Error, Equatable {
    case fileTooLarge
    case unreadable
    case notJSON
    case noSidebar
    case tooDeep
}

public enum ArcProfileKey: Hashable, Sendable {
    case `default`
    case custom(directoryBasename: String)
    case unrecognized
}

public struct ArcTab: Equatable, Sendable {
    public var url: String
    /// The item's own title when set, otherwise Arc's saved title, otherwise empty.
    public var title: String

    public init(url: String, title: String) {
        self.url = url
        self.title = title
    }
}

public indirect enum ArcNode: Equatable, Sendable {
    case tab(ArcTab)
    case folder(title: String, children: [ArcNode])
    case split([ArcTab])
    /// `children` are the item's own children, imported at its position.
    case unsupported(kind: String, title: String?, children: [ArcNode] = [])
}

public struct ArcSpace: Equatable, Sendable {
    /// nil when the space is unnamed in Arc.
    public var title: String?
    public var profile: ArcProfileKey
    /// customInfo.iconType.emoji_v2
    public var emoji: String?
    /// From windowTheme.primaryColorPalette.midTone, clamped, "#RRGGBB".
    public var colorHex: String?
    public var pinned: [ArcNode]
    public var unpinned: [ArcNode]
    /// The space's pinned container id did not resolve, or a resolved container id is absent from the items.
    public var contentsMissing: Bool

    public init(
        title: String?,
        profile: ArcProfileKey,
        emoji: String?,
        colorHex: String?,
        pinned: [ArcNode],
        unpinned: [ArcNode],
        contentsMissing: Bool = false
    ) {
        self.title = title
        self.profile = profile
        self.emoji = emoji
        self.colorHex = colorHex
        self.pinned = pinned
        self.unpinned = unpinned
        self.contentsMissing = contentsMissing
    }
}

public struct ArcSidebar: Equatable, Sendable {
    /// Sidebar order.
    public var spaces: [ArcSpace]
    /// One entry per topApps container.
    public var favorites: [ArcProfileKey: [ArcNode]]
    /// Items reached twice (ruling 11).
    public var duplicateItems: Int
    /// `topApps` containers that hold at least one item and have a missing or unrecognized profile marker; their tabs are merged into `favorites[.default]`.
    public var unrecognizedFavoritesContainers: Int

    public init(
        spaces: [ArcSpace],
        favorites: [ArcProfileKey: [ArcNode]],
        duplicateItems: Int,
        unrecognizedFavoritesContainers: Int = 0
    ) {
        self.spaces = spaces
        self.favorites = favorites
        self.duplicateItems = duplicateItems
        self.unrecognizedFavoritesContainers = unrecognizedFavoritesContainers
    }
}
