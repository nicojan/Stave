import SwiftUI
import StaveCore

/// One window's content: the sidebar beside the content area, with a draggable divider. Re-reads the model when any window writes to the store.
struct BrowserWindowView: View {
    let model: BrowserWindowModel
    let revision: StoreRevision
    let store: OrganizationStore

    private static let minSidebarWidth: CGFloat = 200
    private static let maxSidebarWidth: CGFloat = 400
    private static let keyboardStep: CGFloat = 10
    private static let widthSaveDelay: Duration = .milliseconds(500)

    @State private var sidebarWidth: CGFloat = CGFloat(SettingKeys.sidebarWidth.defaultValue)
    @State private var dragStartWidth: CGFloat?
    @State private var savedWidth: Double?
    @State private var saveTask: Task<Void, Never>?
    @FocusState private var dividerFocused: Bool

    var body: some View {
        HStack(spacing: 0) {
            SidebarView(model: model)
                .frame(width: sidebarWidth)
            divider
            TabPlaceholderView(model: model)
        }
        .onAppear(perform: loadWidth)
        .onChange(of: revision.value) { model.reload() }
        .onChange(of: sidebarWidth) { _, width in scheduleSave(width) }
    }

    /// A 1 pt line with a wider invisible handle. Drag it, or focus it and use the arrow keys, or adjust it with VoiceOver.
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
                                let start = dragStartWidth ?? sidebarWidth
                                dragStartWidth = start
                                sidebarWidth = clamped(start + drag.translation.width)
                            }
                            .onEnded { _ in dragStartWidth = nil }
                    )
            }
            .focusable()
            .focused($dividerFocused)
            .focusEffectDisabled()
            .onKeyPress(.leftArrow) { nudge(-Self.keyboardStep); return .handled }
            .onKeyPress(.rightArrow) { nudge(Self.keyboardStep); return .handled }
            .accessibilityElement()
            .accessibilityLabel("Sidebar width")
            .accessibilityValue("\(Int(sidebarWidth)) points")
            .accessibilityAdjustableAction { direction in
                switch direction {
                case .increment: nudge(Self.keyboardStep)
                case .decrement: nudge(-Self.keyboardStep)
                @unknown default: break
                }
            }
    }

    private func clamped(_ width: CGFloat) -> CGFloat { min(max(width, Self.minSidebarWidth), Self.maxSidebarWidth) }

    private func nudge(_ delta: CGFloat) { sidebarWidth = clamped(sidebarWidth + delta) }

    private func loadWidth() {
        guard savedWidth == nil else { return }
        let stored = (try? store.setting(SettingKeys.sidebarWidth)) ?? SettingKeys.sidebarWidth.defaultValue
        savedWidth = stored
        sidebarWidth = clamped(CGFloat(stored))
    }

    /// The app has one sidebar width. Writes it 0.5 s after the last change, and only when it differs from what is stored.
    private func scheduleSave(_ width: CGFloat) {
        let value = Double(width)
        guard let savedWidth, abs(value - savedWidth) >= 1 else { return }
        saveTask?.cancel()
        saveTask = Task {
            try? await Task.sleep(for: Self.widthSaveDelay)
            guard !Task.isCancelled else { return }
            do {
                try store.setSetting(SettingKeys.sidebarWidth, value)
                self.savedWidth = value
            } catch {
                NSLog("Stave: could not save the sidebar width: \(error)")
            }
        }
    }
}
