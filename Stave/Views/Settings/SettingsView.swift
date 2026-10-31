import SwiftUI
import StaveCore

/// The Settings window. Only the ⌃1–9 toggle so far; the rest of Settings arrives with plan 5.
struct SettingsView: View {
    /// Nil until the app has opened its store.
    let shortcuts: WorkspaceShortcutsSetting?

    var body: some View {
        Form {
            if let shortcuts {
                Toggle(WorkspaceShortcutsSetting.title, isOn: Binding(get: { shortcuts.isEnabled }, set: { shortcuts.set($0) }))
                    .accessibilityLabel(WorkspaceShortcutsSetting.title)
                Text(WorkspaceShortcutsSetting.note)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                Text("Stave's data is not open.").foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .frame(width: 440)
        .fixedSize(horizontal: false, vertical: true)
    }
}
