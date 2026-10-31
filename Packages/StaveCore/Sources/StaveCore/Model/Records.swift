import Foundation
import GRDB

public enum SlotSection: String, Codable, Sendable { case essential, pinned, regular }
public enum SlotKind: String, Codable, Sendable { case tab, split }

public struct Profile: Codable, FetchableRecord, PersistableRecord, Sendable, Identifiable, Equatable {
    public var id: UUID
    public var name: String
    public var dataStoreID: UUID
    public var sortIndex: Double
    public var modifiedAt: Date

    public init(id: UUID = UUID(), name: String, dataStoreID: UUID = UUID(), sortIndex: Double, modifiedAt: Date = Date()) {
        self.id = id; self.name = name; self.dataStoreID = dataStoreID
        self.sortIndex = sortIndex; self.modifiedAt = modifiedAt
    }
}

public struct Workspace: Codable, FetchableRecord, PersistableRecord, Sendable, Identifiable, Equatable {
    public var id: UUID
    public var profileID: UUID
    public var name: String
    public var icon: String
    public var colorHex: String
    public var sortIndex: Double
    public var modifiedAt: Date

    public init(id: UUID = UUID(), profileID: UUID, name: String, icon: String, colorHex: String, sortIndex: Double, modifiedAt: Date = Date()) {
        self.id = id; self.profileID = profileID; self.name = name; self.icon = icon
        self.colorHex = colorHex; self.sortIndex = sortIndex; self.modifiedAt = modifiedAt
    }
}

public struct Folder: Codable, FetchableRecord, PersistableRecord, Sendable, Identifiable, Equatable {
    public var id: UUID
    public var workspaceID: UUID
    public var parentFolderID: UUID?
    public var title: String
    public var sortIndex: Double
    public var isOpen: Bool
    public var modifiedAt: Date

    public init(id: UUID = UUID(), workspaceID: UUID, parentFolderID: UUID? = nil, title: String, sortIndex: Double, isOpen: Bool = true, modifiedAt: Date = Date()) {
        self.id = id; self.workspaceID = workspaceID; self.parentFolderID = parentFolderID
        self.title = title; self.sortIndex = sortIndex; self.isOpen = isOpen; self.modifiedAt = modifiedAt
    }
}

public struct Slot: Codable, FetchableRecord, PersistableRecord, Sendable, Identifiable, Equatable {
    public var id: UUID
    public var profileID: UUID
    /// nil for essentials.
    public var workspaceID: UUID?
    public var section: SlotSection
    public var kind: SlotKind
    public var folderID: UUID?
    public var sortIndex: Double
    public var modifiedAt: Date

    public init(id: UUID = UUID(), profileID: UUID, workspaceID: UUID?, section: SlotSection, kind: SlotKind = .tab, folderID: UUID? = nil, sortIndex: Double, modifiedAt: Date = Date()) {
        self.id = id; self.profileID = profileID; self.workspaceID = workspaceID; self.section = section
        self.kind = kind; self.folderID = folderID; self.sortIndex = sortIndex; self.modifiedAt = modifiedAt
    }
}

public struct Tab: Codable, FetchableRecord, PersistableRecord, Sendable, Identifiable, Equatable {
    public var id: UUID
    public var slotID: UUID
    public var containerID: UUID?
    public var pinnedURL: String?
    public var pinnedTitle: String?
    /// The pinned page's icon, kept so a reset brings it back.
    public var pinnedFaviconURL: String?
    public var url: String
    public var title: String
    public var faviconURL: String?
    public var interactionState: Data?
    public var lastActiveAt: Date
    public var modifiedAt: Date

    public init(id: UUID = UUID(), slotID: UUID, containerID: UUID? = nil, pinnedURL: String? = nil, pinnedTitle: String? = nil, pinnedFaviconURL: String? = nil, url: String, title: String, faviconURL: String? = nil, interactionState: Data? = nil, lastActiveAt: Date = Date(), modifiedAt: Date = Date()) {
        self.id = id; self.slotID = slotID; self.containerID = containerID; self.pinnedURL = pinnedURL
        self.pinnedTitle = pinnedTitle; self.pinnedFaviconURL = pinnedFaviconURL; self.url = url; self.title = title; self.faviconURL = faviconURL
        self.interactionState = interactionState; self.lastActiveAt = lastActiveAt; self.modifiedAt = modifiedAt
    }

    /// True when the tab is pinned and its current page differs from the pinned one. The one home of the drift rule.
    public var isDrifted: Bool { pinnedURL != nil && url != pinnedURL }
}

/// Named containers only; throwaway containers are never stored.
public struct Container: Codable, FetchableRecord, PersistableRecord, Sendable, Identifiable, Equatable {
    public var id: UUID
    public var profileID: UUID
    public var name: String
    public var colorHex: String
    public var dataStoreID: UUID
    public var modifiedAt: Date

    public init(id: UUID = UUID(), profileID: UUID, name: String, colorHex: String, dataStoreID: UUID = UUID(), modifiedAt: Date = Date()) {
        self.id = id; self.profileID = profileID; self.name = name; self.colorHex = colorHex
        self.dataStoreID = dataStoreID; self.modifiedAt = modifiedAt
    }
}

public struct ArchivedTab: Codable, FetchableRecord, PersistableRecord, Sendable, Identifiable, Equatable {
    public var id: UUID
    public var profileID: UUID
    public var workspaceID: UUID?
    /// The pinned page of a pinned tab or Essential; nil for a regular tab. Kept so the page the user pinned is never lost.
    public var pinnedURL: String?
    public var pinnedTitle: String?
    public var pinnedFaviconURL: String?
    public var url: String
    public var title: String
    public var faviconURL: String?
    public var interactionState: Data?
    public var containerID: UUID?
    public var closedAt: Date
    public var modifiedAt: Date

    public init(id: UUID = UUID(), profileID: UUID, workspaceID: UUID? = nil, pinnedURL: String? = nil, pinnedTitle: String? = nil, pinnedFaviconURL: String? = nil, url: String, title: String, faviconURL: String? = nil, interactionState: Data? = nil, containerID: UUID? = nil, closedAt: Date = Date(), modifiedAt: Date = Date()) {
        self.id = id; self.profileID = profileID; self.workspaceID = workspaceID
        self.pinnedURL = pinnedURL; self.pinnedTitle = pinnedTitle; self.pinnedFaviconURL = pinnedFaviconURL; self.url = url
        self.title = title; self.faviconURL = faviconURL; self.interactionState = interactionState
        self.containerID = containerID; self.closedAt = closedAt; self.modifiedAt = modifiedAt
    }
}

public struct WindowState: Codable, FetchableRecord, PersistableRecord, Sendable, Identifiable, Equatable {
    public var id: UUID
    public var profileID: UUID
    public var workspaceID: UUID
    public var selectedTabID: UUID?
    public var frame: String
    public var sortIndex: Double
    public var modifiedAt: Date

    public init(id: UUID = UUID(), profileID: UUID, workspaceID: UUID, selectedTabID: UUID? = nil, frame: String, sortIndex: Double, modifiedAt: Date = Date()) {
        self.id = id; self.profileID = profileID; self.workspaceID = workspaceID
        self.selectedTabID = selectedTabID; self.frame = frame; self.sortIndex = sortIndex; self.modifiedAt = modifiedAt
    }
}
