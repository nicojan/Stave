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
    /// The first responder is the hosting view (SwiftUI's own focus on a button), which says nothing about where: the previous answer stands
    /// until a mouse event or a key other than Tab, then it counts as outside.
    @ObservationIgnored private var focusUnknown = false
    /// The last hold the view reported, kept while disabled so enabling replays it (VoiceOver, an open sheet or menu across a toggle).
    @ObservationIgnored private var lastHold = false
    /// Set by the container; Tab belongs to the command bar while it is open.
    @ObservationIgnored var commandBarOpen = false
    /// Focus entering the sidebar reveals it only before this time: a key press (Tab) or the command bar closing arms it. Focus the system
    /// gives (a window showing, a click) never does.
    @ObservationIgnored private var keyboardIntentUntil: TimeInterval = 0
    @ObservationIgnored private var voiceOverObservation: NSKeyValueObservation?
    @ObservationIgnored private var observers: [NSObjectProtocol] = []
    @ObservationIgnored private var focusObservation: NSKeyValueObservation?
    @ObservationIgnored private var monitor: Any?

    private static let tabKeyCode: UInt16 = 48
    private static var now: TimeInterval { ProcessInfo.processInfo.systemUptime }

    // MARK: - Mode

    /// Compact mode on or off. Either way the sidebar starts hidden and no hold carries over.
    func setEnabled(_ on: Bool) {
        guard on != enabled else { return }
        enabled = on
        reveal = CompactReveal()
        keyboardFocus = false
        focusInside = false
        focusUnknown = false
        keyboardIntentUntil = 0
        if on {
            if voiceOverRunning { reveal.revealForKeyboard() }
            reveal.setHeld(lastHold, at: Self.now)
        }
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
        lastHold = held
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
    /// Hiding wins: focus in the sidebar or on the hosting view (which may be a sidebar button) is released.
    private func releaseSidebarFocus() {
        guard enabled, let window, isFocusInsideSidebar() != false else { return }
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
        focusInside = isFocusInsideSidebar() ?? false
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
        menuOpen = false
        sheetOpen = false
        window = nil
    }

    /// True when the driver took the event.
    private func observe(_ event: NSEvent) -> Bool {
        guard enabled, event.window === window else { return false }
        if isEnteringSidebar(event) {
            enterSidebarByKeyboard()
            return true
        }
        if focusUnknown, event.type != .keyDown || event.keyCode != Self.tabKeyCode {
            focusUnknown = false
            focusInside = false
            keyboardFocus = false
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
        guard event.type == .keyDown, event.keyCode == Self.tabKeyCode, !isRevealed, !menuOpen, !sheetOpen, !commandBarOpen,
              event.modifierFlags.intersection([.command, .option, .control]).isEmpty,
              !(window?.firstResponder is NSText)
        else { return false }
        return true
    }

    private func enterSidebarByKeyboard() {
        keyboardIntentUntil = Self.now + 1
        reveal.revealForKeyboard()
        syncReveal()
        focusSidebar() // the hold starts when the list's focus is observed (focusChanged), not before
    }

    /// Set by the container: asks the sidebar to give its list the keyboard focus.
    @ObservationIgnored var focusSidebar: () -> Void = {}

    /// Focus moving into the sidebar by key (Tab) or by the command bar closing reveals it and holds while it has focus. The hosting view
    /// is unknown (the previous answer stands); no responder counts as outside.
    private func focusChanged() {
        guard let inside = isFocusInsideSidebar() else {
            focusUnknown = true
            return
        }
        focusUnknown = false
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

    /// Whether the keyboard focus is in the sidebar: the first responder's centre lies within the sidebar's width. The sidebar and the content
    /// share one hosting view, so geometry tells them apart; a hidden sidebar sits left of the window, which still counts as inside. Nil when
    /// the first responder is the hosting view itself; false when there is no responder.
    private func isFocusInsideSidebar() -> Bool? {
        guard let window else { return false }
        if window.firstResponder === window.contentView { return nil }
        guard let view = window.firstResponder as? NSView, view.window === window else { return false }
        return view.convert(view.bounds, to: nil).midX < sidebarWidth()
    }
}
