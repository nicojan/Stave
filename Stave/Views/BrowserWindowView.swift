import SwiftUI
import StaveCore

/// One window's content: the sidebar beside the content area, with a draggable divider. Re-reads the model when any window writes to the store.
/// The sidebar width is the app-wide `SidebarWidthModel`, so every window shows the same width.
struct BrowserWindowView: View {
    let model: BrowserWindowModel
    let presenter: SidebarPresenter
    let revision: StoreRevision
    let sidebarWidth: SidebarWidthModel

    @State private var dragStartWidth: Double?
    @FocusState private var dividerFocused: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// The command bar's fade (decision 18); none under Reduce Motion.
    private static let fadeDuration = 0.12

    var body: some View {
        HStack(spacing: 0) {
            SidebarView(model: model, presenter: presenter, openCommandBar: { presenter.openCommandBar($0, for: model) })
                .frame(width: sidebarWidth.width)
            divider
            TabPlaceholderView(model: model)
        }
        .overlay { commandBarLayer }
        .animation(reduceMotion ? nil : .easeInOut(duration: Self.fadeDuration), value: presenter.commandBar != nil)
        .onChange(of: revision.value) { model.reload() }
    }

    @ViewBuilder
    private var commandBarLayer: some View {
        if let bar = presenter.commandBar {
            CommandBarView(bar: bar, activate: { presenter.activate(in: model) }, close: { presenter.closeCommandBar() })
                .transition(.opacity)
        }
    }

    /// A 1 pt line with a wider invisible handle. Drag it, or focus it and use the arrow keys, or use it as a slider with VoiceOver.
    private var divider: some View {
        Rectangle()
            .fill(dividerFocused ? Color.accentColor : Color(nsColor: .separatorColor))
            .frame(width: dividerFocused ? 3 : 1)
            .overlay {
                Color.clear
                    .frame(width: 9)
                    .contentShape(Rectangle())
                    .onHover { inside in if inside { NSCursor.resizeLeftRight.push() } else { NSCursor.pop() } }
                    .gesture(
                        DragGesture(minimumDistance: 1)
                            .onChanged { drag in
                                let start = dragStartWidth ?? sidebarWidth.width
                                dragStartWidth = start
                                sidebarWidth.set(start + drag.translation.width)
                            }
                            .onEnded { _ in dragStartWidth = nil }
                    )
            }
            .focusable()
            .focused($dividerFocused)
            .focusEffectDisabled()
            .onKeyPress(.leftArrow) { sidebarWidth.nudge(by: -SidebarWidthModel.step); return .handled }
            .onKeyPress(.rightArrow) { sidebarWidth.nudge(by: SidebarWidthModel.step); return .handled }
            .accessibilityRepresentation {
                Slider(
                    value: Binding(get: { sidebarWidth.width }, set: { sidebarWidth.set($0) }),
                    in: SidebarWidthModel.range, step: SidebarWidthModel.step
                ) { Text("Sidebar width") }
                .labelsHidden()
                .accessibilityLabel("Sidebar width")
                .accessibilityValue("\(Int(sidebarWidth.width)) points")
            }
    }
}
