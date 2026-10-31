import AppKit
import StaveCore

/// Opens the store, restores one window per saved `WindowState`, and saves the set on quit. Menu commands call into it.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var environment: AppEnvironment?
    private var controllers: [BrowserWindowController] = []
    private var isTerminating = false

    func applicationDidFinishLaunching(_ notification: Notification) {
        do {
            let environment = try AppEnvironment.live()
            let windows = try environment.store.restoredWindows()
            self.environment = environment
            for state in windows { try open(state, environment: environment) }
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
        guard let environment else { return }
        for controller in controllers { controller.reportNow() }
        do {
            try environment.session.save()
        } catch {
            NSLog("Stave: could not save window state: \(error)")
        }
    }

    // MARK: - Menu commands

    /// ⌘N: a window on the front window's profile and workspace, with no tab selected.
    func newWindow() {
        guard let environment, let front = frontController else { return }
        let base = front.model.windowState
        let state = WindowState(
            profileID: base.profileID, workspaceID: base.workspaceID, selectedTabID: nil,
            frame: front.cascadedFrame, sortIndex: 0
        )
        do {
            try open(state, environment: environment)
            controllers.last?.show()
        } catch {
            NSLog("Stave: could not open a window: \(error)")
        }
    }

    /// ⌘W.
    func closeSelectedTab() {
        guard let model = frontController?.model, let id = model.selectedTabID else { return }
        model.close(id)
    }

    /// ⇧⌘W.
    func closeWindow() {
        frontController?.window.performClose(nil)
    }

    // MARK: - Windows

    private var frontController: BrowserWindowController? {
        controllers.first { $0.window === NSApp.keyWindow }
            ?? controllers.first { $0.window === NSApp.mainWindow }
            ?? controllers.first
    }

    private func open(_ state: WindowState, environment: AppEnvironment) throws {
        let controller = try BrowserWindowController(state: state, environment: environment) { [weak self] closed in
            self?.windowClosed(closed)
        }
        controllers = controllers + [controller]
        controller.show()
    }

    private func windowClosed(_ closed: BrowserWindowController) {
        // A window closing because the app is quitting stays in the saved set.
        if !isTerminating, let environment {
            environment.session.windowClosed(closed.model.windowID, isLast: controllers.count == 1)
        }
        controllers = controllers.filter { $0 !== closed }
    }

    // MARK: - Failure

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
