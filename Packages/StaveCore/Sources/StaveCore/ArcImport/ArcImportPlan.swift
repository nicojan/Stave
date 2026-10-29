import Foundation

public struct ArcImportOptions: Equatable, Sendable {
    public var includeUnpinnedTabs: Bool

    public init(includeUnpinnedTabs: Bool = false) {
        self.includeUnpinnedTabs = includeUnpinnedTabs
    }
}

public struct PlannedTab: Equatable, Sendable {
    public var url: String
    public var title: String

    public init(url: String, title: String) {
        self.url = url
        self.title = title
    }
}

public indirect enum PlannedPinned: Equatable, Sendable {
    case tab(PlannedTab)
    case folder(title: String, children: [PlannedPinned])
}

public struct PlannedWorkspace: Equatable, Sendable {
    public var name: String
    public var icon: String
    public var colorHex: String
    public var pinned: [PlannedPinned]
    public var regular: [PlannedTab]

    public init(name: String, icon: String, colorHex: String, pinned: [PlannedPinned], regular: [PlannedTab]) {
        self.name = name
        self.icon = icon
        self.colorHex = colorHex
        self.pinned = pinned
        self.regular = regular
    }
}

public enum PlannedProfileTarget: Equatable, Sendable {
    case existingDefault
    case new(name: String)
}

public struct PlannedProfile: Equatable, Sendable {
    public var target: PlannedProfileTarget
    public var workspaces: [PlannedWorkspace]
    public var essentials: [PlannedTab]

    public init(target: PlannedProfileTarget, workspaces: [PlannedWorkspace], essentials: [PlannedTab]) {
        self.target = target
        self.workspaces = workspaces
        self.essentials = essentials
    }
}

public struct ArcImportPlan: Equatable, Sendable {
    public var profiles: [PlannedProfile]
    public var flattened: [ArcImportReport.Flattened]
    public var skipped: [ArcImportReport.Skipped]

    public init(
        profiles: [PlannedProfile],
        flattened: [ArcImportReport.Flattened],
        skipped: [ArcImportReport.Skipped]
    ) {
        self.profiles = profiles
        self.flattened = flattened
        self.skipped = skipped
    }
}
