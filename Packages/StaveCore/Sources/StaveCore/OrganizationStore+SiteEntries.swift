import Foundation
import GRDB

/// One stored per-site answer or value, as Settings ▸ Websites lists it: a `siteSetting` row (camera, microphone, content blocking) or a
/// `siteValue` row (zoom, user agent).
public struct SiteEntry: Equatable, Sendable, Identifiable {
    public enum Kind: Equatable, Sendable {
        case setting(SiteSettingKey)
        case value(SiteValueKey)
    }

    public var id: UUID
    public var profileID: UUID
    public var host: String
    public var kind: Kind
    /// The stored decision (`allow` / `deny`) or the value's JSON text.
    public var stored: String

    public init(id: UUID, profileID: UUID, host: String, kind: Kind, stored: String) {
        self.id = id; self.profileID = profileID; self.host = host; self.kind = kind; self.stored = stored
    }
}

extension OrganizationStore {
    // MARK: - Settings ▸ Websites

    /// Every stored per-site answer and value of the profile, by host (then by what it is), so Settings can list them.
    /// A row whose key this version doesn't know is skipped by the reader's decoding, never fatal.
    public func siteEntries(profileID: UUID) throws -> [SiteEntry] {
        try database.writer.read { db in
            let settings = try Row.fetchAll(
                db, sql: "SELECT id, host, \"key\", decision FROM siteSetting WHERE profileID = ?", arguments: [profileID]
            ).compactMap { row -> SiteEntry? in
                guard let key = SiteSettingKey(rawValue: row["key"]) else { return nil }
                return SiteEntry(id: row["id"], profileID: profileID, host: row["host"], kind: .setting(key), stored: row["decision"])
            }
            let values = try Row.fetchAll(
                db, sql: "SELECT id, host, \"key\", value FROM siteValue WHERE profileID = ?", arguments: [profileID]
            ).compactMap { row -> SiteEntry? in
                guard let key = SiteValueKey(rawValue: row["key"]) else { return nil }
                return SiteEntry(id: row["id"], profileID: profileID, host: row["host"], kind: .value(key), stored: row["value"])
            }
            return (settings + values).sorted {
                ($0.host, $0.kind.sortName) < ($1.host, $1.kind.sortName)
            }
        }
    }

    /// Removes one stored answer or value. Not user data (it only makes the site ask again), so no archive. Unknown entries are ignored.
    public func removeSiteEntry(_ entry: SiteEntry) throws {
        try database.writer.write { db in
            switch entry.kind {
            case .setting: _ = try SiteSetting.deleteOne(db, key: entry.id)
            case .value: _ = try SiteValue.deleteOne(db, key: entry.id)
            }
        }
    }

    /// Removes every stored answer and value of the profile (Remove All, asked first). Returns how many rows went.
    @discardableResult
    public func removeAllSiteEntries(profileID: UUID) throws -> Int {
        try database.writer.write { db in
            let settings = try SiteSetting.filter(Column("profileID") == profileID).deleteAll(db)
            let values = try SiteValue.filter(Column("profileID") == profileID).deleteAll(db)
            return settings + values
        }
    }
}

private extension SiteEntry.Kind {
    var sortName: String {
        switch self {
        case .setting(let key): "0-" + key.rawValue
        case .value(let key): "1-" + key.rawValue
        }
    }
}
