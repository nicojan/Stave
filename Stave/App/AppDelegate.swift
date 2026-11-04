import AppKit
import Observation
import StaveCore

/// Opens the store, restores one window per saved `WindowState`, and saves the set as it changes and on quit. Menu commands call into it.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var environment: AppEnvironment?
    private var controllers: [BrowserWindowController] = []
    /// Open private windows. Never in `WindowSession`, never saved, never restored.
    private var privateControllers: [PrivateWindowController] = []
    private var isTerminating = false
    /// True once every saved window is open. A launch that fails part-way must not save its partial set over the user's windows.
    private var launchCompleted = false
    /// What the Workspaces menu and Settings show; refreshed when the key window, its workspaces or the ⌃1–9 setting change.
    let menuState = AppMenuState()
    private var menuGeneration = 0
    private var keyObservers: [NSObjectProtocol] = []
    private var importCoordinator: ImportCoordinator?
    /// The pages' events go through this to their windows. Kept here: `PageHost` holds it weakly.
    private var pageEvents: PageEventsRouter?

    /// The default quit handler would refuse with a sheet up, and the first-run sheet cannot be dismissed, so ours ends the sheets first.
    func applicationWillFinishLaunching(_ notification: Notification) {
        NSAppleEventManager.shared().setEventHandler(
            self, andSelector: #selector(handleQuitEvent(_:withReplyEvent:)),
            forEventClass: AEEventClass(kCoreEventClass), andEventID: AEEventID(kAEQuitApplication)
        )
    }

    @objc private func handleQuitEvent(_ event: NSAppleEventDescriptor, withReplyEvent reply: NSAppleEventDescriptor) {
        quit()
    }

    /// Quitting never waits on a sheet: every sheet on every window ends (an open file picker is a sheet, so it is cancelled), then the app
    /// terminates through the usual save path. An import in flight is one transaction, so quitting during it is atomic.
    func quit() {
        // Pending page history is written while every page is still there, before any window closes.
        environment?.pageHost.flushAll()
        for controller in controllers { controller.sidebarPresenter.dismissAllSheets() }
        for window in NSApp.windows {
            var chain: [NSWindow] = []
            var next = window.attachedSheet
            while let sheet = next { chain.append(sheet); next = sheet.attachedSheet }
            for sheet in chain.reversed() {
                if let panel = sheet as? NSOpenPanel { panel.cancel(nil) }
                sheet.sheetParent?.endSheet(sheet, returnCode: .cancel)
            }
        }
        NSApp.terminate(nil)
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        do {
            let environment = try AppEnvironment.live(options: try DebugLaunchOptions.current)
            let windows = try environment.store.restoredWindows()
            self.environment = environment
            menuState.shortcuts = environment.workspaceShortcuts
            menuState.compactMode = environment.compactMode
            menuState.searchEngine = environment.searchEngine
            importCoordinator = ImportCoordinator(environment: environment, controllers: { [weak self] in self?.controllers ?? [] })
            let router = PageEventsRouter(
                environment: environment, controllers: { [weak self] in self?.controllers ?? [] },
                privateControllers: { [weak self] in self?.privateControllers ?? [] },
                openPrivateWindowForLink: { [weak self] source, opener, url in self?.openPrivateWindow(forLink: url, opener: opener, from: source) }
            )
            environment.pageHost.events = router
            pageEvents = router
            observeKeyWindow()
            for state in windows { try open(state, environment: environment) }
            launchCompleted = true
            presentFirstRunIfNeeded(environment)
            refreshWorkspaceMenu()
            environment.session.enableSaving() // a failed launch never reaches here, so it never writes
        } catch let failure as LaunchArguments.Failure {
            presentLaunchArgumentFailure(failure)
            return
        } catch {
            presentOpenFailure(error)
            return
        }
        controllers.first?.show()
        NSApp.activate(ignoringOtherApps: true)
    }

    /// Closing the last window quits, and the kept-last window state is what the next launch restores.
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }

    func applicationWillTerminate(_ notification: Notification) {
        isTerminating = true
        guard launchCompleted, let environment else { return }
        // Private windows leave nothing: their pages close unflushed, their pop-ups close, their stores and download rows go.
        for controller in privateControllers { controller.tearDown() }
        environment.pageHost.flushAll()
        for controller in controllers { controller.reportNow() }
        environment.sidebarWidth.saveIfChanged()
        do {
            try environment.session.saveNow()
        } catch {
            NSLog("Stave: could not save window state: \(error)")
        }
    }

    // MARK: - Menu commands

    /// ⌘N: a window on the front browser window's profile and workspace, with no tab selected. With no browser window open it starts from the
    /// last state the session knows, else from the saved windows.
    func newWindow() {
        guard let environment, launchCompleted else { return }
        if let key = keyController, !allowed(.newWindow, on: key) { return }
        let front = frontController
        let base = front?.model.windowState ?? environment.session.states.last ?? (try? environment.store.restoredWindows().first) ?? nil
        guard let base else { return }
        let state = WindowState(
            profileID: base.profileID, workspaceID: base.workspaceID, selectedTabID: nil,
            frame: front?.cascadedFrame ?? "", sortIndex: 0
        )
        do {
            try open(state, environment: environment)
        } catch {
            NSLog("Stave: could not open a window: \(error)")
        }
    }

    /// "Open Link in New Window": a window on the opener tab's profile and workspace (that of the window `source` shows it in, not the front
    /// window's), with the link as its one tab and selected, in the opener's data store like any linked tab. A link the window can't open
    /// (its opener tab is gone) leaves no empty window behind.
    private func openWindow(forLink url: String, opener: UUID, from source: BrowserWindowController) {
        guard let environment, launchCompleted else { return }
        let base = source.model.windowState
        let state = WindowState(profileID: base.profileID, workspaceID: base.workspaceID, selectedTabID: nil, frame: source.cascadedFrame, sortIndex: 0)
        do {
            let controller = try open(state, environment: environment)
            if controller.openLinkedTab(opener: opener, url: url, select: true, webView: nil) == nil { controller.window.close() }
        } catch {
            NSLog("Stave: could not open a window for a link: \(error)")
        }
    }

    /// "Open Link in New Window" from a private window: a new private window beside it, with the link as its selected tab.
    private func openPrivateWindow(forLink url: String, opener: UUID, from source: PrivateWindowController) {
        guard let environment, launchCompleted else { return }
        let controller = PrivateWindowController(
            environment: environment, near: source.window,
            onClose: { [weak self] closed in self?.privateWindowClosed(closed) }
        )
        privateControllers = privateControllers + [controller]
        controller.show()
        refreshWorkspaceMenu()
        if controller.openLinkedTab(opener: opener, url: url, select: true, webView: nil) == nil { controller.window.close() }
    }

    /// ⇧⌘N: a private window beside the front window. Opens with an empty tab list; nothing of it is saved.
    func newPrivateWindow() {
        guard let environment, launchCompleted else { return }
        let controller = PrivateWindowController(
            environment: environment, near: NSApp.keyWindow ?? frontController?.window,
            onClose: { [weak self] closed in self?.privateWindowClosed(closed) }
        )
        privateControllers = privateControllers + [controller]
        controller.show()
        controller.openCommandBar(.newTab)
        refreshWorkspaceMenu()
    }

    private func privateWindowClosed(_ closed: PrivateWindowController) {
        privateControllers = privateControllers.filter { $0 !== closed }
        refreshWorkspaceMenu()
    }

    /// The private window that is key, or the one a key sheet is attached to.
    private var keyPrivate: PrivateWindowController? {
        guard let key = NSApp.keyWindow else { return nil }
        return privateControllers.first { $0.window === key || $0.window === key.sheetParent }
    }

    /// ⌘T: the command bar on the key browser window, for a new tab.
    func newTab() {
        if let keyPrivate { if keyPrivate.window.attachedSheet == nil { keyPrivate.openCommandBar(.newTab) }; return }
        guard let controller = keyController, allowed(.newTab, on: controller) else { return }
        controller.openCommandBar(.newTab)
    }

    /// ⌘L: the command bar on the key browser window, prefilled with the selected tab's address.
    func openLocation() {
        if let keyPrivate { if keyPrivate.window.attachedSheet == nil { keyPrivate.openCommandBar(.currentTab) }; return }
        guard let controller = keyController, allowed(.openLocation, on: controller) else { return }
        controller.openCommandBar(.currentTab)
    }

    /// ⌘W: closes the selected tab when the key window is a browser window (or a sheet on one); otherwise closes the key window, as in any app.
    func closeSelectedTab() {
        if let keyPrivate {
            if keyPrivate.window.attachedSheet == nil, let id = keyPrivate.model.selectedTabID { keyPrivate.model.close(id) }
            return
        }
        guard let controller = keyController else { NSApp.keyWindow?.performClose(nil); return }
        guard allowed(.closeTab, on: controller) else { return }
        controller.model.closeSelectedTab()
    }

    /// ⇧⌘W: closes the browser window the key window belongs to; otherwise the key window itself.
    func closeWindow() {
        if let controller = keyController {
            guard allowed(.closeWindow, on: controller) else { return }
            controller.window.performClose(nil)
        } else {
            NSApp.keyWindow?.performClose(nil)
        }
    }

    /// ⌥⌘↑ / ⌥⌘↓: moves the key browser window's highlighted sidebar row one place up (-1) or down (+1). Nothing highlighted does nothing.
    func moveHighlightedRow(by delta: Int) {
        guard let controller = keyController, allowed(.moveRow, on: controller) else { return }
        controller.model.moveHighlighted(by: delta)
    }

    /// Workspaces ▸ Edit / Move / Delete: acts on the key browser window's current workspace.
    func performWorkspaceAction(_ action: WorkspaceAction) {
        guard let controller = keyController, allowed(.workspaceAction, on: controller) else { return }
        controller.sidebarPresenter.perform(action, on: controller.model.snapshot.workspace, in: controller.model)
    }

    /// Tab menu items: act on the key browser window's highlighted sidebar row or Essential (New Folder needs none).
    func performSidebarAction(_ action: SidebarAction) {
        guard let controller = keyController, allowed(.sidebarAction, on: controller) else { return }
        controller.sidebarPresenter.requestSidebarAction(action, on: controller.model.sidebarHighlight)
    }

    /// View ▸ Show Archive: the archive sheet on the key browser window.
    func showArchive() {
        guard let controller = keyController, allowed(.showArchive, on: controller) else { return }
        controller.sidebarPresenter.openArchive(.menu)
    }

    /// File ▸ Import from Arc…: on the key browser window (else the front one). One import at a time; an open one is brought forward.
    func importFromArc() {
        guard launchCompleted, let controller = frontController else { return }
        importCoordinator?.open(on: controller, windowIsBusy: isBusy(controller) && !MenuCommandGate.allowedWhileSheetUp(.importFromArc))
    }

    // MARK: - Page commands

    /// View ▸ Back (⌘[), Forward (⌘]), Reload Page (⌘R) and Stop (⌘.): act on the key browser window's shown page; nothing while a sheet is up.
    func goBack() { if !privatePageCommand({ $0.goBack() }) { pageCommand { $0.goBack() } } }
    func goForward() { if !privatePageCommand({ $0.goForward() }) { pageCommand { $0.goForward() } } }
    func reloadPage() { if !privatePageCommand({ $0.reloadPage() }) { pageCommand { $0.reloadPage() } } }
    func stopLoading() { if !privatePageCommand({ $0.stopLoading() }) { pageCommand { $0.stopLoading() } } }
    /// View ▸ Content Blocking on This Site: switches blocking for the key window's shown page's site, which reloads. In a private window it
    /// applies to that page only and is never remembered.
    func toggleContentBlocking() { if !privatePageCommand({ $0.toggleContentBlocking() }) { pageCommand { $0.toggleContentBlocking() } } }

    #if DEBUG
    /// Debug ▸ Crash Page Process: ends the key window's shown page's web content process through WebKit.
    func crashPage() { pageCommand { $0.crashPage() } }
    #endif

    private func pageCommand(_ run: (BrowserWindowController) -> Void) {
        guard let controller = keyController, !isBusy(controller) else { return }
        run(controller)
    }

    /// The same page commands on the key private window.
    private func privatePageCommand(_ run: (PrivateWindowController) -> Void) -> Bool {
        guard let keyPrivate else { return false }
        if keyPrivate.window.attachedSheet == nil { run(keyPrivate) }
        return true
    }

    // MARK: - First run

    /// Shows the first-run sheet on the first window of this launch, once, while the setting says it has not been completed.
    private func presentFirstRunIfNeeded(_ environment: AppEnvironment) {
        guard let first = controllers.first else { return }
        do {
            guard try environment.store.setting(SettingKeys.firstRunCompleted) == false else { return }
        } catch {
            NSLog("Stave: could not read the first-run setting: \(error)")
            return
        }
        let offers: Bool
        do {
            offers = try ArcImportFlow.shouldOfferOnFirstRun(arcHome: environment.arcHome, store: environment.store)
        } catch {
            NSLog("Stave: could not check whether to offer the Arc import: \(error)")
            offers = false
        }
        first.sidebarPresenter.sheet = .firstRun(FirstRunRequest(offersArcImport: offers))
    }

    private func completeFirstRun(on controller: BrowserWindowController, engine: SearchEngine, importFromArc: Bool) {
        guard let environment else { return }
        do {
            try environment.store.completeFirstRun(engine: engine)
        } catch {
            let alert = NSAlert()
            alert.alertStyle = .warning
            alert.messageText = "Stave couldn't save your choice."
            alert.informativeText = StoreErrorText.message(for: error)
            alert.addButton(withTitle: "OK")
            // The first-run sheet is still attached and cannot be dismissed, so the alert goes on top of it.
            alert.beginSheetModal(for: controller.window.attachedSheet ?? controller.window)
            return
        }
        environment.revision.bump()
        controller.sidebarPresenter.sheet = nil
        // The first-run sheet is still leaving, so the window is not "busy" for this hand-over.
        if importFromArc { importCoordinator?.open(on: controller, windowIsBusy: false) }
    }

    /// View ▸ Compact Mode (⌃⌘S): flips the setting through the store, so every window follows. Works with Settings key too.
    func toggleCompactMode() { environment?.compactMode.toggle() }

    // MARK: - Workspaces menu

    /// ⌃1–9 and the Workspaces menu items: the key browser window switches. With no browser window key (Settings, say) nothing happens.
    func switchWorkspace(to id: UUID) {
        guard let controller = keyController, allowed(.switchWorkspace, on: controller) else { return }
        controller.model.switchWorkspace(to: id)
    }

    /// Workspaces ▸ New Workspace…: opens the editor sheet on the key browser window.
    func newWorkspace() {
        guard let controller = keyController, allowed(.newWorkspace, on: controller) else { return }
        controller.sidebarPresenter.workspaceEditor = .create
    }

    /// True while a sheet is attached to the window, a file picker is open, or a sheet (first run, import, workspace editor, new profile) is about to show.
    private func isBusy(_ controller: BrowserWindowController) -> Bool {
        let presenter = controller.sidebarPresenter
        return MenuCommandGate.isBusy(
            hasAttachedSheet: controller.window.attachedSheet != nil,
            isPicking: importCoordinator?.isPicking ?? false,
            hasPendingSheet: presenter.sheet != nil || presenter.workspaceEditor != nil || presenter.showNewProfile || presenter.pendingWorkspaceDelete != nil
                || presenter.showArchiveSheet
        )
    }

    /// A window-acting menu command runs unless a sheet is up and the gate says it must wait.
    private func allowed(_ command: MenuCommand, on controller: BrowserWindowController) -> Bool {
        !isBusy(controller) || MenuCommandGate.allowedWhileSheetUp(command)
    }

    /// Rebuilds the menu's items from the key window's workspaces and the setting, and re-arms itself for the next change to either.
    /// The key window is not observable, so window notifications call this too; a generation number retires the older trackers.
    private func refreshWorkspaceMenu() {
        menuGeneration += 1
        let generation = menuGeneration
        let menu: MenuSnapshot = withObservationTracking {
            // With no browser window key (Settings in front) the checkmark follows the setting itself.
            if let keyPrivate { return Self.privateMenu(keyPrivate, compact: environment?.compactMode.isEnabled ?? false) }
            guard let controller = keyController, let shortcuts = environment?.workspaceShortcuts else {
                return MenuSnapshot(compact: environment?.compactMode.isEnabled ?? false)
            }
            let model = controller.model
            let workspaces = model.workspaces
            let index = workspaces.firstIndex { $0.id == model.snapshot.workspace.id }
            let busy = isBusy(controller)
            let page = controller.shownPage
            let summary = page.map {
                PageStatusSummary(
                    isLoading: $0.status.isLoading, canGoBack: $0.status.canGoBack, canGoForward: $0.status.canGoForward,
                    hasPage: true, blockingOn: $0.isContentBlockingOn
                )
            }
            #if DEBUG
            let canCrash = !busy && controller.canCrashPage
            #else
            let canCrash = false
            #endif
            return MenuSnapshot(
                items: WorkspaceMenus.switchItems(workspaces: workspaces, currentID: model.snapshot.workspace.id, shortcutsEnabled: shortcuts.isEnabled),
                compact: model.isCompact,
                workspaceActions: index.map { WorkspaceMenus.menuItems(index: $0, count: workspaces.count) } ?? [],
                tabActions: SidebarMenus.menuActions(highlight: model.sidebarHighlight, rows: model.rows, snapshot: model.snapshot),
                canMoveUp: SidebarMenus.canMove(highlight: model.sidebarHighlight, by: -1, snapshot: model.snapshot),
                canMoveDown: SidebarMenus.canMove(highlight: model.sidebarHighlight, by: 1, snapshot: model.snapshot),
                busy: busy,
                pageMenu: PageMenuState.from(status: summary, sheetOpen: busy),
                canCrashPage: canCrash
            )
        } onChange: { [weak self] in
            Task { @MainActor in
                guard let self, self.menuGeneration == generation else { return }
                self.refreshWorkspaceMenu()
            }
        }
        if menuState.workspaceItems != menu.items { menuState.workspaceItems = menu.items }
        if menuState.isCompact != menu.compact { menuState.isCompact = menu.compact }
        if menuState.workspaceActions != menu.workspaceActions { menuState.workspaceActions = menu.workspaceActions }
        if menuState.tabActions != menu.tabActions { menuState.tabActions = menu.tabActions }
        if menuState.canMoveUp != menu.canMoveUp { menuState.canMoveUp = menu.canMoveUp }
        if menuState.canMoveDown != menu.canMoveDown { menuState.canMoveDown = menu.canMoveDown }
        if menuState.isBusy != menu.busy { menuState.isBusy = menu.busy }
        if menuState.pageMenu != menu.pageMenu { menuState.pageMenu = menu.pageMenu }
        if menuState.canCrashPage != menu.canCrashPage { menuState.canCrashPage = menu.canCrashPage }
    }

    /// The menus for a key private window: only the page commands; no workspaces, tab actions or moves.
    private static func privateMenu(_ controller: PrivateWindowController, compact: Bool) -> MenuSnapshot {
        let busy = controller.window.attachedSheet != nil
        let summary = controller.shownPage.map {
            PageStatusSummary(
                isLoading: $0.status.isLoading, canGoBack: $0.status.canGoBack, canGoForward: $0.status.canGoForward,
                hasPage: true, blockingOn: $0.isContentBlockingOn
            )
        }
        return MenuSnapshot(compact: compact, busy: busy, pageMenu: PageMenuState.from(status: summary, sheetOpen: busy))
    }

    /// Everything the menus show for the key window, read in one observation pass.
    private struct MenuSnapshot {
        var items: [WorkspaceSwitchItem] = []
        var compact = false
        var workspaceActions: [WorkspaceMenuItem] = []
        var tabActions: [SidebarAction] = []
        var canMoveUp = false
        var canMoveDown = false
        var busy = false
        var pageMenu = PageMenuState.disabled
        var canCrashPage = false
    }

    private func observeKeyWindow() {
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

    // MARK: - Windows

    /// The browser window that is key, or the one a key sheet is attached to. Nil when the key window is something else (Settings).
    private var keyController: BrowserWindowController? {
        guard let key = NSApp.keyWindow else { return nil }
        return controllers.first { $0.window === key || $0.window === key.sheetParent }
    }

    private var frontController: BrowserWindowController? {
        keyController
            ?? controllers.first { $0.window === NSApp.mainWindow }
            ?? controllers.first
    }

    @discardableResult
    private func open(_ state: WindowState, environment: AppEnvironment) throws -> BrowserWindowController {
        let controller = try BrowserWindowController(
            state: state, environment: environment,
            onNewWindow: { [weak self] in self?.newWindow() },
            onImportFromArc: { [weak self] in self?.importFromArc() },
            onClose: { [weak self] closed in self?.windowClosed(closed) }
        )
        controller.onCompleteFirstRun = { [weak self, weak controller] engine, importArc in
            guard let self, let controller else { return }
            self.completeFirstRun(on: controller, engine: engine, importFromArc: importArc)
        }
        controller.onChooseAnotherFile = { [weak self] session in self?.importCoordinator?.chooseAnotherFile(for: session) }
        controller.peers = { [weak self] in self?.controllers ?? [] }
        controller.onOpenLinkInNewWindow = { [weak self] source, opener, url in self?.openWindow(forLink: url, opener: opener, from: source) }
        // A window kept because it was the last to close has no controller; the new window replaces it rather than joining it. Only after the
        // controller exists: a failed init must leave the saved set alone.
        environment.session.discardStates(exceptLive: Set(controllers.map { $0.model.windowID } + [controller.model.windowID]))
        controllers = controllers + [controller]
        controller.show()
        refreshWorkspaceMenu()
        return controller
    }

    private func windowClosed(_ closed: BrowserWindowController) {
        // A window closing because the app is quitting stays in the saved set.
        if !isTerminating, let environment {
            let isLast = controllers.count == 1
            environment.session.windowClosed(closed.model.windowID, isLast: isLast)
            if !isLast {
                do { try environment.session.saveNow() } catch { NSLog("Stave: could not save window state: \(error)") }
            }
        }
        controllers = controllers.filter { $0 !== closed }
        refreshWorkspaceMenu()
    }

    // MARK: - Failure

    private func presentLaunchArgumentFailure(_ failure: LaunchArguments.Failure) {
        guard case .unusable(let flag) = failure else { return }
        let alert = NSAlert()
        alert.alertStyle = .critical
        alert.messageText = "Stave did not start: \(flag) needs an absolute path."
        alert.informativeText = "The flag was given with no value, a value starting with \"-\", or a relative path. Fix it or remove it; Stave will not fall back to your real folders."
        alert.addButton(withTitle: "Quit")
        alert.runModal()
        NSApp.terminate(nil)
    }

    private func presentOpenFailure(_ error: Error) {
        let alert = NSAlert()
        alert.alertStyle = .critical
        if let storeError = error as? StoreError, storeError == .newerSchema {
            alert.messageText = "This copy of Stave is older than the one that last used your data. Install the newest Stave to open it."
        } else {
            alert.messageText = "Stave could not open its data."
            alert.informativeText = "\(error)"
        }
        alert.addButton(withTitle: "Quit")
        alert.runModal()
        NSApp.terminate(nil)
    }
}
