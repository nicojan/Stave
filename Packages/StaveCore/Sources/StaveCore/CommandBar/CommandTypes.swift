import Foundation

public enum CommandBarMode: Equatable, Sendable { case newTab, currentTab }

/// An open tab as the command bar lists it: the tab, where it sits, and the workspace it belongs to (nil for an Essential).
public struct CommandTab: Equatable, Sendable {
    public var tab: Tab
    public var section: SlotSection
    public var workspaceID: UUID?
    public var workspaceName: String?

    public init(tab: Tab, section: SlotSection, workspaceID: UUID?, workspaceName: String?) {
        self.tab = tab; self.section = section; self.workspaceID = workspaceID; self.workspaceName = workspaceName
    }
}

public struct CommandCandidates: Equatable, Sendable {
    public var tabs: [CommandTab]
    public var archived: [ArchivedTab]
    public var workspaces: [Workspace]
    public var actions: [CommandAction]

    public init(tabs: [CommandTab] = [], archived: [ArchivedTab] = [], workspaces: [Workspace] = [], actions: [CommandAction] = []) {
        self.tabs = tabs; self.archived = archived; self.workspaces = workspaces; self.actions = actions
    }
}

public enum CommandAction: Equatable, Sendable {
    case newWorkspace, newProfile, newWindow, toggleCompactMode, importFromArc, showArchive
    case closeTab, pinTab, unpinTab, resetPinnedTab, copyAddress
    case switchProfile(id: UUID, name: String), newTabInContainer(id: UUID, name: String)

    public var title: String {
        switch self {
        case .newWorkspace: "New Workspace"
        case .newProfile: "New Profile"
        case .newWindow: "New Window"
        case .toggleCompactMode: "Toggle Compact Mode"
        case .importFromArc: "Import from Arc…"
        case .showArchive: "Show Archive"
        case .closeTab: "Close Tab"
        case .pinTab: "Pin Tab"
        case .unpinTab: "Unpin Tab"
        case .resetPinnedTab: "Back to Pinned Page"
        case .copyAddress: "Copy Address"
        case .switchProfile(_, let name): "Switch to \(name)"
        case .newTabInContainer(_, let name): "New Tab in \(name)"
        }
    }
}

public enum CommandResult: Equatable, Sendable {
    case open(url: String), search(query: String), tab(CommandTab), archived(ArchivedTab), workspace(Workspace), action(CommandAction)
}

public enum CommandOutcome: Equatable, Sendable {
    case done, showArcImport, showArchive, newWindow, newWorkspace, newProfile, chooseSearchEngine, copy(String)
}
