import AppKit
import SwiftUI
import StaveCore

/// Lays out the sidebar and the content. Normally the sidebar sits beside the content; in compact mode (the `compactMode` setting, read by
/// the window model) the content fills the window and the sidebar slides in over it, driven by `CompactReveal` through `CompactDriver`.
struct CompactContainer<Sidebar: View, Divider: View, Content: View>: View {
    let isCompact: Bool
    let sidebarWidth: SidebarWidthModel
    let presenter: SidebarPresenter
    @ViewBuilder let sidebar: () -> Sidebar
    @ViewBuilder let divider: () -> Divider
    @ViewBuilder let content: () -> Content

    @State private var driver = CompactDriver()
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// The reveal slide (decision 18); none under Reduce Motion.
    private static var slideDuration: Double { 0.15 }
    private static var shadowRadius: CGFloat { 12 }
    private static var dividerWidth: CGFloat { 1 }

    private var hold: CompactHold {
        CompactHold(
            commandBarOpen: presenter.commandBar != nil,
            menuOpen: driver.menuOpen,
            popoverOpen: presenter.showArchive,
            sheetOpen: driver.sheetOpen || presenter.workspaceEditor != nil || presenter.showNewProfile,
            dragInFlight: presenter.drag.payload != nil,
            keyboardFocusInside: driver.keyboardFocus,
            voiceOverRunning: driver.voiceOverRunning
        )
    }

    private var isHidden: Bool { isCompact && !driver.isRevealed }

    var body: some View {
        ZStack(alignment: .leading) {
            content()
                .padding(.leading, isCompact ? 0 : sidebarWidth.width + Self.dividerWidth)
            HStack(spacing: 0) {
                sidebar().frame(width: sidebarWidth.width)
                if !isCompact { divider().frame(width: Self.dividerWidth) }
            }
            .shadow(color: .black.opacity(isCompact && driver.isRevealed ? 0.3 : 0), radius: Self.shadowRadius, x: 2)
            .offset(x: isHidden ? -(sidebarWidth.width + Self.shadowRadius * 2) : 0)
        }
        .animation(reduceMotion ? nil : .easeOut(duration: Self.slideDuration), value: driver.isRevealed)
        .ignoresSafeArea() // the sidebar runs under the transparent title bar; the hosting view's bounds clip a hidden sidebar
        .background { CompactPointerView(driver: driver).ignoresSafeArea() }
        .onChange(of: isCompact, initial: true) { _, compact in
            driver.setSidebarWidth { [sidebarWidth] in sidebarWidth.width }
            driver.focusSidebar = { [presenter] in presenter.requestSidebarFocus() }
            driver.setEnabled(compact)
        }
        .onChange(of: presenter.commandBar == nil) { _, closed in if closed { driver.expectKeyboardFocus() } }
        .onChange(of: hold, initial: true) { _, new in driver.setHeld(new.isHeld) }
    }
}

/// Reports the pointer's position over the whole window through an `NSTrackingArea`, and hands the driver the window. It never takes a click.
private struct CompactPointerView: NSViewRepresentable {
    let driver: CompactDriver

    func makeNSView(context: Context) -> PointerView {
        let view = PointerView()
        view.driver = driver
        return view
    }

    func updateNSView(_ view: PointerView, context: Context) { view.driver = driver }

    static func dismantleNSView(_ view: PointerView, coordinator: ()) {
        MainActor.assumeIsolated { view.driver?.detach() }
    }

    final class PointerView: NSView {
        var driver: CompactDriver?
        private var area: NSTrackingArea?

        override func hitTest(_ point: NSPoint) -> NSView? { nil }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            MainActor.assumeIsolated {
                if let window { driver?.attach(to: window) } else { driver?.detach() }
            }
        }

        override func updateTrackingAreas() {
            super.updateTrackingAreas()
            if let area { removeTrackingArea(area) }
            let new = NSTrackingArea(
                rect: .zero, options: [.mouseMoved, .mouseEnteredAndExited, .activeInActiveApp, .inVisibleRect], owner: self, userInfo: nil
            )
            addTrackingArea(new)
            area = new
        }

        override func mouseMoved(with event: NSEvent) { report(event) }
        override func mouseEntered(with event: NSEvent) { report(event) }
        override func mouseExited(with event: NSEvent) { MainActor.assumeIsolated { driver?.pointerMoved(x: nil) } }

        private func report(_ event: NSEvent) {
            let x = convert(event.locationInWindow, from: nil).x
            MainActor.assumeIsolated { driver?.pointerMoved(x: x) }
        }
    }
}
