import Foundation

public enum SidebarArrow: Sendable { case left, right }

/// What the sidebar's keys do for the highlighted row. A folder row is highlighted but is not a tab.
public enum SidebarKeys {
    /// The tab ⌫ or ⌘W closes. A highlighted folder closes nothing (not the previously selected tab); with no highlight, the selected tab.
    public static func tabToClose(highlight: SidebarItemID?, selected: UUID?) -> UUID? {
        switch highlight {
        case .tab(let id)?: id
        case .folder?: nil
        case nil: selected
        }
    }

    /// ← closes and → opens a highlighted folder; nil when the key does nothing (not a folder, or already in that state).
    public static func folderChange(highlight: SidebarItemID?, key: SidebarArrow, rows: [SidebarRow]) -> (folderID: UUID, isOpen: Bool)? {
        guard case .folder(let id)? = highlight,
              let row = rows.first(where: { $0.id == .folder(id) }),
              case .folder(let isOpen, _) = row.kind else { return nil }
        let wanted = key == .right
        return wanted == isOpen ? nil : (id, wanted)
    }
}

/// The address field's text and labels.
public enum AddressFieldText {
    public static let placeholder = "Search or enter address"
    public static let hint = "Opens the command bar"

    /// The host of the selected tab, or the placeholder with no tab or no address.
    public static func text(for tab: Tab?) -> String {
        guard let tab, !tab.url.isEmpty else { return placeholder }
        return DisplayText.address(for: tab.url)
    }

    public static func accessibilityLabel(for tab: Tab?) -> String {
        guard let tab, !tab.url.isEmpty else { return "Address, empty" }
        return "Address, \(DisplayText.address(for: tab.url))"
    }
}

public enum SidebarText {
    public static let newTabRow = "New Tab"
    public static let pinnedHeader = "Pinned"
    public static let driftedButton = "Back to pinned page"
    public static let archiveButton = "Archive"
}
