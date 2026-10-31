import Foundation

/// Everything a sidebar row can be asked to do. The context menu and the VoiceOver actions both come from `SidebarMenus`, so they cannot drift.
public enum SidebarAction: Hashable, Sendable, CaseIterable {
    case pin, unpin, addToEssentials, backToPinnedPage, closeTab, removeFromPinned, removeFromEssentials
    case renameFolder, newFolderInside, deleteFolder, newFolder
    case moveUp, moveDown, moveLeft, moveRight

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
        case .moveLeft: "Move Left"
        case .moveRight: "Move Right"
        }
    }

    /// The title in the Tab menu, where an item that asks for a name ends in an ellipsis and the target is spelled out.
    public var menuTitle: String {
        switch self {
        case .pin: "Pin Tab"
        case .unpin: "Unpin Tab"
        case .renameFolder: "Rename Folder…"
        case .newFolderInside: "New Folder Inside…"
        case .newFolder: "New Folder…"
        default: title
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
        case .moveLeft: "arrow.left"
        case .moveRight: "arrow.right"
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

    /// Move Up and Move Down (Move Left and Move Right for an Essential, which sits in a grid), each only when
    /// `SidebarDropPlanner.keyboardMove` has somewhere to go.
    public static func moveActions(for item: SidebarItemID, in snapshot: SidebarSnapshot) -> [SidebarAction] {
        let isEssential: Bool
        if case .tab(let id) = item { isEssential = snapshot.essentials.contains { $0.id == id } } else { isEssential = false }
        let (back, forward): (SidebarAction, SidebarAction) = isEssential ? (.moveLeft, .moveRight) : (.moveUp, .moveDown)
        return (SidebarDropPlanner.keyboardMove(item, by: -1, snapshot: snapshot) == nil ? [] : [back])
            + (SidebarDropPlanner.keyboardMove(item, by: 1, snapshot: snapshot) == nil ? [] : [forward])
    }

    /// The actions for an Essentials tile.
    public static func actions(forEssential tab: Tab) -> [SidebarAction] {
        (tab.isDrifted ? [.backToPinnedPage] : []) + [.removeFromEssentials]
    }

    /// What the Tab menu offers for the highlighted item, from the same lists as the context menu and the VoiceOver actions: an Essential's,
    /// a row's, or nothing when nothing (or something stale) is highlighted; then New Folder, which needs no row. Close Tab is left out
    /// (it is File ▸ Close Tab, ⌘W) and the moves are separate (`canMove`), because they carry the ⌥⌘↑ and ⌥⌘↓ shortcuts.
    public static func menuActions(highlight: SidebarItemID?, rows: [SidebarRow], snapshot: SidebarSnapshot) -> [SidebarAction] {
        let target: [SidebarAction]
        if case .tab(let id)? = highlight, let essential = snapshot.essentials.first(where: { $0.id == id }) {
            target = actions(forEssential: essential)
        } else if let highlight, let row = rows.first(where: { $0.id == highlight }) {
            target = actions(for: row)
        } else {
            target = []
        }
        return target.filter { $0 != .closeTab } + pinnedHeaderActions
    }

    /// Whether ⌥⌘↑ (`by: -1`) or ⌥⌘↓ (`by: 1`) has somewhere to move the highlighted item. Nothing highlighted: no.
    public static func canMove(highlight: SidebarItemID?, by delta: Int, snapshot: SidebarSnapshot) -> Bool {
        guard let highlight else { return false }
        return SidebarDropPlanner.keyboardMove(highlight, by: delta, snapshot: snapshot) != nil
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
