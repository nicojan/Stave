import Foundation

public enum ArcImportError: Error, Equatable {
    case fileTooLarge
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
    case unsupported(kind: String, title: String?)
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

    public init(
        title: String?,
        profile: ArcProfileKey,
        emoji: String?,
        colorHex: String?,
        pinned: [ArcNode],
        unpinned: [ArcNode]
    ) {
        self.title = title
        self.profile = profile
        self.emoji = emoji
        self.colorHex = colorHex
        self.pinned = pinned
        self.unpinned = unpinned
    }
}

public struct ArcSidebar: Equatable, Sendable {
    /// Sidebar order.
    public var spaces: [ArcSpace]
    /// One entry per topApps container.
    public var favorites: [ArcProfileKey: [ArcNode]]
    /// Items reached twice (ruling 11).
    public var duplicateItems: Int

    public init(spaces: [ArcSpace], favorites: [ArcProfileKey: [ArcNode]], duplicateItems: Int) {
        self.spaces = spaces
        self.favorites = favorites
        self.duplicateItems = duplicateItems
    }
}
