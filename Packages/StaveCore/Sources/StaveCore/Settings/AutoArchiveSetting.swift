import Foundation
import Observation

/// "Archive idle tabs after" as live state for Settings; writing it bumps `revision`. The next check (launch or the 15-minute one) applies it.
@MainActor @Observable
public final class AutoArchiveSetting {
    @ObservationIgnored private let store: OrganizationStore
    @ObservationIgnored private let revision: StoreRevision
    @ObservationIgnored public var onSaveError: (@MainActor (Error) -> Void)?

    public init(store: OrganizationStore, revision: StoreRevision) {
        self.store = store
        self.revision = revision
    }

    public var limit: AutoArchiveAfter {
        _ = revision.value
        return (try? store.setting(SettingKeys.autoArchiveAfter)) ?? SettingKeys.autoArchiveAfter.defaultValue
    }

    public func set(_ limit: AutoArchiveAfter) {
        guard limit != self.limit else { return }
        do {
            try store.setAutoArchiveAfter(limit) // from Never, this also records when it was turned on
            revision.bump()
        } catch {
            onSaveError?(error)
        }
    }
}
