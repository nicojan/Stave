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

    func applicationDidFinishLaunching(_ notification: Notification) {
        do {
            let environment = try AppEnvironment.live(options: try DebugLaunchOptions.current)
            let windows = try environment.store.restoredWindows()
            self.environment = environment
            menuState.shortcuts = environment.workspaceShortcuts
            observeKeyWindow()
            for state in windows { try open(state, environment: environment) }
            launchCompleted = true
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
    func newTab() { keyController?.openCommandBar(.newTab) }

    /// ⌘L: the command bar on the key browser window, prefilled with the selected tab's address.
    func openLocation() { keyController?.openCommandBar(.currentTab) }

    /// ⌘W: closes the selected tab when the key window is a browser window (or a sheet on one); otherwise closes the key window, as in any app.
    func closeSelectedTab() {
        guard let controller = keyController else { NSApp.keyWindow?.performClose(nil); return }
        controller.model.closeSelectedTab()
    }

    /// ⇧⌘W: closes the browser window the key window belongs to; otherwise the key window itself.
    func closeWindow() {
        if let controller = keyController {
            controller.window.performClose(nil)
        } else {
            NSApp.keyWindow?.performClose(nil)
        }
    }

    /// ⌥⌘↑ / ⌥⌘↓: moves the key browser window's highlighted sidebar row one place up (-1) or down (+1). Nothing highlighted does nothing.
    func moveHighlightedRow(by delta: Int) { keyController?.model.moveHighlighted(by: delta) }

    // MARK: - Workspaces menu

    /// ⌃1–9 and the Workspaces menu items: the key browser window switches. With no browser window key (Settings, say) nothing happens.
    func switchWorkspace(to id: UUID) {
        keyController?.model.switchWorkspace(to: id)
    }

    /// Workspaces ▸ New Workspace…: opens the editor sheet on the key browser window.
    func newWorkspace() {
        keyController?.sidebarPresenter.workspaceEditor = .create
    }

    /// Rebuilds the menu's items from the key window's workspaces and the setting, and re-arms itself for the next change to either.
    /// The key window is not observable, so window notifications call this too; a generation number retires the older trackers.
    private func refreshWorkspaceMenu() {
        menuGeneration += 1
        let generation = menuGeneration
        let items: [WorkspaceSwitchItem] = withObservationTracking {
            guard let controller = keyController, let shortcuts = environment?.workspaceShortcuts else { return [] }
            return WorkspaceMenus.switchItems(
                workspaces: controller.model.workspaces, currentID: controller.model.snapshot.workspace.id,
                shortcutsEnabled: shortcuts.isEnabled
            )
        } onChange: { [weak self] in
            Task { @MainActor in
                guard let self, self.menuGeneration == generation else { return }
                self.refreshWorkspaceMenu()
            }
        }
        if menuState.workspaceItems != items { menuState.workspaceItems = items }
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
            onClose: { [weak self] closed in self?.windowClosed(closed) }
        )
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
