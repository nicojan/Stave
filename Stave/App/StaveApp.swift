import SwiftUI
import StaveCore

@main
struct StaveApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate

    private var state: AppMenuState { delegate.menuState }

    // Windows are AppKit-managed (see AppDelegate); SwiftUI only needs a scene, which also hosts the menu commands. Every key comes from
    // `StandardShortcuts` through `standardShortcut(_:state:enabled:)` (decision 16), which also applies the entry's declared gate; each block stays within the ten children Xcode 26 (CI) accepts.
    var body: some Scene {
        Settings {
            SettingsView(
                state: delegate.menuState,
                makeDefaultBrowser: { delegate.makeDefaultBrowser() }, refreshDefaultBrowser: { delegate.refreshDefaultBrowser() },
                showBackups: { delegate.showBackupsInFinder() },
                frontProfileID: { delegate.frontController?.model.snapshot.profile.id }
            )
        }
            .commands {
                CommandGroup(replacing: .appTermination) {
                    Button(PageChromeText.quitMenuItem) { delegate.quit() }
                        .standardShortcut(.quit, state: state)
                }
                CommandGroup(replacing: .newItem) {
                    Button(CommandBarText.newTabMenuItem) { delegate.newTab() }
                        .standardShortcut(.newTab, state: state)
                    Button(PageChromeText.newWindowMenuItem) { delegate.newWindow() }
                        .standardShortcut(.newWindow, state: state)
                    Button(PrivateWindowText.menuItem) { delegate.newPrivateWindow() }
                        .standardShortcut(.newPrivateWindow, state: state)
                }
                CommandGroup(after: .newItem) {
                    Button(ExternalOpenText.openFileMenuItem) { delegate.openFile() }
                        .standardShortcut(.openFile, state: state)
                    Button(CommandBarText.openLocationMenuItem) { delegate.openLocation() }
                        .standardShortcut(.openLocation, state: state)
                    Divider()
                    Button(ArcImportSheetContent.menuItemTitle) { delegate.importFromArc() }
                        .disabled(!state.isEnabled(.importFromArc))
                }
                CommandGroup(replacing: .saveItem) {
                    Button(PageChromeText.closeTabMenuItem) { delegate.closeSelectedTab() }
                        .standardShortcut(.closeTab, state: state)
                    Button(PageChromeText.closeWindowMenuItem) { delegate.closeWindow() }
                        .standardShortcut(.closeWindow, state: state)
                }
                CommandGroup(replacing: .printItem) {
                    Button(PageMenuText.print) { delegate.printPage() }
                        .standardShortcut(.print, state: state, enabled: state.pageMenu.canPrint)
                }
                // Replaces the system's text-editing group, so its Find items never sit beside these with the same keys.
                CommandGroup(replacing: .textEditing) {
                    Menu(FindText.menu) {
                        Button(FindText.findMenuItem) { delegate.showFind() }
                            .standardShortcut(.find, state: state, enabled: state.findMenu.canFind)
                        Button(FindText.findNextMenuItem) { delegate.findNext() }
                            .standardShortcut(.findNext, state: state, enabled: state.findMenu.canFindAgain)
                        Button(FindText.findPreviousMenuItem) { delegate.findPrevious() }
                            .standardShortcut(.findPrevious, state: state, enabled: state.findMenu.canFindAgain)
                        Button(FindText.useSelectionMenuItem) { delegate.useSelectionForFind() }
                            .standardShortcut(.useSelectionForFind, state: state, enabled: state.findMenu.canUseSelection)
                    }
                }
                ViewCommands(delegate: delegate)
                HistoryAndDevelopCommands(delegate: delegate)
                TabCommands(delegate: delegate)
                WorkspacesCommands(delegate: delegate)
            }
    }
}

/// The View menu's items after the sidebar group: compact mode and the archive, the page commands, zoom, blocking and downloads.
private struct ViewCommands: Commands {
    let delegate: AppDelegate
    private var state: AppMenuState { delegate.menuState }

    var body: some Commands {
        CommandGroup(after: .sidebar) {
            Toggle(CompactModeSetting.menuTitle, isOn: Binding(get: { delegate.menuState.isCompact }, set: { _ in delegate.toggleCompactMode() }))
                .standardShortcut(.toggleCompactMode, state: state)
            Button(ArchivePresentation.menuItem) { delegate.showArchive() }
                .disabled(!state.isEnabled(.showArchive))
            Divider()
            PageNavigationItems(delegate: delegate)
            Divider()
            ZoomItems(delegate: delegate)
            Divider()
            SiteItems(delegate: delegate)
            Button(ShortcutText.title(.showDownloads)) { delegate.showDownloads() }
                .standardShortcut(.showDownloads, state: state, enabled: state.tabKeys.canShowDownloads)
        }
    }
}

/// View ▸ Back, Forward, Reload Page and Stop.
private struct PageNavigationItems: View {
    let delegate: AppDelegate
    private var state: AppMenuState { delegate.menuState }

    var body: some View {
        Button(PageMenuText.back) { delegate.goBack() }
            .standardShortcut(.back, state: state, enabled: state.pageMenu.canGoBack)
        Button(PageMenuText.forward) { delegate.goForward() }
            .standardShortcut(.forward, state: state, enabled: state.pageMenu.canGoForward)
        Button(PageMenuText.reload) { delegate.reloadPage() }
            .standardShortcut(.reload, state: state, enabled: state.pageMenu.canReload)
        Button(PageMenuText.stop) { delegate.stopLoading() }
            .standardShortcut(.stop, state: state, enabled: state.pageMenu.canStop)
    }
}

/// View ▸ Content Blocking, Settings for This Website, and Open in Safari / Chrome (only for an app that is installed): the page's per-site
/// items, kept in their own view so the View group stays under the result builder's ten-child limit.
private struct SiteItems: View {
    let delegate: AppDelegate
    private var state: AppMenuState { delegate.menuState }

    var body: some View {
        Toggle(PageMenuText.contentBlocking, isOn: Binding(get: { state.pageMenu.blockingOn ?? false }, set: { _ in delegate.toggleContentBlocking() }))
            .disabled(state.pageMenu.blockingOn == nil)
        Button(SitePanelText.menuItem) { delegate.showSitePanel() }
            .disabled(!state.pageMenu.canShowSitePanel)
        ForEach(state.installedBrowsers, id: \.self) { app in
            Button(app.menuTitle) { delegate.openInBrowser(app) }
                .disabled(!state.pageMenu.canOpenElsewhere)
        }
    }
}

/// View ▸ Actual Size, Zoom In and Zoom Out, in Safari's order. ⌘= also zooms in: the table's hidden alternate (`installHiddenShortcuts`).
private struct ZoomItems: View {
    let delegate: AppDelegate
    private var state: AppMenuState { delegate.menuState }

    var body: some View {
        Button(PageMenuText.actualSize) { delegate.actualSize() }
            .standardShortcut(.actualSize, state: state, enabled: state.pageMenu.canResetZoom)
        Button(PageMenuText.zoomIn) { delegate.zoomIn() }
            .standardShortcut(.zoomIn, state: state, enabled: state.pageMenu.canZoomIn)
        Button(PageMenuText.zoomOut) { delegate.zoomOut() }
            .standardShortcut(.zoomOut, state: state, enabled: state.pageMenu.canZoomOut)
    }
}

/// The History, Develop and (in Debug builds) Debug menus.
private struct HistoryAndDevelopCommands: Commands {
    let delegate: AppDelegate
    private var state: AppMenuState { delegate.menuState }

    var body: some Commands {
        CommandMenu(HistoryText.menu) {
            Button(HistoryText.showAllHistory) { delegate.showAllHistory() }
                .standardShortcut(.showAllHistory, state: state, enabled: state.canShowHistory)
            Button(ShortcutText.title(.reopenClosedTab)) { delegate.reopenLastClosedTab() }
                .standardShortcut(.reopenClosedTab, state: state, enabled: state.tabKeys.canReopenClosedTab)
            Divider()
            Button(HistoryText.clearHistoryMenuItem) { delegate.clearHistory() }
                .disabled(!state.canShowHistory)
        }
        // Always visible, with no setting (decision 14); each item is disabled when the private piece it needs is missing.
        CommandMenu(PageMenuText.developMenu) {
            Button(PageMenuText.showWebInspector) { delegate.showWebInspector() }
                .standardShortcut(.showWebInspector, state: state, enabled: state.pageMenu.canInspect)
            Button(PageMenuText.showPageSource) { delegate.showPageSource() }
                .standardShortcut(.showPageSource, state: state, enabled: state.pageMenu.canShowSource)
        }
        #if DEBUG
        CommandMenu(PageMenuText.debugMenu) {
            Button(PageMenuText.crashPageProcess) { delegate.crashPage() }
                .disabled(!state.canCrashPage)
        }
        #endif
    }
}

/// The Tab menu: ⌘D's Pin Tab for the selected tab, the highlighted row's actions, moves, and going from tab to tab.
private struct TabCommands: Commands {
    let delegate: AppDelegate
    private var state: AppMenuState { delegate.menuState }

    var body: some Commands {
        CommandMenu(PageChromeText.tabMenu) {
            // A fixed item on the selected tab (question 18). Only one "Pin Tab" is ever shown: while ⌘D can pin, the highlight's
            // own Pin is left out below; while it can't and the highlight offers Pin, the fixed (disabled) item steps aside.
            if state.pageMenu.canPinSelected || !state.tabActions.contains(.pin) {
                Button(ShortcutText.title(.pinTab)) { delegate.pinSelectedTab() }
                    .standardShortcut(.pinTab, state: state, enabled: state.pageMenu.canPinSelected)
            }
            // The keyboard route to the row and Essentials context menus: the same SidebarMenus lists, on the highlighted item.
            ForEach(SidebarMenus.tabMenuActions(state.tabActions, fixedPinEnabled: state.pageMenu.canPinSelected), id: \.self) { action in
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
                .standardShortcut(.moveRowUp, state: state, enabled: delegate.menuState.canMoveUp)
            Button(SidebarAction.moveDown.title) { delegate.moveHighlightedRow(by: 1) }
                .standardShortcut(.moveRowDown, state: state, enabled: delegate.menuState.canMoveDown)
            Divider()
            TabSwitchItems(delegate: delegate)
        }
    }

    /// Tab ▸ Move to Workspace's items, from the menu state the app delegate keeps.
    private var tabMoveMenu: MoveToWorkspaceMenu {
        MoveToWorkspaceMenu(
            targets: state.moveTargets, symbol: { [state] in state.moveSymbols[$0.workspaceID] },
            perform: { [delegate] in delegate.moveHighlightedTab(to: $0) }
        )
    }
}

/// Tab ▸ Show Next Tab (⌃Tab; ⇧⌘] too) and Show Previous Tab (⌃⇧Tab; ⇧⌘[ too). ⌘1–9 have no item, as in Safari: the key monitor handles them.
private struct TabSwitchItems: View {
    let delegate: AppDelegate
    private var state: AppMenuState { delegate.menuState }

    var body: some View {
        Button(ShortcutText.title(.nextTab)) { delegate.selectAdjacentTab(1) }
            .standardShortcut(.nextTab, state: state, enabled: state.tabKeys.canSelectTab)
        Button(ShortcutText.title(.previousTab)) { delegate.selectAdjacentTab(-1) }
            .standardShortcut(.previousTab, state: state, enabled: state.tabKeys.canSelectTab)
    }
}

/// The Workspaces menu: one switch item per workspace (⌃1–9), New Workspace…, and the current workspace's actions.
private struct WorkspacesCommands: Commands {
    let delegate: AppDelegate
    private var state: AppMenuState { delegate.menuState }

    var body: some Commands {
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

    /// One switch item; a checkmark marks the current workspace, and ⌃digit is attached only when the item has a digit.
    @ViewBuilder
    private func workspaceItem(_ item: WorkspaceSwitchItem) -> some View {
        let toggle = Toggle(item.title, isOn: Binding(get: { item.isCurrent }, set: { _ in delegate.switchWorkspace(to: item.workspaceID) }))
        if let digit = item.shortcutDigit {
            toggle.standardShortcut(.switchWorkspace(digit), state: state)
        } else {
            toggle.disabled(!state.isEnabled(.switchWorkspace))
        }
    }
}
