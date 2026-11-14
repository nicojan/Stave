import Foundation
import GRDB

extension OrganizationStore {
    // MARK: - Site values (decision 12; Task 16's user agent)

    /// The value stored for the profile, host and key, decoded as `V`; nil when there is none. A row that doesn't decode as `V` throws.
    /// `host` is `SiteHost.normalized`'s key, the one site settings use.
    public func siteValue<V: Codable>(profileID: UUID, host: String, key: SiteValueKey, as type: V.Type) throws -> V? {
        let row = try database.writer.read { db in try Self.siteValueRow(db, profileID: profileID, host: host, key: key) }
        guard let row else { return nil }
        return try JSONDecoder().decode(V.self, from: Data(row.value.utf8))
    }

    /// Stores the value (one row per profile, host and key); nil removes the row. Writing for a profile that doesn't exist throws `.notFound`.
    public func setSiteValue<V: Codable>(profileID: UUID, host: String, key: SiteValueKey, _ value: V?) throws {
        let stamp = now()
        let text = try value.map { String(decoding: try JSONEncoder().encode($0), as: UTF8.self) }
        try database.writer.write { db in
            let existing = try Self.siteValueRow(db, profileID: profileID, host: host, key: key)
            guard let text else {
                _ = try existing?.delete(db)
                return
            }
            guard try Profile.fetchOne(db, key: profileID) != nil else { throw StoreError.notFound }
            var row = existing ?? SiteValue(profileID: profileID, host: host, key: key, value: text, modifiedAt: stamp)
            row.value = text
            row.modifiedAt = stamp
            try row.save(db)
        }
    }

    private static func siteValueRow(_ db: Database, profileID: UUID, host: String, key: SiteValueKey) throws -> SiteValue? {
        try SiteValue
            .filter(Column("profileID") == profileID && Column("host") == host && Column("key") == key.rawValue)
            .fetchOne(db)
    }
}
