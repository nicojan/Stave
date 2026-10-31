import AppKit
import Observation
import StaveCore

/// Connects one window to `CompactReveal`: feeds it the pointer, the hold and the clock, and watches the AppKit signals the hold needs
/// (menus, sheets, keyboard focus). Holds no rule of its own; the rules are `CompactReveal` and `CompactHold` in StaveCore.
@MainActor @Observable
final class CompactDriver {
    /// What the view animates.
    private(set) var isRevealed = false
    private(set) var menuOpen = false
    private(set) var sheetOpen = false
    /// Keyboard focus moved into the sidebar and no mouse action has taken over since.
    private(set) var keyboardFocus = false

    @ObservationIgnored private var reveal = CompactReveal()
    @ObservationIgnored private var enabled = false
    @ObservationIgnored private var timer: Task<Void, Never>?
    @ObservationIgnored private var sidebarWidth: () -> Double = { 0 }
    @ObservationIgnored private weak var window: NSWindow?
    @ObservationIgnored private var focusInside = false
    /// A click in the sidebar gave it focus; that is the mouse's doing, so it does not reveal or hold. The next key press clears this.
    @ObservationIgnored private var focusFromMouse = false
    @ObservationIgnored private var observers: [NSObjectProtocol] = []
    @ObservationIgnored private var focusObservation: NSKeyValueObservation?
    @ObservationIgnored private var monitor: Any?

    private static var now: TimeInterval { ProcessInfo.processInfo.systemUptime }

    // MARK: - Mode

    /// Compact mode on or off. Either way the sidebar starts hidden and no hold carries over.
    func setEnabled(_ on: Bool) {
        guard on != enabled else { return }
        enabled = on
        reveal = CompactReveal()
        keyboardFocus = false
        syncReveal()
    }

    func setSidebarWidth(_ read: @escaping () -> Double) { sidebarWidth = read }

    // MARK: - Pointer and hold

    /// The pointer's x in the window, or nil when it left the window.
    func pointerMoved(x: Double?) {
        guard enabled else { return }
        if let x {
            // The mouse has taken over from the keyboard once it moves outside the sidebar.
            if x > sidebarWidth(), keyboardFocus { clearKeyboardFocus() }
            reveal.pointerMoved(x: x, sidebarWidth: sidebarWidth(), at: Self.now)
        } else {
            reveal.pointerLeft(at: Self.now)
        }
        syncReveal()
    }

    func setHeld(_ held: Bool) {
        guard enabled else { return }
        reveal.setHeld(held, at: Self.now)
        syncReveal()
    }

    private func clearKeyboardFocus() { keyboardFocus = false }

    private func tick() {
        reveal.tick(at: Self.now)
        syncReveal()
    }

    private func syncReveal() {
        if isRevealed != reveal.isRevealed { isRevealed = reveal.isRevealed }
        manageTimer()
    }

    /// The 0.1 s tick runs only while a hide is pending.
    private func manageTimer() {
        guard reveal.hideAt != nil else {
            timer?.cancel()
            timer = nil
            return
        }
        guard timer == nil else { return }
        timer = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(100))
                guard let self, !Task.isCancelled else { return }
                self.tick()
            }
        }
    }

    // MARK: - Window signals

    func attach(to window: NSWindow) {
        guard self.window !== window else { return }
        detach()
        self.window = window
        let center = NotificationCenter.default
        func watch(_ name: Notification.Name, object: AnyObject?, _ apply: @escaping @MainActor (CompactDriver) -> Void) {
            observers.append(center.addObserver(forName: name, object: object, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { if let self { apply(self) } }
            })
        }
        watch(NSMenu.didBeginTrackingNotification, object: nil) { $0.menuOpen = true }
        watch(NSMenu.didEndTrackingNotification, object: nil) { $0.menuOpen = false }
        watch(NSWindow.willBeginSheetNotification, object: window) { $0.sheetOpen = true }
        watch(NSWindow.didEndSheetNotification, object: window) { driver in driver.sheetOpen = driver.window?.attachedSheet != nil }
        focusObservation = window.observe(\.firstResponder, options: []) { [weak self] _, _ in
            Task { @MainActor in self?.focusChanged() }
        }
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown, .keyDown]) { [weak self] event in
            MainActor.assumeIsolated { self?.observe(event) }
            return event
        }
        focusInside = isFocusInsideSidebar() ?? false
    }

    func detach() {
        observers.forEach { NotificationCenter.default.removeObserver($0) }
        observers = []
        focusObservation?.invalidate()
        focusObservation = nil
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        timer?.cancel()
        timer = nil
        window = nil
    }

    private func observe(_ event: NSEvent) {
        guard enabled, event.window === window else { return }
        switch event.type {
        case .keyDown:
            focusFromMouse = false
        case .leftMouseDown, .rightMouseDown:
            if event.locationInWindow.x <= sidebarWidth() {
                focusFromMouse = true
            } else if keyboardFocus {
                // A click on the content: the keyboard hold is over, the sidebar hides as soon as the pointer is outside.
                clearKeyboardFocus()
            }
        default: break
        }
    }

    /// Focus moving into the sidebar (Tab, or the command bar closing back to the list) reveals it and holds while it has focus.
    private func focusChanged() {
        // Nil: SwiftUI's own focus (a button) sits on the hosting view, which says nothing about where; the last answer stands.
        guard let inside = isFocusInsideSidebar() else { return }
        defer { focusInside = inside }
        guard enabled, inside != focusInside else { return }
        if inside {
            guard !focusFromMouse else { return }
            reveal.revealForKeyboard()
            keyboardFocus = true
            syncReveal()
        } else {
            keyboardFocus = false
        }
    }

    /// The first responder is a view whose centre lies within the sidebar's width. The sidebar and the content share one hosting view, so
    /// geometry is what tells them apart; a hidden sidebar sits left of the window, which still counts as inside.
    private func isFocusInsideSidebar() -> Bool? {
        guard let window else { return false }
        guard let view = window.firstResponder as? NSView, view.window === window else { return false }
        if view === window.contentView { return nil }
        return view.convert(view.bounds, to: nil).midX <= sidebarWidth()
    }
}
