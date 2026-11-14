import Foundation
import Observation

/// Every string for the default-browser button, the link-target setting, File ▸ Open File… and links that couldn't open.
public enum ExternalOpenText {
    public static let makeDefault = "Make Stave your default browser"
    public static let isDefault = "Stave is your default browser"
    public static let linkTargetTitle = "Open links from other apps in"
    public static let lastUsed = "Last used"
    public static let openFileMenuItem = "Open File…"
    public static let unopenedTitle = "Stave couldn't open these links"
    public static let noWindowDetail = "Stave has no profile to open them in."

    /// The Settings button: disabled, with the other title, when Stave already is the default browser.
    public static func defaultBrowserButton(isDefault: Bool) -> (title: String, isEnabled: Bool) {
        isDefault ? (Self.isDefault, false) : (makeDefault, true)
    }

    /// Whether the app macOS opens `http` links with is this one (compared by bundle ID, so a Debug build is not the Release one).
    public static func isStaveDefault(defaultBundleID: String?, ownBundleID: String?) -> Bool {
        guard let defaultBundleID, let ownBundleID else { return false }
        return defaultBundleID == ownBundleID
    }

    /// The links a failed launch couldn't open, one per line, for the failure alert; nil when there were none.
    public static func unopenedLinks(_ links: [String]) -> String? {
        guard !links.isEmpty else { return nil }
        return "\(unopenedTitle):\n" + links.map { ExternalOpen.shown($0) }.joined(separator: "\n")
    }

    public struct Choice: Sendable, Equatable {
        public let title: String
        public let target: ExternalLinkTarget
    }

    /// "Last used", then every profile's workspaces in sidebar order.
    public static func choices(profiles: [(profileID: UUID, name: String, workspaces: [(id: UUID, name: String)])]) -> [Choice] {
        [Choice(title: lastUsed, target: .lastUsed)] + profiles.flatMap { profile in
            profile.workspaces.map { workspace in
                Choice(title: "\(profile.name) – \(workspace.name)", target: .workspace(profileID: profile.profileID, workspaceID: workspace.id))
            }
        }
    }
}

/// The "Open links from other apps in" setting as live state for Settings. Writing it bumps the revision.
@MainActor @Observable
public final class ExternalLinkSetting {
    @ObservationIgnored private let store: OrganizationStore
    @ObservationIgnored private let revision: StoreRevision
    @ObservationIgnored public var onSaveError: (@MainActor (Error) -> Void)?

    public init(store: OrganizationStore, revision: StoreRevision) {
        self.store = store
        self.revision = revision
    }

    public var target: ExternalLinkTarget {
        _ = revision.value
        return (try? store.setting(SettingKeys.externalLinkTarget)) ?? .lastUsed
    }

    /// The picker's choices; just "Last used" when the store can't be read.
    public var choices: [ExternalOpenText.Choice] {
        _ = revision.value
        let profiles = (try? store.profiles()) ?? []
        let listed = profiles.map { profile in
            let workspaces = (try? store.workspaces(profileID: profile.id)) ?? []
            return (profileID: profile.id, name: profile.name, workspaces: workspaces.map { (id: $0.id, name: $0.name) })
        }
        return ExternalOpenText.choices(profiles: listed)
    }

    public func set(_ target: ExternalLinkTarget) {
        guard target != self.target else { return }
        do {
            try store.setSetting(SettingKeys.externalLinkTarget, target)
            revision.bump()
        } catch {
            onSaveError?(error)
        }
    }
}
