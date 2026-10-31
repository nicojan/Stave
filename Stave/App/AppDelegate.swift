import AppKit
import Observation
import StaveCore

/// Opens the store, restores one window per saved `WindowState`, and saves the set as it changes and on quit. Menu commands call into it.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var environment: AppEnvironment?
    private var controllers: [BrowserWindowController] = []
    private var isTerminating = false
    /// True once every saved window is open. A launch that fails part-way must not save its partial set over the user's windows.
    private var launchCompleted = false
    /// What the Workspaces menu and Settings show; refreshed when the key window, its workspaces or the ⌃1–9 setting change.
    let menuState = AppMenuState()
    private var menuGeneration = 0
    private var keyObservers: [NSObjectProtocol] = []
    private var importCoordinator: ImportCoordinator?

    func applicationDidFinishLaunching(_ notification: Notification) {
        do {
            let environment = try AppEnvironment.live(options: try DebugLaunchOptions.current)
            let windows = try environment.store.restoredWindows()
            self.environment = environment
            menuState.shortcuts = environment.workspaceShortcuts
            menuState.compactMode = environment.compactMode
            menuState.searchEngine = environment.searchEngine
            importCoordinator = ImportCoordinator(environment: environment, controllers: { [weak self] in self?.controllers ?? [] })
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

    /// ⌘T: the command bar on the key browser window, for a new tab.
    func newTab() { guard let controller = keyController, allowed(.newTab, on: controller) else { return }; controller.openCommandBar(.newTab) }

    /// ⌘L: the command bar on the key browser window, prefilled with the selected tab's address.
    func openLocation() { guard let controller = keyController, allowed(.openLocation, on: controller) else { return }; controller.openCommandBar(.currentTab) }

    /// ⌘W: closes the selected tab when the key window is a browser window (or a sheet on one); otherwise closes the key window, as in any app.
    func closeSelectedTab() {
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

    /// File ▸ Import from Arc…: on the key browser window (else the front one). One import at a time; an open one is brought forward.
    func importFromArc() {
        guard launchCompleted, let controller = frontController else { return }
        importCoordinator?.open(on: controller, windowIsBusy: isBusy(controller) && !MenuCommandGate.allowedWhileSheetUp(.importFromArc))
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
            hasPendingSheet: presenter.sheet != nil || presenter.workspaceEditor != nil || presenter.showNewProfile
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
        let (items, compact): ([WorkspaceSwitchItem], Bool) = withObservationTracking {
            // With no browser window key (Settings in front) the checkmark follows the setting itself.
            guard let controller = keyController, let shortcuts = environment?.workspaceShortcuts else {
                return ([], environment?.compactMode.isEnabled ?? false)
            }
            let items = WorkspaceMenus.switchItems(
                workspaces: controller.model.workspaces, currentID: controller.model.snapshot.workspace.id,
                shortcutsEnabled: shortcuts.isEnabled
            )
            return (items, controller.model.isCompact)
        } onChange: { [weak self] in
            Task { @MainActor in
                guard let self, self.menuGeneration == generation else { return }
                self.refreshWorkspaceMenu()
            }
        }
        if menuState.workspaceItems != items { menuState.workspaceItems = items }
        if menuState.isCompact != compact { menuState.isCompact = compact }
    }

    private func observeKeyWindow() {
        let center = NotificationCenter.default
        keyObservers = [NSWindow.didBecomeKeyNotification, NSWindow.didResignKeyNotification].map { name in
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

    private func open(_ state: WindowState, environment: AppEnvironment) throws {
        // A window kept because it was the last to close has no controller; the new window replaces it rather than joining it.
        environment.session.discardStates(exceptLive: Set(controllers.map { $0.model.windowID }))
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
        controllers = controllers + [controller]
        controller.show()
        refreshWorkspaceMenu()
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
