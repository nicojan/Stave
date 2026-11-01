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

/// The selected page's site and whether content blocking is on for it, filled by the app from the live page.
public struct PageSite: Equatable, Sendable {
    public var host: String
    public var blockingOn: Bool

    public init(host: String, blockingOn: Bool) {
        self.host = host; self.blockingOn = blockingOn
    }
}

public struct CommandCandidates: Equatable, Sendable {
    public var tabs: [CommandTab]
    public var archived: [ArchivedTab]
    public var workspaces: [Workspace]
    public var actions: [CommandAction]
    /// The selected page's site, when the window shows a live web page.
    public var pageSite: PageSite?

    public init(tabs: [CommandTab] = [], archived: [ArchivedTab] = [], workspaces: [Workspace] = [], actions: [CommandAction] = [], pageSite: PageSite? = nil) {
        self.tabs = tabs; self.archived = archived; self.workspaces = workspaces; self.actions = actions; self.pageSite = pageSite
    }
}

public enum CommandAction: Equatable, Sendable {
    case newWorkspace, newProfile, newWindow, toggleCompactMode, importFromArc, showArchive
    case closeTab, pinTab, unpinTab, resetPinnedTab, copyAddress
    case switchProfile(id: UUID, name: String), newTabInContainer(id: UUID, name: String)
    /// Turns content blocking on or off for the selected page's site.
    case setContentBlocking(on: Bool, host: String)

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
        case .setContentBlocking(let on, let host): "Turn \(on ? "On" : "Off") Content Blocking for \(host)"
        }
    }
}

public enum CommandResult: Equatable, Sendable {
    case open(url: String), search(query: String), tab(CommandTab), archived(ArchivedTab), workspace(Workspace), action(CommandAction)
}

public enum CommandOutcome: Equatable, Sendable {
    case done, showArcImport, showArchive, newWindow, newWorkspace, newProfile, chooseSearchEngine, copy(String)
    /// The app switches content blocking for the selected page's site.
    case setContentBlocking(on: Bool)
}
