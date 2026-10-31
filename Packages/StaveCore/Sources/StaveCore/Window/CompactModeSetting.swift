import Foundation
import Observation

/// The compact-mode setting for the Settings window and the menu: writes through the store and bumps the shared revision, so every window
/// re-reads. `isEnabled` reads the store under the revision, so it follows a toggle made anywhere (menu, command bar, another window).
@MainActor @Observable
public final class CompactModeSetting {
    @ObservationIgnored private let store: OrganizationStore
    @ObservationIgnored private let revision: StoreRevision
    /// Called when writing the setting fails.
    @ObservationIgnored public var onSaveError: (@MainActor (Error) -> Void)?

    public init(store: OrganizationStore, revision: StoreRevision) {
        self.store = store
        self.revision = revision
    }

    public var isEnabled: Bool {
        _ = revision.value
        return (try? store.setting(SettingKeys.compactMode)) ?? SettingKeys.compactMode.defaultValue
    }

    public func set(_ enabled: Bool) {
        guard enabled != isEnabled else { return }
        do {
            try store.setSetting(SettingKeys.compactMode, enabled)
            revision.bump()
        } catch {
            onSaveError?(error)
        }
    }

    public func toggle() { set(!isEnabled) }

    public static let title = "Compact mode"
    public static let menuTitle = "Compact Mode"
    public static let note = "Hides the sidebar until the pointer reaches the left edge of the window. ⌃⌘S turns it on and off."
}
