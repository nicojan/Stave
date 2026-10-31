import Foundation

public enum SidebarArrow: Sendable { case left, right }

/// What the sidebar's keys do for the highlighted row. A folder row is highlighted but is not a tab.
public enum SidebarKeys {
    /// The tab ⌘W closes. A highlighted folder closes nothing (not the previously selected tab); with no highlight, the selected tab.
    public static func closeShortcutTarget(highlight: SidebarItemID?, selected: UUID?) -> UUID? {
        switch highlight {
        case .tab(let id)?: id
        case .folder?: nil
        case nil: selected
        }
    }

    /// The tab ⌫ closes: only a highlighted tab row. With a folder or nothing highlighted it does nothing.
    public static func deleteKeyTarget(highlight: SidebarItemID?) -> UUID? {
        if case .tab(let id)? = highlight { id } else { nil }
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

    /// True when the field shows the placeholder, which the view draws in the secondary colour.
    public static func isPlaceholder(for tab: Tab?) -> Bool { text(for: tab) == placeholder }

    public static func accessibilityLabel(for tab: Tab?) -> String {
        guard let tab, !tab.url.isEmpty else { return "Address, empty" }
        return "Address, \(DisplayText.address(for: tab.url))"
    }
}

public enum SidebarText {
    public static let newTabRow = "New Tab"
    public static let pinnedHeader = "Pinned"
    public static let archiveButton = "Archive"
    public static let searchArchive = "Search archive"
    public static let archivedTabs = "Archived tabs"
    public static let essentials = "Essentials"
    /// Shown in the empty Essentials area while a tab is dragged.
    public static let essentialsDropHint = "Drop here to add to Essentials"
    public static let folderName = "Folder name"
    public static let tabs = "Tabs"
    public static let dismissMessage = "Dismiss message"
    public static let restoreButton = "Restore"

    /// The chevron button's label. It names the folder, so the rotor's list of buttons tells one chevron from the next.
    public static func disclosureLabel(isOpen: Bool, title: String) -> String { (isOpen ? "Close folder " : "Open folder ") + title }

    /// The drifted pinned tab's "back" button label, naming its tab for the same reason.
    public static func driftedLabel(title: String) -> String { "Back to pinned page, \(title)" }

    /// The confirm button of the folder-name prompt.
    public static func promptConfirm(for action: SidebarAction) -> String { action == .renameFolder ? "Rename" : "Create" }

    /// The archive row's Restore button label.
    public static func restoreLabel(title: String) -> String { "Restore \(title)" }
}
