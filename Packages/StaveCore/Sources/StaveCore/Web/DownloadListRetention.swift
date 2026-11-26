import Foundation
import Observation

/// "Remove download list items", Safari's choices (decision 33, question 22). After one day by default.
public enum DownloadListRetention: String, Codable, Sendable, CaseIterable {
    case day, onQuit, onSuccess, manually

    /// The setting's label.
    public static let settingTitle = "Remove download list items"

    public var title: String {
        switch self {
        case .day: "After one day"
        case .onQuit: "When Stave quits"
        case .onSuccess: "Upon successful download"
        case .manually: "Manually"
        }
    }
}

/// "Remove download list items" as live state for Settings; writing it bumps `revision`. The next trim, or the next finished download,
/// applies it.
@MainActor @Observable
public final class DownloadListRetentionSetting {
    @ObservationIgnored private let store: OrganizationStore
    @ObservationIgnored private let revision: StoreRevision
    @ObservationIgnored public var onSaveError: (@MainActor (Error) -> Void)?

    public init(store: OrganizationStore, revision: StoreRevision) {
        self.store = store
        self.revision = revision
    }

    public var retention: DownloadListRetention {
        _ = revision.value
        return stored
    }

    private var stored: DownloadListRetention {
        (try? store.setting(SettingKeys.downloadListRetention)) ?? SettingKeys.downloadListRetention.defaultValue
    }

    public func set(_ retention: DownloadListRetention) {
        guard retention != stored else { return }
        do {
            try store.setSetting(SettingKeys.downloadListRetention, retention)
            revision.bump()
        } catch {
            onSaveError?(error)
        }
    }
}
