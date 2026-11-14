import SwiftUI
import StaveCore

/// The Settings window: the default-browser button, where links from other apps open, and the ⌃1–9, compact-mode and search-engine
/// settings so far; the rest of Settings arrives with plan 5.
struct SettingsView: View {
    /// Nil until the app has opened its store.
    let shortcuts: WorkspaceShortcutsSetting?
    let compactMode: CompactModeSetting?
    let searchEngine: SearchEngineSetting?
    let externalLinks: ExternalLinkSetting?
    let isDefaultBrowser: Bool
    let makeDefaultBrowser: () -> Void
    let refreshDefaultBrowser: () -> Void

    var body: some View {
        Form {
            // Task 12 moves these two into a General pane.
            defaultBrowserRow
            if let externalLinks {
                Picker(ExternalOpenText.linkTargetTitle, selection: Binding(get: { externalLinks.target }, set: { externalLinks.set($0) })) {
                    ForEach(externalLinks.choices, id: \.target) { Text($0.title).tag($0.target) }
                }
                .accessibilityLabel(ExternalOpenText.linkTargetTitle)
            }
            if let shortcuts {
                Toggle(WorkspaceShortcutsSetting.title, isOn: Binding(get: { shortcuts.isEnabled }, set: { shortcuts.set($0) }))
                    .accessibilityLabel(WorkspaceShortcutsSetting.title)
                Text(WorkspaceShortcutsSetting.note)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let compactMode {
                Toggle(CompactModeSetting.title, isOn: Binding(get: { compactMode.isEnabled }, set: { compactMode.set($0) }))
                    .accessibilityLabel(CompactModeSetting.title)
                Text(CompactModeSetting.note)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let searchEngine {
                Picker(SearchEngineSetting.title, selection: Binding(get: { searchEngine.engine }, set: { if let engine = $0 { searchEngine.set(engine) } })) {
                    if searchEngine.engine == nil { Text(SearchEngineSetting.unchosenTitle).tag(SearchEngine?.none) }
                    ForEach(SearchEngine.allCases, id: \.self) { Text($0.displayName).tag(Optional($0)) }
                }
                .accessibilityLabel(SearchEngineSetting.title)
            }
            if shortcuts == nil && compactMode == nil && searchEngine == nil && externalLinks == nil {
                Text(PageChromeText.dataNotOpen).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .onAppear(perform: refreshDefaultBrowser)
        .frame(width: 440)
        .fixedSize(horizontal: false, vertical: true)
    }

    /// "Make Stave your default browser"; disabled, with the other title, when it already is. macOS asks the user to confirm.
    private var defaultBrowserRow: some View {
        let button = ExternalOpenText.defaultBrowserButton(isDefault: isDefaultBrowser)
        return Button(button.title, action: makeDefaultBrowser)
            .disabled(!button.isEnabled)
            .accessibilityLabel(button.title)
    }
}
