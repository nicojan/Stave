import AppKit
import SwiftUI
import StaveCore

@main
struct StaveApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate

    // Windows are AppKit-managed (see AppDelegate); SwiftUI only needs a scene, which also hosts the Debug command.
    #if DEBUG
    var body: some Scene {
        Settings { EmptyView() }
            .commands {
                // Temporary (plan 1 Task 10): remove in plan 4
                CommandMenu("Debug") {
                    Button("Add sample tab") { delegate.addSampleTab() }
                }
            }
    }
    #else
    var body: some Scene {
        Settings { EmptyView() }
    }
    #endif
}

/// Opens the store, restores one `NSWindow` per saved `WindowState`, and saves them on quit.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {
    private struct OpenWindow {
        var state: WindowState
        let window: NSWindow
    }

    private var environment: AppEnvironment?
    private var openWindows: [OpenWindow] = []

    private static let defaultContentSize = NSSize(width: 320, height: 640)
    #if DEBUG
    // Temporary (plan 1 Task 10): remove in plan 4
    private static let sampleTabURL = "https://example.com/"
    private static let sampleTabLaunchArgument = "-StaveAddSampleTab"
    #endif

    func applicationDidFinishLaunching(_ notification: Notification) {
        let environment: AppEnvironment
        let windows: [WindowState]
        do {
            environment = try AppEnvironment.live()
            windows = try environment.store.restoredWindows()
        } catch {
            presentOpenFailure(error)
            return
        }
        self.environment = environment
        for state in windows { show(state, environment: environment) }
        NSApp.activate(ignoringOtherApps: true)

        #if DEBUG
        // Temporary (plan 1 Task 10): remove in plan 4
        if ProcessInfo.processInfo.arguments.contains(Self.sampleTabLaunchArgument) { addSampleTab() }
        #endif
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }

    func applicationWillTerminate(_ notification: Notification) {
        guard let environment else { return }
        let states = openWindows.enumerated().map { index, entry -> WindowState in
            var state = entry.state
            state.frame = NSStringFromRect(entry.window.frame)
            state.sortIndex = Double(index)
            return state
        }
        // Closing the last window quits the app; with nothing open there is nothing to overwrite the saved state with.
        guard !states.isEmpty else { return }
        do {
            try environment.store.saveWindows(states)
        } catch {
            NSLog("Stave: could not save window state: \(error)")
        }
    }

    func windowWillClose(_ notification: Notification) {
        guard let closing = notification.object as? NSWindow else { return }
        openWindows.removeAll { $0.window === closing }
    }

    // Temporary (plan 1 Task 10): remove in plan 4
    #if DEBUG
    func addSampleTab() {
        guard let environment else { return }
        let front = openWindows.first { $0.window === NSApp.keyWindow } ?? openWindows.first
        guard let workspaceID = front?.state.workspaceID else { return }
        do {
            _ = try environment.store.openTab(
                url: Self.sampleTabURL, title: "Sample tab", workspaceID: workspaceID,
                origin: .commandBar, containerID: nil, edge: .bottom
            )
            environment.noteStoreChanged()
        } catch {
            NSLog("Stave: could not add sample tab: \(error)")
        }
    }
    #endif

    // MARK: - Windows

    private func show(_ state: WindowState, environment: AppEnvironment) {
        let window = NSWindow(
            contentRect: NSRect(origin: .zero, size: Self.defaultContentSize),
            styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false
        )
        window.title = "Stave"
        window.isReleasedWhenClosed = false
        window.delegate = self
        window.contentView = NSHostingView(rootView: FoundationSidebarView(environment: environment, workspaceID: state.workspaceID))
        if let stored = Self.storedFrame(state.frame) {
            window.setFrame(stored, display: false)
        } else {
            window.center()
        }
        window.makeKeyAndOrderFront(nil)
        openWindows.append(OpenWindow(state: state, window: window))
    }

    /// The saved frame as a window frame rect (`NSWindow.frame`, title bar included, the same kind of rect `applicationWillTerminate` saves),
    /// or nil when it is empty, unparseable or has no area; the caller then keeps the default size and centres.
    private static func storedFrame(_ string: String) -> NSRect? {
        guard !string.isEmpty else { return nil }
        let rect = NSRectFromString(string)
        return rect.width > 0 && rect.height > 0 ? rect : nil
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
