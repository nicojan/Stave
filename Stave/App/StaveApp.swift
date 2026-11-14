import SwiftUI
import StaveCore

@main
struct StaveApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate

    private var state: AppMenuState { delegate.menuState }

    // Windows are AppKit-managed (see AppDelegate); SwiftUI only needs a scene, which also hosts the menu commands.
    var body: some Scene {
        Settings {
            SettingsView(
                shortcuts: delegate.menuState.shortcuts, compactMode: delegate.menuState.compactMode, searchEngine: delegate.menuState.searchEngine,
                externalLinks: delegate.menuState.externalLinks, isDefaultBrowser: delegate.menuState.isDefaultBrowser,
                makeDefaultBrowser: { delegate.makeDefaultBrowser() }, refreshDefaultBrowser: { delegate.refreshDefaultBrowser() }
            )
        }
            .commands {
                CommandGroup(replacing: .appTermination) {
                    Button(PageChromeText.quitMenuItem) { delegate.quit() }
                        .keyboardShortcut("q", modifiers: .command)
                }
                CommandGroup(replacing: .newItem) {
                    Button(CommandBarText.newTabMenuItem) { delegate.newTab() }
                        .keyboardShortcut("t", modifiers: .command)
                        .disabled(!state.isEnabled(.newTab))
                    Button(PageChromeText.newWindowMenuItem) { delegate.newWindow() }
                        .keyboardShortcut("n", modifiers: .command)
                        .disabled(!state.isEnabled(.newWindow))
                    Button(PrivateWindowText.menuItem) { delegate.newPrivateWindow() }
                        .keyboardShortcut("n", modifiers: [.command, .shift])
                        .disabled(!state.isEnabled(.newWindow))
                }
                CommandGroup(after: .newItem) {
                    Button(ExternalOpenText.openFileMenuItem) { delegate.openFile() }
                        .keyboardShortcut("o", modifiers: .command)
                        .disabled(!state.isEnabled(.newWindow))
                    Button(CommandBarText.openLocationMenuItem) { delegate.openLocation() }
                        .keyboardShortcut("l", modifiers: .command)
                        .disabled(!state.isEnabled(.openLocation))
                    Divider()
                    Button(ArcImportSheetContent.menuItemTitle) { delegate.importFromArc() }
                        .disabled(!state.isEnabled(.importFromArc))
                }
                CommandGroup(replacing: .saveItem) {
                    Button(PageChromeText.closeTabMenuItem) { delegate.closeSelectedTab() }
                        .keyboardShortcut("w", modifiers: .command)
                        .disabled(!state.isEnabled(.closeTab))
                    Button(PageChromeText.closeWindowMenuItem) { delegate.closeWindow() }
                        .keyboardShortcut("w", modifiers: [.command, .shift])
                        .disabled(!state.isEnabled(.closeWindow))
                }
                CommandGroup(after: .sidebar) {
                    Toggle(CompactModeSetting.menuTitle, isOn: Binding(get: { delegate.menuState.isCompact }, set: { _ in delegate.toggleCompactMode() }))
                        .keyboardShortcut("s", modifiers: [.control, .command])
                    Button(ArchivePresentation.menuItem) { delegate.showArchive() }
                        .disabled(!state.isEnabled(.showArchive))
                    Divider()
                    Button(PageMenuText.back) { delegate.goBack() }
                        .keyboardShortcut("[", modifiers: .command)
                        .disabled(!state.pageMenu.canGoBack)
                    Button(PageMenuText.forward) { delegate.goForward() }
                        .keyboardShortcut("]", modifiers: .command)
                        .disabled(!state.pageMenu.canGoForward)
                    Button(PageMenuText.reload) { delegate.reloadPage() }
                        .keyboardShortcut("r", modifiers: .command)
                        .disabled(!state.pageMenu.canReload)
                    Button(PageMenuText.stop) { delegate.stopLoading() }
                        .keyboardShortcut(".", modifiers: .command)
                        .disabled(!state.pageMenu.canStop)
                    Divider()
                    Toggle(PageMenuText.contentBlocking, isOn: Binding(get: { state.pageMenu.blockingOn ?? false }, set: { _ in delegate.toggleContentBlocking() }))
                        .disabled(state.pageMenu.blockingOn == nil)
                }
                #if DEBUG
                CommandMenu(PageMenuText.debugMenu) {
                    Button(PageMenuText.crashPageProcess) { delegate.crashPage() }
                        .disabled(!state.canCrashPage)
                }
                #endif
                CommandMenu(PageChromeText.tabMenu) {
                    // The keyboard route to the row and Essentials context menus: the same SidebarMenus lists, on the highlighted item.
                    ForEach(delegate.menuState.tabActions, id: \.self) { action in
                        Button(action.menuTitle) { delegate.performSidebarAction(action) }
                            .disabled(!state.isEnabled(.sidebarAction))
                    }
                    // The same targets as the row's context menu, for the highlighted tab; absent where the drop would refuse.
                    if !state.moveTargets.isEmpty {
                        Menu(PageChromeText.moveToWorkspaceMenu) {
                            MoveToWorkspaceItems(menu: tabMoveMenu, isDisabled: !state.isEnabled(.sidebarAction))
                        }
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

    /// Tab ▸ Move to Workspace's items, from the menu state the app delegate keeps.
    private var tabMoveMenu: MoveToWorkspaceMenu {
        MoveToWorkspaceMenu(
            targets: state.moveTargets, symbol: { [state] in state.moveSymbols[$0.workspaceID] },
            perform: { [delegate] in delegate.moveHighlightedTab(to: $0) }
        )
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
