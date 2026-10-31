import Foundation
import Observation

/// The "Use ⌃1–9 to switch workspaces" setting as live state: the Settings toggle writes it and the Workspaces menu reads it, so a change
/// shows in the menu at once, without a relaunch.
@MainActor @Observable
public final class WorkspaceShortcutsSetting {
    public private(set) var isEnabled: Bool
    /// Called when writing the setting fails; the value reverts to what is stored.
    @ObservationIgnored public var onSaveError: (@MainActor (Error) -> Void)?
    @ObservationIgnored private let store: OrganizationStore

    public init(store: OrganizationStore) {
        self.store = store
        isEnabled = (try? store.setting(SettingKeys.workspaceShortcutsEnabled)) ?? SettingKeys.workspaceShortcutsEnabled.defaultValue
    }

    public func set(_ enabled: Bool) {
        guard enabled != isEnabled else { return }
        do {
            try store.setSetting(SettingKeys.workspaceShortcutsEnabled, enabled)
            isEnabled = enabled
        } catch {
            onSaveError?(error)
        }
    }

    public static let title = "Use ⌃1–9 to switch workspaces"
    public static let note = "If macOS uses ⌃1–9 to switch desktops, turn those off in System Settings ▸ Keyboard ▸ Keyboard Shortcuts ▸ Mission Control, or turn this off."
}
