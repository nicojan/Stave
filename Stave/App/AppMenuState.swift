import Observation
import StaveCore

/// What the menus and the Settings window read from the app: the Workspaces menu's items for the key browser window, and the ⌃1–9 setting.
/// The app delegate keeps it current; SwiftUI's `.commands` and the Settings scene observe it.
@MainActor @Observable
final class AppMenuState {
    var workspaceItems: [WorkspaceSwitchItem] = []
    /// Nil until the store is open.
    var shortcuts: WorkspaceShortcutsSetting?
    /// Nil until the store is open.
    var compactMode: CompactModeSetting?
    /// Nil until the store is open.
    var searchEngine: SearchEngineSetting?
    /// The key browser window's compact state, for the View ▸ Compact Mode checkmark.
    var isCompact = false
}
