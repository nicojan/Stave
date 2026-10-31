import Foundation

/// The compact-mode sidebar's show and hide rule (decision 17), with time passed in so nothing here reads a clock.
///
/// - The pointer within `edgeWidth` of the window's left edge reveals the sidebar.
/// - While revealed, the pointer within the sidebar's width cancels a pending hide; beyond it, a hide is scheduled `hideDelay` later
///   (and not rescheduled while one is pending).
/// - While held (command bar, menu, popover, sheet, drag, keyboard focus) nothing is scheduled and `tick` never hides; releasing a hold
///   while the pointer is outside schedules the hide.
public struct CompactReveal: Equatable, Sendable {
    public static let edgeWidth: Double = 8
    public static let hideDelay: TimeInterval = 0.4

    public private(set) var isRevealed = false
    /// When the sidebar will hide, nil when no hide is pending.
    public private(set) var hideAt: TimeInterval?
    private var held = false
    /// Where the pointer last was, relative to the sidebar. Unknown counts as outside, so a keyboard reveal hides once released.
    private var pointerOutside = true

    public init() {}

    public mutating func pointerMoved(x: Double, sidebarWidth: Double, at time: TimeInterval) {
        if x <= Self.edgeWidth {
            isRevealed = true
            pointerOutside = false
            hideAt = nil
        } else if x <= sidebarWidth {
            pointerOutside = false
            hideAt = nil
        } else {
            pointerOutside = true
            scheduleHideIfNeeded(at: time)
        }
    }

    /// The pointer left the window: it is outside the sidebar.
    public mutating func pointerLeft(at time: TimeInterval) {
        pointerOutside = true
        scheduleHideIfNeeded(at: time)
    }

    public mutating func setHeld(_ newHeld: Bool, at time: TimeInterval) {
        held = newHeld
        if newHeld {
            hideAt = nil
        } else if pointerOutside {
            scheduleHideIfNeeded(at: time)
        }
    }

    /// Shows the sidebar without the pointer (keyboard focus moved into it). It hides once the hold is released and the pointer is outside.
    public mutating func revealForKeyboard() {
        isRevealed = true
        hideAt = nil
    }

    public mutating func tick(at time: TimeInterval) {
        guard let hideAt, time >= hideAt, !held else { return }
        isRevealed = false
        self.hideAt = nil
    }

    private mutating func scheduleHideIfNeeded(at time: TimeInterval) {
        guard isRevealed, !held, hideAt == nil else { return }
        hideAt = time + Self.hideDelay
    }
}

/// Everything that keeps the compact sidebar open. The view only gathers the flags.
public struct CompactHold: Equatable, Sendable {
    public var commandBarOpen: Bool
    public var menuOpen: Bool
    public var popoverOpen: Bool
    /// A sheet or alert on the window.
    public var sheetOpen: Bool
    public var dragInFlight: Bool
    /// Keyboard focus is in the sidebar and no mouse action has taken over since.
    public var keyboardFocusInside: Bool

    public init(
        commandBarOpen: Bool = false, menuOpen: Bool = false, popoverOpen: Bool = false,
        sheetOpen: Bool = false, dragInFlight: Bool = false, keyboardFocusInside: Bool = false
    ) {
        self.commandBarOpen = commandBarOpen; self.menuOpen = menuOpen; self.popoverOpen = popoverOpen
        self.sheetOpen = sheetOpen; self.dragInFlight = dragInFlight; self.keyboardFocusInside = keyboardFocusInside
    }

    public var isHeld: Bool {
        commandBarOpen || menuOpen || popoverOpen || sheetOpen || dragInFlight || keyboardFocusInside
    }
}
