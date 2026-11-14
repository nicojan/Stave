import Foundation
import GRDB

public enum SiteSettingKey: String, Codable, Sendable { case camera, microphone, contentBlocking }

/// For `contentBlocking`, `.deny` means blocking is off for the site.
public enum SiteDecision: String, Codable, Sendable { case allow, deny }

/// A remembered per-site choice, scoped to a profile. Not user data: removing one needs no archive.
public struct SiteSetting: Codable, FetchableRecord, PersistableRecord, Sendable, Identifiable, Equatable {
    public static let databaseTableName = "siteSetting"

    public var id: UUID
    public var profileID: UUID
    public var host: String
    public var key: SiteSettingKey
    public var decision: SiteDecision
    public var modifiedAt: Date

    public init(id: UUID = UUID(), profileID: UUID, host: String, key: SiteSettingKey, decision: SiteDecision, modifiedAt: Date = Date()) {
        self.id = id; self.profileID = profileID; self.host = host; self.key = key
        self.decision = decision; self.modifiedAt = modifiedAt
    }
}

/// The key a site's settings are stored under: the lowercased host with no port and no leading "www.".
public enum SiteHost {
    /// Accepts a web URL or a bare host. Nil for a non-web URL or an empty host. The key is `HostText`'s host, the one
    /// rule the address field and monograms also use (plan 5 decision 3).
    public static func normalized(_ urlOrHost: String) -> String? {
        HostText.host(of: urlOrHost)
    }
}
