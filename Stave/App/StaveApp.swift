import SwiftUI
import StaveCore

@main
struct StaveApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate

    // Windows are AppKit-managed (see AppDelegate); SwiftUI only needs a scene, which also hosts the menu commands.
    var body: some Scene {
        Settings { SettingsView(shortcuts: delegate.menuState.shortcuts, compactMode: delegate.menuState.compactMode, searchEngine: delegate.menuState.searchEngine) }
            .commands {
                CommandGroup(replacing: .newItem) {
                    Button(CommandBarText.newTabMenuItem) { delegate.newTab() }
                        .keyboardShortcut("t", modifiers: .command)
                    Button("New Window") { delegate.newWindow() }
                        .keyboardShortcut("n", modifiers: .command)
                }
                CommandGroup(after: .newItem) {
                    Button(CommandBarText.openLocationMenuItem) { delegate.openLocation() }
                        .keyboardShortcut("l", modifiers: .command)
                    Divider()
                    Button(ArcImportSheetContent.menuItemTitle) { delegate.importFromArc() }
                }
                CommandGroup(replacing: .saveItem) {
                    Button("Close Tab") { delegate.closeSelectedTab() }
                        .keyboardShortcut("w", modifiers: .command)
                    Button("Close Window") { delegate.closeWindow() }
                        .keyboardShortcut("w", modifiers: [.command, .shift])
                }
                CommandGroup(after: .sidebar) {
                    Toggle(CompactModeSetting.menuTitle, isOn: Binding(get: { delegate.menuState.isCompact }, set: { _ in delegate.toggleCompactMode() }))
                        .keyboardShortcut("s", modifiers: [.control, .command])
                }
                CommandMenu("Tab") {
                    // The keyboard route to the row and Essentials context menus: the same SidebarMenus lists, on the highlighted item.
                    ForEach(delegate.menuState.tabActions, id: \.self) { action in
                        Button(action.menuTitle) { delegate.performSidebarAction(action) }
                    }
                    Divider()
                    Button(SidebarAction.moveUp.title) { delegate.moveHighlightedRow(by: -1) }
                        .keyboardShortcut(.upArrow, modifiers: [.command, .option])
                        .disabled(!delegate.menuState.canMoveUp)
                    Button(SidebarAction.moveDown.title) { delegate.moveHighlightedRow(by: 1) }
                        .keyboardShortcut(.downArrow, modifiers: [.command, .option])
                        .disabled(!delegate.menuState.canMoveDown)
                }
                CommandMenu(WorkspaceMenus.workspacesMenu) {
                    ForEach(delegate.menuState.workspaceItems, id: \.workspaceID) { item in
                        workspaceItem(item)
                    }
                    Divider()
                    Button(WorkspaceMenus.newWorkspaceItem) { delegate.newWorkspace() }
                    Divider()
                    ForEach(delegate.menuState.workspaceActions, id: \.action) { item in
                        Button(item.action.menuTitle) { delegate.performWorkspaceAction(item.action) }
                            .disabled(!item.isEnabled)
                    }
                }
            }
    }

    /// One switch item; a checkmark marks the current workspace, and ⌃digit is attached only when the item has a digit.
    @ViewBuilder
    private func workspaceItem(_ item: WorkspaceSwitchItem) -> some View {
        let toggle = Toggle(item.title, isOn: Binding(get: { item.isCurrent }, set: { _ in delegate.switchWorkspace(to: item.workspaceID) }))
        if let digit = item.shortcutDigit, let character = String(digit).first {
            toggle.keyboardShortcut(KeyEquivalent(character), modifiers: .control)
        } else {
            toggle
        }
    }
}
