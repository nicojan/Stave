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
    /// VoiceOver is running; compact mode then keeps the sidebar revealed.
    private(set) var voiceOverRunning = false

    @ObservationIgnored private var reveal = CompactReveal()
    @ObservationIgnored private var enabled = false
    @ObservationIgnored private var timer: Task<Void, Never>?
    @ObservationIgnored private var sidebarWidth: () -> Double = { 0 }
    @ObservationIgnored private weak var window: NSWindow?
    @ObservationIgnored private var focusInside = false
    /// Focus entering the sidebar reveals it only before this time: a key press (Tab) or the command bar closing arms it. Focus the system
    /// gives (a window showing, a click) never does.
    @ObservationIgnored private var keyboardIntentUntil: TimeInterval = 0
    @ObservationIgnored private var voiceOverObservation: NSKeyValueObservation?
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
        focusInside = false
        keyboardIntentUntil = 0
        if on, voiceOverRunning { reveal.revealForKeyboard() }
        syncReveal()
    }

    /// The command bar closed: focus is about to return to the sidebar list, which counts as the keyboard's doing.
    func expectKeyboardFocus() { keyboardIntentUntil = Self.now + 1 }

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
        if isRevealed != reveal.isRevealed {
            let hid = isRevealed
            isRevealed = reveal.isRevealed
            if hid { releaseSidebarFocus() }
        }
        manageTimer()
    }

    /// A hidden sidebar must not receive keys (arrows would switch tabs, Delete close them, out of sight): the content takes the focus.
    private func releaseSidebarFocus() {
        guard let window, isFocusInsideSidebar() else { return }
        window.makeFirstResponder(nil) // also clears SwiftUI's own focus on a button, which lives on the hosting view
        focusInside = false
        keyboardFocus = false
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
            MainActor.assumeIsolated { self?.observe(event) ?? false } ? nil : event
        }
        focusInside = isFocusInsideSidebar()
        voiceOverObservation = NSWorkspace.shared.observe(\.isVoiceOverEnabled, options: [.initial, .new]) { [weak self] _, _ in
            Task { @MainActor in self?.voiceOverChanged() }
        }
    }

    private func voiceOverChanged() {
        let running = NSWorkspace.shared.isVoiceOverEnabled
        guard running != voiceOverRunning else { return }
        voiceOverRunning = running
        if enabled, running {
            reveal.revealForKeyboard()
            syncReveal()
        }
    }

    func detach() {
        observers.forEach { NotificationCenter.default.removeObserver($0) }
        observers = []
        focusObservation?.invalidate()
        focusObservation = nil
        voiceOverObservation?.invalidate()
        voiceOverObservation = nil
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        timer?.cancel()
        timer = nil
        window = nil
    }

    /// True when the driver took the event.
    private func observe(_ event: NSEvent) -> Bool {
        guard enabled, event.window === window else { return false }
        if isEnteringSidebar(event) {
            enterSidebarByKeyboard()
            return true
        }
        switch event.type {
        case .keyDown:
            keyboardIntentUntil = Self.now + 0.5
        case .leftMouseDown, .rightMouseDown:
            keyboardIntentUntil = 0
            if event.locationInWindow.x > sidebarWidth(), keyboardFocus {
                // A click on the content: the keyboard hold is over, the sidebar hides as soon as the pointer is outside.
                clearKeyboardFocus()
            }
        default: break
        }
        return false
    }

    /// Tab with a hidden sidebar and focus in the content: where Tab would land cannot be seen from AppKit (SwiftUI focus sits on the hosting
    /// view), so Tab itself is the way in. It reveals the sidebar, holds it, and asks the list for focus.
    private func isEnteringSidebar(_ event: NSEvent) -> Bool {
        guard event.type == .keyDown, event.keyCode == 48, !isRevealed, !menuOpen, !sheetOpen,
              event.modifierFlags.intersection([.command, .option, .control]).isEmpty,
              !(window?.firstResponder is NSText)
        else { return false }
        return true
    }

    private func enterSidebarByKeyboard() {
        keyboardIntentUntil = Self.now + 1
        reveal.revealForKeyboard()
        keyboardFocus = true
        syncReveal()
        focusSidebar()
    }

    /// Set by the container: asks the sidebar to give its list the keyboard focus.
    @ObservationIgnored var focusSidebar: () -> Void = {}

    /// Focus moving into the sidebar by key (Tab) or by the command bar closing reveals it and holds while it has focus. Any other
    /// responder, including the hosting view and none, counts as outside.
    private func focusChanged() {
        let inside = isFocusInsideSidebar()
        defer { focusInside = inside }
        guard enabled, inside != focusInside else { return }
        if inside {
            guard Self.now <= keyboardIntentUntil else { return }
            reveal.revealForKeyboard()
            keyboardFocus = true
            syncReveal()
        } else {
            keyboardFocus = false
        }
    }

    /// Whether the keyboard focus is in the sidebar: the first responder, or for SwiftUI's own focus (a button, which leaves the hosting view as
    /// responder) the accessibility-focused element, is centred within the sidebar's width. The sidebar and the content share one hosting view,
    /// so geometry is what tells them apart; a hidden sidebar sits left of the window, which still counts as inside. Anything unknown (no
    /// responder, no focused element) counts as outside.
    private func isFocusInsideSidebar() -> Bool {
        guard let window else { return false }
        let midX: Double
        if let view = window.firstResponder as? NSView, view.window === window, view !== window.contentView {
            midX = view.convert(view.bounds, to: nil).midX
        } else if window.firstResponder === window.contentView,
                  let element = NSApp.accessibilityApplicationFocusedUIElement() as? NSAccessibilityElementProtocol,
                  case let frame = element.accessibilityFrame(), !frame.isEmpty {
            midX = window.convertFromScreen(frame).midX
        } else {
            return false
        }
        return midX < sidebarWidth()
    }
}
