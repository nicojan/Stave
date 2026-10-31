import Foundation

/// What a workspace button's context menu and VoiceOver actions can do. One list (`WorkspaceMenus.items`) feeds both, as for sidebar rows.
public enum WorkspaceAction: Hashable, Sendable, CaseIterable {
    case edit, moveLeft, moveRight, delete

    public var title: String {
        switch self {
        case .edit: "Edit"
        case .moveLeft: "Move Left"
        case .moveRight: "Move Right"
        case .delete: "Delete"
        }
    }

    public var symbol: String {
        switch self {
        case .edit: "pencil"
        case .moveLeft: "arrow.left"
        case .moveRight: "arrow.right"
        case .delete: "trash"
        }
    }
}

public struct WorkspaceMenuItem: Equatable, Sendable {
    public var action: WorkspaceAction
    public var isEnabled: Bool
    public init(action: WorkspaceAction, isEnabled: Bool = true) { self.action = action; self.isEnabled = isEnabled }
}

/// One entry of the Workspaces menu: switch to a workspace, with ⌃digit when it has one.
public struct WorkspaceSwitchItem: Equatable, Sendable {
    public var workspaceID: UUID
    public var title: String
    public var isCurrent: Bool
    /// 1...9 for the first nine workspaces while the shortcut setting is on, else nil.
    public var shortcutDigit: Int?
    public init(workspaceID: UUID, title: String, isCurrent: Bool, shortcutDigit: Int?) {
        self.workspaceID = workspaceID; self.title = title; self.isCurrent = isCurrent; self.shortcutDigit = shortcutDigit
    }
}

public enum WorkspaceMenus {
    /// Edit, then Move Left (not on the first), Move Right (not on the last), then Delete (disabled for a profile's only workspace).
    public static func items(index: Int, count: Int) -> [WorkspaceMenuItem] {
        var items = [WorkspaceMenuItem(action: .edit)]
        if index > 0 { items.append(WorkspaceMenuItem(action: .moveLeft)) }
        if index < count - 1 { items.append(WorkspaceMenuItem(action: .moveRight)) }
        items.append(WorkspaceMenuItem(action: .delete, isEnabled: count > 1))
        return items
    }

    /// Where `moveWorkspace(_:after:)` must put the workspace at `index` among `ids`: after the returned id (nil = first). Nil result when
    /// the move is not possible (first can't go left, last can't go right, or the action is not a move).
    public static func moveTarget(_ action: WorkspaceAction, index: Int, ids: [UUID]) -> MoveTarget? {
        guard ids.indices.contains(index) else { return nil }
        switch action {
        case .moveLeft:
            guard index > 0 else { return nil }
            return MoveTarget(afterID: index >= 2 ? ids[index - 2] : nil)
        case .moveRight:
            guard index < ids.count - 1 else { return nil }
            return MoveTarget(afterID: ids[index + 1])
        case .edit, .delete:
            return nil
        }
    }

    public struct MoveTarget: Equatable, Sendable {
        public var afterID: UUID?
        public init(afterID: UUID?) { self.afterID = afterID }
    }

    public static func deleteConfirmation(name: String) -> String { "Delete “\(name)”? Its tabs go to the archive." }

    public static let deleteButton = "Delete"
    public static let newWorkspaceButton = "New Workspace"
    public static let newWorkspaceItem = "New Workspace…"
    public static let workspacesMenu = "Workspaces"

    /// The shortcut digit of the workspace at `index` (0-based): 1...9 for the first nine, only while the setting is on.
    public static func shortcutDigit(index: Int, enabled: Bool) -> Int? {
        enabled && (0..<9).contains(index) ? index + 1 : nil
    }

    /// The Workspaces menu's switch items for a window's profile.
    public static func switchItems(workspaces: [Workspace], currentID: UUID, shortcutsEnabled: Bool) -> [WorkspaceSwitchItem] {
        workspaces.enumerated().map { index, workspace in
            WorkspaceSwitchItem(
                workspaceID: workspace.id, title: workspace.name, isCurrent: workspace.id == currentID,
                shortcutDigit: shortcutDigit(index: index, enabled: shortcutsEnabled)
            )
        }
    }

    // MARK: - Profiles

    public static let profileMenu = "Profile"
    public static let newProfileItem = "New Profile…"
    public static let newProfilePrompt = "New Profile"
    public static let createProfileButton = "Create"
    public static let profileName = "Profile name"

    /// The profile menu (decision 3) shows with two or more profiles.
    public static func showsProfileMenu(profileCount: Int) -> Bool { profileCount >= 2 }

    /// A new profile's name: trimmed; nothing typed cancels.
    public static func profileName(typed: String) -> String? {
        let trimmed = typed.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
