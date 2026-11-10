import AppKit
import Observation
import SwiftUI
import StaveCore

/// Owns one browser `NSWindow` and its `BrowserWindowModel`. Hands every state change to `WindowSession`, which saves once, 0.5 s after the last change.
@MainActor
final class BrowserWindowController: NSObject, NSWindowDelegate {
    private static let cascadeOffset: CGFloat = 24

    let model: BrowserWindowModel
    let window: NSWindow
    /// Lets the Workspaces menu ask this window's sidebar to open the workspace editor.
    let sidebarPresenter = SidebarPresenter()
    private let environment: AppEnvironment
    private let onClose: (BrowserWindowController) -> Void
    /// Set by the app delegate: the first-run sheet's Continue, and the import sheet's "Choose Another File…".
    var onCompleteFirstRun: (SearchEngine, Bool) -> Void = { _, _ in }
    var onChooseAnotherFile: (ArcImportSession) -> Void = { _ in }
    private var isClosed = false
    /// True from the start of entering full screen until leaving it has finished.
    private var inFullScreen = false

    init(state: WindowState, environment: AppEnvironment, onNewWindow: @escaping () -> Void, onImportFromArc: @escaping () -> Void, onClose: @escaping (BrowserWindowController) -> Void) throws {
        let model = try BrowserWindowModel(
            store: environment.store, revision: environment.revision, livePages: environment.livePages, state: state
        )
        self.model = model
        self.environment = environment
        self.onClose = onClose
        window = NSWindow(
            contentRect: NSRect(origin: .zero, size: WindowFrameRestore.defaultSize),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered, defer: false
        )
        super.init()
        sidebarPresenter.newWindow = onNewWindow
        sidebarPresenter.importFromArc = onImportFromArc
        configureWindow()
        place(savedFrame: state.frame)
        window.title = windowTitle
        reportNow()
        observeModel()
        observeCompact()
    }

    // MARK: - Window

    private func configureWindow() {
        window.isReleasedWhenClosed = false
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.minSize = WindowFrameRestore.minimumSize
        window.delegate = self
        let hosting = NSHostingView(rootView: BrowserWindowView(model: model, presenter: sidebarPresenter, revision: environment.revision, sidebarWidth: environment.sidebarWidth, shortcuts: environment.workspaceShortcuts, completeFirstRun: { [weak self] engine, importArc in self?.onCompleteFirstRun(engine, importArc) }, chooseAnotherFile: { [weak self] session in self?.onChooseAnotherFile(session) }))
        hosting.sizingOptions = [] // the window decides its size, not the SwiftUI content
        window.contentView = hosting
    }

    /// Applies the title bar for the compact-mode setting, then re-arms itself after each change.
    private func observeCompact() {
        applyTitleBar(underTitleBar: CompactLayout.contentUnderTitleBar(isCompact: model.isCompact))
        withObservationTracking {
            _ = model.isCompact
        } onChange: { [weak self] in
            Task { @MainActor in
                guard let self, !self.isClosed else { return }
                self.observeCompact()
            }
        }
    }

    /// Compact mode keeps a title bar of its own, so the traffic lights never sit over the page; otherwise the content runs under the
    /// transparent title bar (`CompactLayout`). A style change can resize the window to keep the content size, or leave the content view
    /// where it was, so the window keeps its frame and the content view is sized for the new style.
    /// In full screen, and while entering or leaving it, the style waits: full screen has no title bar either way, and
    /// `windowDidExitFullScreen` applies it.
    private func applyTitleBar(underTitleBar: Bool) {
        guard !inFullScreen, window.styleMask.contains(.fullSizeContentView) != underTitleBar else { return }
        let frame = window.frame
        if underTitleBar { window.styleMask.insert(.fullSizeContentView) } else { window.styleMask.remove(.fullSizeContentView) }
        window.setFrame(frame, display: false)
        window.contentView?.setFrameSize(window.contentRect(forFrameRect: window.frame).size)
        #if DEBUG
        if window.frame != frame || window.contentView?.frame.size != window.contentRect(forFrameRect: window.frame).size {
            NSLog("Stave: the title bar change left the window at \(window.frame) with content \(window.contentView?.frame ?? .zero)")
        }
        #endif
    }

    func windowWillEnterFullScreen(_ notification: Notification) { inFullScreen = true }
    func windowDidFailToEnterFullScreen(_ window: NSWindow) { leftFullScreen() }
    func windowWillExitFullScreen(_ notification: Notification) { inFullScreen = true }
    func windowDidExitFullScreen(_ notification: Notification) { leftFullScreen() }

    private func leftFullScreen() {
        inFullScreen = false
        applyTitleBar(underTitleBar: CompactLayout.contentUnderTitleBar(isCompact: model.isCompact))
    }

    /// The saved frame, restored by `WindowFrameRestore` (parse, minimum size, clamp to the screens); the default size, centred, when it is unusable.
    private func place(savedFrame: String) {
        if let rect = WindowFrameRestore.restore(savedFrame, visibleFrames: NSScreen.screens.map(\.visibleFrame)) {
            window.setFrame(rect, display: false)
        } else {
            // The frame, not the content size: in compact mode the content is shorter than the window by the title bar.
            window.setFrame(NSRect(origin: window.frame.origin, size: WindowFrameRestore.defaultSize), display: false)
            window.center()
        }
    }

    /// The frame string for a new window: this window's, nudged down and right so the two do not hide each other.
    var cascadedFrame: String {
        var rect = window.frame
        rect.origin.x += Self.cascadeOffset
        rect.origin.y -= Self.cascadeOffset
        return NSStringFromRect(rect)
    }

    private var windowTitle: String {
        WindowTitle.title(selectedTab: model.selectedTab, workspaceName: model.snapshot.workspace.name)
    }

    /// ⌘T and ⌘L (and the sidebar's address field and New Tab row) open the command bar in this window.
    func openCommandBar(_ mode: CommandBarMode) { sidebarPresenter.openCommandBar(mode, for: model) }

    func show() { window.makeKeyAndOrderFront(nil) }

    // MARK: - Reporting state

    /// Re-arms itself after each change: the model's state or title changed, so the session takes the new state and schedules its save.
    private func observeModel() {
        withObservationTracking {
            _ = model.windowState
            _ = windowTitle
        } onChange: { [weak self] in
            Task { @MainActor in
                guard let self, !self.isClosed else { return }
                self.window.title = self.windowTitle
                self.reportNow()
                self.observeModel()
            }
        }
    }

    /// Hands the window's current state to the session and schedules the save. Also used before quit and at close.
    /// The model's frame is assigned only when it differs: an equal assignment still notifies observers on Swift before 6.2, which would loop.
    func reportNow() {
        guard !isClosed else { return }
        syncFrame()
        environment.session.update(model.windowState)
        environment.session.scheduleSave()
    }

    private func syncFrame() {
        let current = NSStringFromRect(window.frame)
        if model.frame != current { model.frame = current }
    }

    // MARK: - NSWindowDelegate

    /// The bar belongs to the window it opened in; losing key (another window, Settings) closes it, so two windows never show a bar at once.
    func windowDidResignKey(_ notification: Notification) { sidebarPresenter.closeCommandBar() }

    func windowDidMove(_ notification: Notification) { frameChanged() }
    func windowDidResize(_ notification: Notification) { frameChanged() }

    private func frameChanged() {
        guard !isClosed else { return }
        syncFrame()
    }

    func windowWillClose(_ notification: Notification) {
        reportNow() // the last window stays in the saved set with its final frame and selection
        isClosed = true
        model.windowWillClose()
        onClose(self)
    }
}
