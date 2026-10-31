import Foundation

/// Everything a sidebar row can be asked to do. The context menu and the VoiceOver actions both come from `SidebarMenus`, so they cannot drift.
public enum SidebarAction: Hashable, Sendable, CaseIterable {
    case pin, unpin, addToEssentials, backToPinnedPage, closeTab, removeFromPinned, removeFromEssentials
    case renameFolder, newFolderInside, deleteFolder, newFolder
    case moveUp, moveDown

    /// The menu item and VoiceOver action name.
    public var title: String {
        switch self {
        case .pin: "Pin"
        case .unpin: "Unpin"
        case .addToEssentials: "Add to Essentials"
        case .backToPinnedPage: "Back to Pinned Page"
        case .closeTab: "Close Tab"
        case .removeFromPinned: "Remove from Pinned"
        case .removeFromEssentials: "Remove from Essentials"
        case .renameFolder: "Rename"
        case .newFolderInside: "New Folder Inside"
        case .deleteFolder: "Delete Folder"
        case .newFolder: "New Folder"
        case .moveUp: "Move Up"
        case .moveDown: "Move Down"
        }
    }

    /// These need a name from the user, so the view asks for it and then calls `createFolder` or `renameFolder`.
    public var needsTitle: Bool { self == .renameFolder || self == .newFolderInside || self == .newFolder }

    /// SF Symbol for the menu item.
    public var symbol: String {
        switch self {
        case .pin: "pin"
        case .unpin: "pin.slash"
        case .addToEssentials: "star"
        case .backToPinnedPage: "arrow.uturn.backward"
        case .closeTab: "xmark"
        case .removeFromPinned, .removeFromEssentials, .deleteFolder: "trash"
        case .renameFolder: "pencil"
        case .newFolderInside, .newFolder: "folder.badge.plus"
        case .moveUp: "arrow.up"
        case .moveDown: "arrow.down"
        }
    }
}

public enum SidebarMenus {
    /// The actions for a pinned-tree or regular row, in menu order.
    public static func actions(for row: SidebarRow) -> [SidebarAction] {
        switch row.kind {
        case .regularTab:
            return [.pin, .addToEssentials, .closeTab]
        case .pinnedTab(let drifted):
            return [.unpin, .addToEssentials] + (drifted ? [.backToPinnedPage] : []) + [.closeTab, .removeFromPinned]
        case .folder:
            // Folders go one level deep: a top-level folder may hold one.
            return [.renameFolder] + (row.parentFolderID == nil ? [.newFolderInside] : []) + [.deleteFolder]
        }
    }

    /// The row's actions plus Move Up and Move Down where the row has a neighbour to swap with (the same rule as ⌥⌘↑ and ⌥⌘↓).
    public static func actions(for row: SidebarRow, in snapshot: SidebarSnapshot) -> [SidebarAction] {
        actions(for: row) + moveActions(for: row.id, in: snapshot)
    }

    /// The Essentials tile's actions plus the moves that apply.
    public static func actions(forEssential tab: Tab, in snapshot: SidebarSnapshot) -> [SidebarAction] {
        actions(forEssential: tab) + moveActions(for: .tab(tab.id), in: snapshot)
    }

    /// Move Up and Move Down, each only when `SidebarDropPlanner.keyboardMove` has somewhere to go.
    public static func moveActions(for item: SidebarItemID, in snapshot: SidebarSnapshot) -> [SidebarAction] {
        (SidebarDropPlanner.keyboardMove(item, by: -1, snapshot: snapshot) == nil ? [] : [.moveUp])
            + (SidebarDropPlanner.keyboardMove(item, by: 1, snapshot: snapshot) == nil ? [] : [.moveDown])
    }

    /// The actions for an Essentials tile.
    public static func actions(forEssential tab: Tab) -> [SidebarAction] {
        (tab.isDrifted ? [.backToPinnedPage] : []) + [.removeFromEssentials]
    }

    /// The actions for the "Pinned" header.
    public static let pinnedHeaderActions: [SidebarAction] = [.newFolder]

    /// The title typed into a rename or new-folder prompt. A rename with nothing typed is cancelled (nil); a new folder falls back to "New Folder".
    public static func folderTitle(typed: String, action: SidebarAction) -> String? {
        let trimmed = typed.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty { return trimmed }
        return action == .renameFolder ? nil : "New Folder"
    }

    /// The prefilled text of the prompt: a rename starts from the current title.
    public static func promptPrefill(action: SidebarAction, currentTitle: String) -> String {
        action == .renameFolder ? currentTitle : ""
    }
}

public extension SidebarRow {
    /// Regular tabs live below the "New Tab" row; everything else is the pinned tree.
    var isRegular: Bool { if case .regularTab = kind { true } else { false } }
}
