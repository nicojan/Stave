import Foundation

/// A page's per-site writes (a zoom, a permission answer): the store write, then a bump of the shared revision, so Settings ▸ Websites, which
/// reads the same rows, re-reads them (R1-L1). The app's page writer calls this; a failed write throws and nothing is bumped.
@MainActor
public struct SiteSettingWrites {
    private let store: OrganizationStore
    private let revision: StoreRevision

    public init(store: OrganizationStore, revision: StoreRevision) {
        self.store = store
        self.revision = revision
    }

    public func setDecision(profileID: UUID, host: String, key: SiteSettingKey, _ decision: SiteDecision?) throws {
        try store.setSiteDecision(profileID: profileID, host: host, key: key, decision)
        revision.bump()
    }

    public func setValue<V: Codable>(profileID: UUID, host: String, key: SiteValueKey, _ value: V?) throws {
        try store.setSiteValue(profileID: profileID, host: host, key: key, value)
        revision.bump()
    }
}
