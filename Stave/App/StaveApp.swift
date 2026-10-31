import SwiftUI
import StaveCore

@main
struct StaveApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate

    private var state: AppMenuState { delegate.menuState }

    // Windows are AppKit-managed (see AppDelegate); SwiftUI only needs a scene, which also hosts the menu commands.
    var body: some Scene {
        Settings { SettingsView(shortcuts: delegate.menuState.shortcuts, compactMode: delegate.menuState.compactMode, searchEngine: delegate.menuState.searchEngine) }
            .commands {
                CommandGroup(replacing: .newItem) {
                    Button(CommandBarText.newTabMenuItem) { delegate.newTab() }
                        .keyboardShortcut("t", modifiers: .command)
                        .disabled(!state.isEnabled(.newTab))
                    Button("New Window") { delegate.newWindow() }
                        .keyboardShortcut("n", modifiers: .command)
                        .disabled(!state.isEnabled(.newWindow))
                }
                CommandGroup(after: .newItem) {
                    Button(CommandBarText.openLocationMenuItem) { delegate.openLocation() }
                        .keyboardShortcut("l", modifiers: .command)
                        .disabled(!state.isEnabled(.openLocation))
                    Divider()
                    Button(ArcImportSheetContent.menuItemTitle) { delegate.importFromArc() }
                        .disabled(!state.isEnabled(.importFromArc))
                }
                CommandGroup(replacing: .saveItem) {
                    Button("Close Tab") { delegate.closeSelectedTab() }
                        .keyboardShortcut("w", modifiers: .command)
                        .disabled(!state.isEnabled(.closeTab))
                    Button("Close Window") { delegate.closeWindow() }
                        .keyboardShortcut("w", modifiers: [.command, .shift])
                        .disabled(!state.isEnabled(.closeWindow))
                }
                CommandGroup(after: .sidebar) {
                    Toggle(CompactModeSetting.menuTitle, isOn: Binding(get: { delegate.menuState.isCompact }, set: { _ in delegate.toggleCompactMode() }))
                        .keyboardShortcut("s", modifiers: [.control, .command])
                    Button(ArchivePresentation.menuItem) { delegate.showArchive() }
                        .disabled(!state.isEnabled(.showArchive))
                }
                CommandMenu("Tab") {
                    // The keyboard route to the row and Essentials context menus: the same SidebarMenus lists, on the highlighted item.
                    ForEach(delegate.menuState.tabActions, id: \.self) { action in
                        Button(action.menuTitle) { delegate.performSidebarAction(action) }
                            .disabled(!state.isEnabled(.sidebarAction))
                    }
                    Divider()
                    Button(SidebarAction.moveUp.title) { delegate.moveHighlightedRow(by: -1) }
                        .keyboardShortcut(.upArrow, modifiers: [.command, .option])
                        .disabled(!delegate.menuState.canMoveUp || !state.isEnabled(.moveRow))
                    Button(SidebarAction.moveDown.title) { delegate.moveHighlightedRow(by: 1) }
                        .keyboardShortcut(.downArrow, modifiers: [.command, .option])
                        .disabled(!delegate.menuState.canMoveDown || !state.isEnabled(.moveRow))
                }
                CommandMenu(WorkspaceMenus.workspacesMenu) {
                    ForEach(delegate.menuState.workspaceItems, id: \.workspaceID) { item in
                        workspaceItem(item)
                    }
                    Divider()
                    Button(WorkspaceMenus.newWorkspaceItem) { delegate.newWorkspace() }
                        .disabled(!state.isEnabled(.newWorkspace))
                    Divider()
                    ForEach(delegate.menuState.workspaceActions, id: \.action) { item in
                        Button(item.action.menuTitle) { delegate.performWorkspaceAction(item.action) }
                            .disabled(!item.isEnabled || !state.isEnabled(.workspaceAction))
                    }
                }
            }
    }

    /// One switch item; a checkmark marks the current workspace, and ⌃digit is attached only when the item has a digit.
    @ViewBuilder
    private func workspaceItem(_ item: WorkspaceSwitchItem) -> some View {
        let toggle = Toggle(item.title, isOn: Binding(get: { item.isCurrent }, set: { _ in delegate.switchWorkspace(to: item.workspaceID) }))
            .disabled(!state.isEnabled(.switchWorkspace))
        if let digit = item.shortcutDigit, let character = String(digit).first {
            toggle.keyboardShortcut(KeyEquivalent(character), modifiers: .control)
        } else {
            toggle
        }
    }
}
