import AppKit
import Observation
import StaveCore

/// Opens the store, restores one window per saved `WindowState`, and saves the set as it changes and on quit. Menu commands call into it.
/// Private windows are in `AppDelegate+Private.swift`, the menu bar's state in `AppDelegate+Menus.swift`; the members those files use are
/// internal rather than private for that reason only.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private(set) var environment: AppEnvironment?
    private(set) var controllers: [BrowserWindowController] = []
    /// Open private windows. Never in `WindowSession`, never saved, never restored.
    var privateControllers: [PrivateWindowController] = []
    private var isTerminating = false
    /// True once every saved window is open. A launch that fails part-way must not save its partial set over the user's windows.
    private(set) var launchCompleted = false
    /// What the Workspaces menu and Settings show; refreshed when the key window, its workspaces or the ⌃1–9 setting change.
    let menuState = AppMenuState()
    var menuGeneration = 0
    var keyObservers: [NSObjectProtocol] = []
    private(set) var importCoordinator: ImportCoordinator?
    /// The pages' events go through this to their windows. Kept here: `PageHost` holds it weakly.
    private var pageEvents: PageEventsRouter?
    /// Links and files from other apps that arrived before launch completed (decision 7); see `AppDelegate+Links.swift`.
    let pendingLinks = PendingLinks()

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
            menuState.externalLinks = environment.externalLinks
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
        observeDefaultBrowser()
        openPendingLinks()
    }

    /// Stave stays open with no windows, as Safari, Chrome and Firefox do (decision 31). The last window closed stays in the saved set until
    /// another browser window opens (`open` drops it), so a quit with no window open restores it and a quit after ⌘N restores only the new one.
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    /// A Dock click with no browser window open, normal or private, opens one through the ⌘N path (Settings alone doesn't count). With only
    /// private windows open it brings the newest forward. With browser windows open, AppKit's usual handling applies.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        guard launchCompleted, controllers.isEmpty else { return true }
        if let privateWindow = privateControllers.last {
            privateWindow.show()
        } else {
            newWindow()
        }
        return false
    }

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
    /// last state the session knows, else from the saved windows. Nothing while a sheet (or a sheet on a sheet) is up on the key window.
    func newWindow() {
        guard let environment, launchCompleted, !keyWindowIsBusy(for: .newWindow) else { return }
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

    /// "Open Link in New Window": a window on the opener tab's own profile and workspace, read from its stored record (not the front window's,
    /// and not the window `source` that happens to route the event: a pop-up's opener tab may be selected nowhere), with the link as its
    /// one tab and selected, in the opener's data store like any linked tab. The opener is checked before the window is made. If the window
    /// can't be made or can't take the link, the link opens as a tab in `source` instead of being lost.
    private func openWindow(forLink url: String, opener: UUID, from source: BrowserWindowController) {
        guard let environment, launchCompleted else { return }
        guard let home = try? environment.store.tabHome(forTab: opener) else {
            openAsTab(url, opener: opener, in: source)
            return
        }
        let base = source.model.windowState
        // An Essential belongs to a profile, not a workspace: it opens on the source window's workspace.
        let workspaceID = home.workspaceID ?? (base.profileID == home.profileID ? base.workspaceID : nil)
        guard let workspaceID else {
            openAsTab(url, opener: opener, in: source)
            return
        }
        let state = WindowState(profileID: home.profileID, workspaceID: workspaceID, selectedTabID: nil, frame: source.cascadedFrame, sortIndex: 0)
        do {
            let controller = try open(state, environment: environment)
            if controller.openLinkedTab(opener: opener, url: url, select: true, webView: nil) == nil {
                controller.window.close()
                openAsTab(url, opener: opener, in: source)
            }
        } catch {
            NSLog("Stave: could not open a window for a link: \(error)")
            openAsTab(url, opener: opener, in: source)
        }
    }

    private func openAsTab(_ url: String, opener: UUID, in source: BrowserWindowController) {
        if source.openLinkedTab(opener: opener, url: url, select: true, webView: nil) == nil {
            NSLog("Stave: could not open a link from a tab that is gone")
        }
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

    /// Tab ▸ Move to Workspace: sends the key browser window's highlighted tab to another workspace, as dropping it on that workspace's icon
    /// does. The selected tab takes the window with it.
    func moveHighlightedTab(to target: TabMoveTarget) {
        guard let controller = keyController, allowed(.sidebarAction, on: controller), let item = controller.model.sidebarHighlight else { return }
        controller.model.run(target, on: item)
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
    func isBusy(_ controller: BrowserWindowController) -> Bool {
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

    /// Whether `command` must wait because the key window, browser or private, has a sheet up. False with no such window key (Settings).
    func keyWindowIsBusy(for command: MenuCommand) -> Bool {
        if let keyPrivate { return keyPrivate.window.attachedSheet != nil && !MenuCommandGate.allowedWhileSheetUp(command) }
        if let controller = keyController { return !allowed(command, on: controller) }
        return false
    }

    // MARK: - Windows

    /// The browser window that is key, or the one a key sheet is attached to, however deep the sheets nest (an alert over the archive sheet
    /// still names its window, so the sheet gate holds). Nil when the key window is something else (Settings).
    var keyController: BrowserWindowController? {
        guard let key = NSApp.keyWindow else { return nil }
        let root = Self.rootWindow(of: key)
        return controllers.first { $0.window === root }
    }

    /// The window at the bottom of `window`'s sheet chain: itself when it is not a sheet.
    static func rootWindow(of window: NSWindow) -> NSWindow {
        window.sheetParent.map(rootWindow(of:)) ?? window
    }

    var frontController: BrowserWindowController? {
        keyController
            ?? controllers.first { $0.window === NSApp.mainWindow }
            ?? controllers.first
    }

    @discardableResult
    func open(_ state: WindowState, environment: AppEnvironment) throws -> BrowserWindowController {
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
            } else {
                // Stave stays open with no browser window (decision 31). Every browser-window page is unloaded (flushed first), its
                // questions ended and its pop-ups closed, so a background tab's audio, camera or microphone stops as in Safari, Chrome and
                // Firefox. Private pages belong to their own windows, which close them.
                for id in environment.pageHost.persistentTabIDs { closed.tabUnloaded(id) }
            }
        }
        controllers = controllers.filter { $0 !== closed }
        refreshWorkspaceMenu()
    }
}
