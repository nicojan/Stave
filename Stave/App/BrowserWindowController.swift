import AppKit
import Observation
import SwiftUI
import StaveCore

/// Owns one browser `NSWindow` and its `BrowserWindowModel`. Reports the window's state to `WindowSession` 0.5 s after the last change.
@MainActor
final class BrowserWindowController: NSObject, NSWindowDelegate {
    static let defaultSize = NSSize(width: 1200, height: 800)
    static let minimumSize = NSSize(width: 800, height: 500)
    private static let reportDelay: Duration = .milliseconds(500)
    private static let cascadeOffset: CGFloat = 24

    let model: BrowserWindowModel
    let window: NSWindow
    private let environment: AppEnvironment
    private let onClose: (BrowserWindowController) -> Void
    private var reportTask: Task<Void, Never>?
    private var isClosed = false

    init(state: WindowState, environment: AppEnvironment, onClose: @escaping (BrowserWindowController) -> Void) throws {
        let model = try BrowserWindowModel(
            store: environment.store, revision: environment.revision, livePages: environment.livePages, state: state
        )
        self.model = model
        self.environment = environment
        self.onClose = onClose
        window = NSWindow(
            contentRect: NSRect(origin: .zero, size: Self.defaultSize),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered, defer: false
        )
        super.init()
        configureWindow()
        place(savedFrame: state.frame)
        window.title = windowTitle
        reportNow()
        observeModel()
    }

    // MARK: - Window

    private func configureWindow() {
        window.isReleasedWhenClosed = false
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.minSize = Self.minimumSize
        window.delegate = self
        let hosting = NSHostingView(rootView: BrowserWindowView(model: model, revision: environment.revision, store: environment.store))
        hosting.sizingOptions = [] // the window decides its size, not the SwiftUI content
        window.contentView = hosting
    }

    /// A saved frame that is empty, unparseable, zero-area, NaN or infinite falls back to the default size, centred.
    /// Anything else goes through `WindowFrameClamp` with every screen's visible frame.
    private func place(savedFrame: String) {
        if let rect = Self.usableFrame(savedFrame) {
            let clamped = WindowFrameClamp.clamp(rect, visibleFrames: NSScreen.screens.map(\.visibleFrame))
            window.setFrame(clamped, display: false)
        } else {
            window.setContentSize(Self.defaultSize)
            window.center()
        }
    }

    static func usableFrame(_ string: String) -> NSRect? {
        guard !string.isEmpty else { return nil }
        let rect = NSRectFromString(string)
        let numbers = [rect.origin.x, rect.origin.y, rect.width, rect.height]
        guard numbers.allSatisfy(\.isFinite), rect.width > 0, rect.height > 0 else { return nil }
        return rect
    }

    /// The frame string for a new window: this window's, nudged down and right so the two do not hide each other.
    var cascadedFrame: String {
        var rect = window.frame
        rect.origin.x += Self.cascadeOffset
        rect.origin.y -= Self.cascadeOffset
        return NSStringFromRect(rect)
    }

    /// The selected tab's title, or the workspace name: used by the Window menu and VoiceOver.
    private var windowTitle: String {
        model.selectedTab.map(DisplayText.title(for:)) ?? model.snapshot.workspace.name
    }

    func show() { window.makeKeyAndOrderFront(nil) }

    // MARK: - Reporting state

    /// Re-arms itself after each change: the model's state or title changed, so the report is due in 0.5 s.
    private func observeModel() {
        withObservationTracking {
            _ = model.windowState
            _ = windowTitle
        } onChange: { [weak self] in
            Task { @MainActor in
                guard let self, !self.isClosed else { return }
                self.window.title = self.windowTitle
                self.scheduleReport()
                self.observeModel()
            }
        }
    }

    private func scheduleReport() {
        reportTask?.cancel()
        reportTask = Task {
            try? await Task.sleep(for: Self.reportDelay)
            guard !Task.isCancelled else { return }
            reportNow()
        }
    }

    /// Hands the window's current state to the session at once. Also used before quit, so no change is left waiting on the delay.
    func reportNow() {
        guard !isClosed else { return }
        reportTask?.cancel()
        model.frame = NSStringFromRect(window.frame)
        environment.session.update(model.windowState)
    }

    // MARK: - NSWindowDelegate

    func windowDidMove(_ notification: Notification) { frameChanged() }
    func windowDidResize(_ notification: Notification) { frameChanged() }

    private func frameChanged() {
        guard !isClosed else { return }
        model.frame = NSStringFromRect(window.frame)
    }

    func windowWillClose(_ notification: Notification) {
        reportNow() // the last window stays in the saved set with its final frame and selection
        isClosed = true
        reportTask?.cancel()
        model.windowWillClose()
        onClose(self)
    }
}
