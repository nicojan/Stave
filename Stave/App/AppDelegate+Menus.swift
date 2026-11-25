import AppKit
import Observation
import StaveCore
import StaveWeb

/// The menu bar's state for the key window: rebuilt in one observation pass whenever the key window, its workspaces, its highlight, its
/// page or a setting changes. Every rule it shows is a StaveCore function; this only gathers the inputs.
extension AppDelegate {
    /// Rebuilds the menu's items from the key window's workspaces and the setting, and re-arms itself for the next change to either.
    /// The key window is not observable, so window notifications call this too; a generation number retires the older trackers.
    func refreshWorkspaceMenu() {
        menuGeneration += 1
        let generation = menuGeneration
        let menu: MenuSnapshot = withObservationTracking {
            currentMenu()
        } onChange: { [weak self] in
            Task { @MainActor in
                guard let self, self.menuGeneration == generation else { return }
                self.refreshWorkspaceMenu()
            }
        }
        apply(menu)
    }

    /// What the menus show now. With no browser window key (Settings in front) the compact checkmark follows the setting itself.
    private func currentMenu() -> MenuSnapshot {
        if let keyPrivate {
            let hasDownloads = environment?.downloads.hasItems(for: .privateWindow(keyPrivate.windowID)) ?? false
            return Self.privateMenu(keyPrivate, compact: environment?.compactMode.isEnabled ?? false, hasDownloads: hasDownloads)
        }
        guard let controller = keyController, let shortcuts = environment?.workspaceShortcuts else {
            return MenuSnapshot(compact: environment?.compactMode.isEnabled ?? false)
        }
        let model = controller.model
        let workspaces = model.workspaces
        let index = workspaces.firstIndex { $0.id == model.snapshot.workspace.id }
        let busy = isBusy(controller)
        #if DEBUG
        let canCrash = !busy && controller.canCrashPage
        #else
        let canCrash = false
        #endif
        let moveTargets = model.moveTargets(for: model.sidebarHighlight)
        let section = model.selectedSection
        let pageMenu = PageMenuState.from(
            status: controller.shownPage.map { Self.summary(of: $0, section: section) }, sheetOpen: busy, historyShown: model.isShowingHistory
        )
        let hasDownloads = environment?.downloads.hasItems(for: .profile(model.snapshot.profile.id)) ?? false
        return MenuSnapshot(
            items: WorkspaceMenus.switchItems(workspaces: workspaces, currentID: model.snapshot.workspace.id, shortcutsEnabled: shortcuts.isEnabled),
            compact: model.isCompact,
            workspaceActions: index.map { WorkspaceMenus.menuItems(index: $0, count: workspaces.count) } ?? [],
            tabActions: SidebarMenus.menuActions(highlight: model.sidebarHighlight, rows: model.rows, snapshot: model.snapshot),
            moveTargets: moveTargets,
            moveSymbols: Dictionary(uniqueKeysWithValues: moveTargets.compactMap { target in
                SidebarMenus.moveTargetSymbol(target, workspaces: workspaces).map { (target.workspaceID, $0) }
            }),
            canMoveUp: SidebarMenus.canMove(highlight: model.sidebarHighlight, by: -1, snapshot: model.snapshot),
            canMoveDown: SidebarMenus.canMove(highlight: model.sidebarHighlight, by: 1, snapshot: model.snapshot),
            busy: busy,
            pageMenu: pageMenu,
            findMenu: FindMenuState.from(pageMenu: pageMenu, find: controller.find.current),
            canCrashPage: canCrash,
            canShowHistory: HistoryText.isShowAllHistoryEnabled(isPrivate: false, busy: busy),
            tabKeys: TabShortcutMenuState.from(busy: busy, isPrivate: false, tabCount: model.tabsInSidebarOrder.count, hasDownloads: hasDownloads)
        )
    }

    /// Writes only what changed, so a refresh that changes nothing re-renders no menu.
    private func apply(_ menu: MenuSnapshot) {
        if menuState.workspaceItems != menu.items { menuState.workspaceItems = menu.items }
        if menuState.isCompact != menu.compact { menuState.isCompact = menu.compact }
        if menuState.workspaceActions != menu.workspaceActions { menuState.workspaceActions = menu.workspaceActions }
        if menuState.tabActions != menu.tabActions { menuState.tabActions = menu.tabActions }
        if menuState.moveTargets != menu.moveTargets { menuState.moveTargets = menu.moveTargets }
        if menuState.moveSymbols != menu.moveSymbols { menuState.moveSymbols = menu.moveSymbols }
        if menuState.canMoveUp != menu.canMoveUp { menuState.canMoveUp = menu.canMoveUp }
        if menuState.canMoveDown != menu.canMoveDown { menuState.canMoveDown = menu.canMoveDown }
        if menuState.isBusy != menu.busy { menuState.isBusy = menu.busy }
        if menuState.pageMenu != menu.pageMenu { menuState.pageMenu = menu.pageMenu }
        if menuState.findMenu != menu.findMenu { menuState.findMenu = menu.findMenu }
        if menuState.canCrashPage != menu.canCrashPage { menuState.canCrashPage = menu.canCrashPage }
        if menuState.canShowHistory != menu.canShowHistory { menuState.canShowHistory = menu.canShowHistory }
        if menuState.tabKeys != menu.tabKeys { menuState.tabKeys = menu.tabKeys }
    }

    /// The menus for a key private window: only the page commands; no workspaces, tab actions or moves.
    private static func privateMenu(_ controller: PrivateWindowController, compact: Bool, hasDownloads: Bool) -> MenuSnapshot {
        let busy = controller.window.attachedSheet != nil
        let pageMenu = PageMenuState.from(status: controller.shownPage.map { summary(of: $0, isPrivate: true) }, sheetOpen: busy)
        return MenuSnapshot(
            compact: compact, busy: busy, pageMenu: pageMenu, findMenu: FindMenuState.from(pageMenu: pageMenu, find: controller.find.current),
            tabKeys: TabShortcutMenuState.from(busy: busy, isPrivate: true, tabCount: controller.model.tabs.count, hasDownloads: hasDownloads)
        )
    }

    /// A live page's status for the page menu. The blocking toggle applies only to a page with a web site (`PageMenuState.blockingState`).
    /// `section` is where the selected tab sits, for ⌘D's rule; a private window's page has none.
    static func summary(of page: LivePage, section: SlotSection? = nil, isPrivate: Bool = false) -> PageStatusSummary {
        PageStatusSummary(
            isLoading: page.status.isLoading, canGoBack: page.status.canGoBack, canGoForward: page.status.canGoForward,
            hasPage: true, blockingOn: PageMenuState.blockingState(url: page.status.url, isOn: page.isContentBlockingOn),
            hasFailure: page.status.failure != nil, isBlank: PageMenuState.isBlank(url: page.status.url), zoom: page.zoom,
            inspectorAvailable: PageTools.canShowInspector(page.webView), sourceAvailable: PageTools.canShowPageSource(page.webView),
            selectedSection: section, isPrivate: isPrivate
        )
    }

    /// Everything the menus show for the key window, read in one observation pass.
    private struct MenuSnapshot {
        var items: [WorkspaceSwitchItem] = []
        var compact = false
        var workspaceActions: [WorkspaceMenuItem] = []
        var tabActions: [SidebarAction] = []
        var moveTargets: [TabMoveTarget] = []
        var moveSymbols: [UUID: String] = [:]
        var canMoveUp = false
        var canMoveDown = false
        var busy = false
        var pageMenu = PageMenuState.disabled
        var findMenu = FindMenuState.disabled
        var canCrashPage = false
        /// False for a private window and with no browser window key (the defaults).
        var canShowHistory = false
        var tabKeys = TabShortcutMenuState.disabled
    }

    func observeKeyWindow() {
        installHiddenShortcuts()
        let center = NotificationCenter.default
        keyObservers = [
            NSWindow.didBecomeKeyNotification, NSWindow.didResignKeyNotification,
            NSWindow.willBeginSheetNotification, NSWindow.didEndSheetNotification,
        ].map { name in
            center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                // Deferred: during a resign, `NSApp.keyWindow` still names the old window.
                Task { @MainActor in self?.refreshWorkspaceMenu() }
            }
        }
    }
}
