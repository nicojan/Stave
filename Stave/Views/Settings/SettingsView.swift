import AppKit
import SwiftUI
import StaveCore

/// The Settings window: six panes (decision 17). General and Tabs hold the settings from earlier plans; Profiles, Containers, Websites and
/// Advanced are Task 12's. Every control has a label from `SettingsCopy` (or the setting that owns it) and works with the keyboard alone.
struct SettingsView: View {
    let state: AppMenuState
    let makeDefaultBrowser: () -> Void
    let refreshDefaultBrowser: () -> Void
    let showBackups: () -> Void
    /// The front browser window's profile, for Websites' picker.
    let frontProfileID: () -> UUID?
    @State private var pane: SettingsPane = .general
    /// The front browser window's profile, read again whenever a window becomes key so a reused Settings window never shows an old one (R2-L3).
    @State private var frontProfile: UUID?

    var body: some View {
        TabView(selection: $pane) {
            ForEach(SettingsPane.allCases) { pane in
                paneContent(pane)
                    .tabItem { Label(pane.title, systemImage: pane.symbol) }
                    .tag(pane)
            }
        }
        .frame(width: 520)
        .onAppear {
            refreshDefaultBrowser()
            frontProfile = frontProfileID()
        }
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didBecomeKeyNotification)) { _ in frontProfile = frontProfileID() }
        // A pane's failure is cleared when the user leaves that pane (BH5).
        .onChange(of: pane) { old, _ in state.settings?.clearMessage(for: old) }
    }

    @ViewBuilder
    private func paneContent(_ pane: SettingsPane) -> some View {
        switch pane {
        case .general:
            GeneralPane(state: state, makeDefaultBrowser: makeDefaultBrowser)
        case .tabs:
            TabsPane(shortcuts: state.shortcuts, compactMode: state.compactMode, autoArchive: state.autoArchive)
        case .profiles:
            if let settings = state.settings { ProfilesPane(model: settings).frame(minHeight: 260) } else { notOpen }
        case .containers:
            if let settings = state.settings { ContainersPane(model: settings).frame(minHeight: 320) } else { notOpen }
        case .websites:
            if let settings = state.settings { WebsitesPane(model: settings, frontProfileID: frontProfile).frame(minHeight: 320) } else { notOpen }
        case .advanced:
            AdvancedPane(backups: state.backups, showBackups: showBackups)
        }
    }

    private var notOpen: some View {
        Text(PageChromeText.dataNotOpen).foregroundStyle(.secondary).padding()
    }
}

/// General: default browser, where links from other apps open, search engine, where new tabs open and "Remove history items".
struct GeneralPane: View {
    let state: AppMenuState
    let makeDefaultBrowser: () -> Void

    var body: some View {
        Form {
            defaultBrowserRow
            if let externalLinks = state.externalLinks {
                Picker(ExternalOpenText.linkTargetTitle, selection: Binding(get: { externalLinks.target }, set: { externalLinks.set($0) })) {
                    ForEach(externalLinks.choices, id: \.target) { Text($0.title).tag($0.target) }
                }
                .accessibilityLabel(ExternalOpenText.linkTargetTitle)
            }
            if let searchEngine = state.searchEngine {
                Picker(SearchEngineSetting.title, selection: Binding(get: { searchEngine.engine }, set: { if let engine = $0 { searchEngine.set(engine) } })) {
                    if searchEngine.engine == nil { Text(SearchEngineSetting.unchosenTitle).tag(SearchEngine?.none) }
                    ForEach(SearchEngine.allCases, id: \.self) { Text($0.displayName).tag(Optional($0)) }
                }
                .accessibilityLabel(SearchEngineSetting.title)
            }
            if let settings = state.settings {
                Picker(SettingsCopy.newTabEdgeTitle, selection: Binding(get: { settings.newTabEdge }, set: { settings.setNewTabEdge($0) })) {
                    ForEach([NewTabEdge.top, .bottom], id: \.self) { Text(SettingsCopy.newTabEdgeChoice($0)).tag($0) }
                }
                .accessibilityLabel(SettingsCopy.newTabEdgeTitle)
            }
            if let historyRetention = state.historyRetention {
                Picker(HistoryRetention.settingTitle, selection: Binding(get: { historyRetention.retention }, set: { historyRetention.set($0) })) {
                    ForEach(HistoryRetention.allCases, id: \.self) { Text($0.title).tag($0) }
                }
                .accessibilityLabel(HistoryRetention.settingTitle)
            }
            if let downloadRetention = state.downloadRetention {
                Picker(DownloadListRetention.settingTitle, selection: Binding(get: { downloadRetention.retention }, set: { downloadRetention.set($0) })) {
                    ForEach(DownloadListRetention.allCases, id: \.self) { Text($0.title).tag($0) }
                }
                .accessibilityLabel(DownloadListRetention.settingTitle)
            }
            if state.externalLinks == nil && state.searchEngine == nil && state.historyRetention == nil && state.downloadRetention == nil {
                Text(PageChromeText.dataNotOpen).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .fixedSize(horizontal: false, vertical: true)
    }

    /// "Make Stave your default browser"; disabled, with the other title, when it already is. macOS asks the user to confirm.
    private var defaultBrowserRow: some View {
        let button = ExternalOpenText.defaultBrowserButton(isDefault: state.isDefaultBrowser)
        return Button(button.title, action: makeDefaultBrowser)
            .disabled(!button.isEnabled)
            .accessibilityLabel(button.title)
    }
}

/// Tabs: ⌃1–9, compact mode, how long the archive keeps closed tabs (read-only) and "Archive idle tabs after" (off by default).
struct TabsPane: View {
    let shortcuts: WorkspaceShortcutsSetting?
    let compactMode: CompactModeSetting?
    let autoArchive: AutoArchiveSetting?

    var body: some View {
        Form {
            if let shortcuts {
                Toggle(WorkspaceShortcutsSetting.title, isOn: Binding(get: { shortcuts.isEnabled }, set: { shortcuts.set($0) }))
                    .accessibilityLabel(WorkspaceShortcutsSetting.title)
                note(WorkspaceShortcutsSetting.note)
            }
            if let compactMode {
                Toggle(CompactModeSetting.title, isOn: Binding(get: { compactMode.isEnabled }, set: { compactMode.set($0) }))
                    .accessibilityLabel(CompactModeSetting.title)
                note(CompactModeSetting.note)
            }
            LabeledContent(SettingsCopy.archiveTrimTitle, value: SettingsCopy.archiveTrimValue)
                .accessibilityElement(children: .combine)
            if let autoArchive {
                Picker(AutoArchiveAfter.settingTitle, selection: Binding(get: { autoArchive.limit }, set: { autoArchive.set($0) })) {
                    ForEach(AutoArchiveAfter.allCases, id: \.self) { Text($0.title).tag($0) }
                }
                .accessibilityLabel(AutoArchiveAfter.settingTitle)
            }
        }
        .formStyle(.grouped)
        .fixedSize(horizontal: false, vertical: true)
    }

    private func note(_ text: String) -> some View {
        Text(text).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
    }
}
