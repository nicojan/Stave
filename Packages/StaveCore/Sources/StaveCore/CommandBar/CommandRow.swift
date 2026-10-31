import Foundation

/// Which icon a command-bar row shows. The view maps it to a picture; the choice is made here.
public enum CommandRowIcon: Equatable, Sendable {
    case open, search, tab, archived, action
    case workspace(WorkspaceIcon)

    /// The SF Symbol name for the kinds that use one; nil for a workspace that shows an emoji.
    public var symbolName: String? {
        switch self {
        case .open: "arrow.up.right.square"
        case .search: "magnifyingglass"
        case .tab: "rectangle.on.rectangle"
        case .archived: "archivebox"
        case .action: "command"
        case .workspace(.symbol(let name)): name
        case .workspace(.emoji): nil
        }
    }
}

/// What one command-bar result row shows and says: icon, title, secondary line and VoiceOver label.
public struct CommandRow: Equatable, Sendable {
    public var icon: CommandRowIcon
    public var title: String
    public var secondary: String?
    public var accessibilityLabel: String

    public init(icon: CommandRowIcon, title: String, secondary: String?, accessibilityLabel: String) {
        self.icon = icon; self.title = title; self.secondary = secondary; self.accessibilityLabel = accessibilityLabel
    }
}

/// The text of the command bar and its menu items.
public enum CommandBarText {
    public static let newTabMenuItem = "New Tab"
    public static let openLocationMenuItem = "Open Location…"
    public static let fieldLabel = "Command bar"
    public static let placeholder = "Search or enter address"
    public static let resultsLabel = "Results"
    public static let noResults = "No results"
    public static let chooseEngineSecondary = "Choose a search engine"
    public static let enginePickerTitle = "Choose a search engine"
    public static let enginePickerHint = "Your search will run once you choose. You can change this later in Settings."
    public static let enginePickerLabel = "Search engines"
    public static let archivedSecondary = "Archived"
    /// The address prefix the Open row leaves out, so it reads "Open example.net".
    fileprivate static let secureScheme = "https://"

    public static func engineRowLabel(_ engine: SearchEngine) -> String { "\(engine.displayName), search engine" }
}

public enum CommandRows {
    /// The row for a result. `currentWorkspaceID` decides which tabs show their workspace; `engine` is the chosen search engine, nil when none is chosen yet.
    public static func row(for result: CommandResult, currentWorkspaceID: UUID?, engine: SearchEngine?) -> CommandRow {
        switch result {
        case .open(let url):
            let title = "Open " + (url.hasPrefix(CommandBarText.secureScheme) ? String(url.dropFirst(CommandBarText.secureScheme.count)) : url)
            return row(.open, title, secondary: url, kind: "address")
        case .search(let query):
            return row(.search, "Search for \(query)", secondary: engine?.displayName ?? CommandBarText.chooseEngineSecondary, kind: "search")
        case .tab(let found):
            let title = DisplayText.title(for: found.tab)
            let elsewhere = found.workspaceName.flatMap { found.workspaceID != currentWorkspaceID ? $0 : nil }
            let host = found.tab.url.isEmpty ? nil : DisplayText.address(for: found.tab.url)
            return row(.tab, title, secondary: elsewhere ?? host, kind: "tab", workspace: elsewhere)
        case .archived(let archived):
            let title = DisplayText.title(title: archived.title, url: archived.url)
            return row(.archived, title, secondary: CommandBarText.archivedSecondary, kind: "archived tab")
        case .workspace(let workspace):
            return row(.workspace(WorkspaceIcon(stored: workspace.icon)), workspace.name, secondary: nil, kind: "workspace")
        case .action(let action):
            return row(.action, action.title, secondary: nil, kind: "action")
        }
    }

    private static func row(_ icon: CommandRowIcon, _ title: String, secondary: String?, kind: String, workspace: String? = nil) -> CommandRow {
        let label = "\(title), \(kind)" + (workspace.map { ", in \($0)" } ?? "")
        return CommandRow(icon: icon, title: title, secondary: secondary, accessibilityLabel: label)
    }
}
