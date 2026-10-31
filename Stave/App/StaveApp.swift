import SwiftUI
import StaveCore

@main
struct StaveApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate

    // Windows are AppKit-managed (see AppDelegate); SwiftUI only needs a scene, which also hosts the menu commands.
    var body: some Scene {
        Settings { SettingsView(shortcuts: delegate.menuState.shortcuts) }
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
                }
                CommandGroup(replacing: .saveItem) {
                    Button("Close Tab") { delegate.closeSelectedTab() }
                        .keyboardShortcut("w", modifiers: .command)
                    Button("Close Window") { delegate.closeWindow() }
                        .keyboardShortcut("w", modifiers: [.command, .shift])
                }
                CommandMenu("Tab") {
                    Button(SidebarAction.moveUp.title) { delegate.moveHighlightedRow(by: -1) }
                        .keyboardShortcut(.upArrow, modifiers: [.command, .option])
                    Button(SidebarAction.moveDown.title) { delegate.moveHighlightedRow(by: 1) }
                        .keyboardShortcut(.downArrow, modifiers: [.command, .option])
                }
                CommandMenu(WorkspaceMenus.workspacesMenu) {
                    ForEach(delegate.menuState.workspaceItems, id: \.workspaceID) { item in
                        workspaceItem(item)
                    }
                    Divider()
                    Button(WorkspaceMenus.newWorkspaceItem) { delegate.newWorkspace() }
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
