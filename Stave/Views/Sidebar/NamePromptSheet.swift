import SwiftUI
import StaveCore

/// A small sheet that asks for one name (a folder, a profile). It replaces SwiftUI's `.alert` with a text field because an alert does not put
/// the keyboard in its field when Full Keyboard Access is on; here the field takes the focus itself, as in the workspace editor.
/// What the typed text means (trimming, the "New Folder" fallback, a cancelled blank) stays in StaveCore; this only collects it.
struct NamePromptSheet: View {
    let title: String
    let fieldLabel: String
    let confirmTitle: String
    let confirm: (String) -> Void
    let cancel: () -> Void

    @State private var text: String
    @FocusState private var fieldFocused: Bool

    init(title: String, fieldLabel: String, prefill: String = "", confirmTitle: String, confirm: @escaping (String) -> Void, cancel: @escaping () -> Void) {
        self.title = title; self.fieldLabel = fieldLabel; self.confirmTitle = confirmTitle; self.confirm = confirm; self.cancel = cancel
        _text = State(initialValue: prefill)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(title).font(.headline).accessibilityAddTraits(.isHeader)
            TextField(fieldLabel, text: $text)
                .focused($fieldFocused)
                .accessibilityLabel(fieldLabel)
                .onSubmit { confirm(text) }
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
        .onAppear { Task { fieldFocused = true } } // after the sheet's window has become key
    }
}
