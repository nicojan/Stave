import Foundation

/// Menu commands that act on the key browser window, and whether each may run while a sheet is attached to that window.
public enum MenuCommand: CaseIterable, Sendable {
    case newTab, openLocation, newWindow, closeTab, closeWindow, switchWorkspace, moveRow, newWorkspace, importFromArc, toggleCompactMode
    case workspaceAction, sidebarAction, showArchive
}

public enum MenuCommandGate {
    /// Only the compact-mode toggle is a setting; every other command would act behind, or on top of, the sheet.
    public static func allowedWhileSheetUp(_ command: MenuCommand) -> Bool {
        command == .toggleCompactMode
    }

    /// Whether the menu item for `command` is enabled: always when the key window is free, else only the commands allowed over a sheet.
    public static func isEnabled(_ command: MenuCommand, busy: Bool) -> Bool { !busy || allowedWhileSheetUp(command) }

    /// A window is busy when a sheet is attached, a file picker is open for it, or a sheet is about to be shown.
    public static func isBusy(hasAttachedSheet: Bool, isPicking: Bool, hasPendingSheet: Bool) -> Bool {
        hasAttachedSheet || isPicking || hasPendingSheet
    }
}
