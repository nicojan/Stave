import SwiftUI
import StaveCore

/// A small sheet that asks for one name (a folder, a profile). It replaces SwiftUI's `.alert` with a text field because an alert does not put
/// the keyboard in its field when Full Keyboard Access is on; here the field takes the focus itself, as in the workspace editor.
/// Return is the default button's job only (no `.onSubmit`), so a Return confirms exactly once.
/// What the typed text means (trimming, the "New Folder" fallback, a cancelled blank) stays in StaveCore; this only collects it.
struct NamePromptSheet: View {
    let title: String
    let fieldLabel: String
    let placeholder: String?
    let confirmTitle: String
    let confirm: (String) -> Void
    let cancel: () -> Void

    @State private var text: String
    @FocusState private var fieldFocused: Bool
    /// Set once the field has held focus; after that, becoming key again must not pull focus back from a button the user moved to (R2-L1).
    @State private var hasHadFocus = false
    @Environment(\.controlActiveState) private var activeState

    init(title: String, fieldLabel: String, prefill: String = "", placeholder: String? = nil, confirmTitle: String, confirm: @escaping (String) -> Void, cancel: @escaping () -> Void) {
        self.title = title; self.fieldLabel = fieldLabel; self.placeholder = placeholder; self.confirmTitle = confirmTitle; self.confirm = confirm; self.cancel = cancel
        _text = State(initialValue: prefill)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(title).font(.headline).accessibilityAddTraits(.isHeader)
            TextField(placeholder ?? fieldLabel, text: $text)
                .focused($fieldFocused)
                .accessibilityLabel(fieldLabel)
            HStack {
                Spacer()
                Button(WorkspaceEditorRules.cancelButton, role: .cancel, action: cancel)
                    .keyboardShortcut(.cancelAction)
                Button(confirmTitle) { confirm(text) }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 300)
        .defaultFocus($fieldFocused, true)
        // The sheet can appear while the window that opened it (the command bar's Return) still holds the keyboard, and a focus request made
        // before the sheet's window is key is dropped (R1-BH4). So the field is asked for focus when the view appears, a tick later, and
        // again whenever the sheet's window becomes key, until the field has held focus once.
        .onAppear {
            fieldFocused = true
            Task { fieldFocused = true }
        }
        .onChange(of: activeState) { _, state in
            if state == .key, !hasHadFocus { fieldFocused = true }
        }
        .onChange(of: fieldFocused) { _, focused in
            // Counts only focus held while the sheet's window is key: a request made before then can be reported here and still be dropped.
            if focused, activeState == .key { hasHadFocus = true }
        }
    }
}
