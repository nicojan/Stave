import AppKit
import SwiftUI
import StaveCore

/// The find bar above a page (decision 11): the field, "Not found" when a search finds nothing, previous and next, and Done. Return finds
/// the next match, ⇧Return the previous, Escape closes. The strings and rules are StaveCore's (`FindText`, `FindState`); this holds focus.
struct FindBar: View {
    let find: PageFind
    let tabID: UUID

    @FocusState private var fieldFocused: Bool

    private var state: FindState { find.state(for: tabID) }

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass").foregroundStyle(.secondary).accessibilityHidden(true)
            TextField(FindText.fieldPlaceholder, text: Binding(get: { state.query }, set: { find.setQuery($0, in: tabID) }))
                .textFieldStyle(.roundedBorder)
                .frame(maxWidth: 320)
                .focused($fieldFocused)
                .accessibilityLabel(FindText.fieldLabel)
                // ⇧Return is read from the key press itself: `NSEvent.modifierFlags` inside `onSubmit` read Shift as up (by-hand check).
                .onKeyPress(.return, phases: .down) { press in
                    guard press.modifiers.contains(.shift) else { return .ignored }
                    find.findNext(in: tabID, backwards: true)
                    return .handled
                }
                .onSubmit { find.findNext(in: tabID, backwards: false) }
                .onExitCommand { find.hide(in: tabID) }
            if let status = state.statusText {
                Text(status)
                    .foregroundStyle(.secondary)
                    .accessibilityLabel(status)
            }
            Spacer(minLength: 8)
            Button { find.findNext(in: tabID, backwards: true) } label: { Image(systemName: "chevron.left") }
                .disabled(!state.canFindAgain)
                .accessibilityLabel(FindText.previousButton)
                .help(FindText.previousButton)
            Button { find.findNext(in: tabID, backwards: false) } label: { Image(systemName: "chevron.right") }
                .disabled(!state.canFindAgain)
                .accessibilityLabel(FindText.nextButton)
                .help(FindText.nextButton)
            Button(FindText.doneButton) { find.hide(in: tabID) }
                .accessibilityLabel(FindText.doneButton)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(.bar)
        .overlay(alignment: .bottom) { Divider() }
        .onAppear { focusIfAsked() } // ⌘F made the bar appear
        .onChange(of: find.fieldFocus) { focusIfAsked() } // ⌘F with the bar already up
        .onChange(of: state.statusText) { _, status in
            // VoiceOver hears "Not found" without leaving the field.
            if let status { AccessibilityNotification.Announcement(status).post() }
        }
    }

    /// Clear, then set on the next turn, after the bar is in the window: a stale-true flag would give nothing the focus.
    private func focusIfAsked() {
        guard find.takeFocus(for: tabID) else { return }
        fieldFocused = false
        Task { @MainActor in fieldFocused = true }
    }
}
