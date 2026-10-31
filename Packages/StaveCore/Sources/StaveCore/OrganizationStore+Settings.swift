import Foundation
import GRDB

extension OrganizationStore {
    // MARK: - Settings

    /// The stored value, or the key's default when the row is missing or its JSON no longer decodes.
    public func setting<V>(_ key: SettingKey<V>) throws -> V {
        let text = try database.writer.read { db in
            try String.fetchOne(db, sql: "SELECT value FROM setting WHERE key = ?", arguments: [key.name])
        }
        guard let text, let value = try? JSONDecoder().decode(V.self, from: Data(text.utf8)) else {
            return key.defaultValue
        }
        return value
    }

    public func setSetting<V>(_ key: SettingKey<V>, _ value: V) throws {
        let data = try JSONEncoder().encode(value)
        guard let text = String(data: data, encoding: .utf8) else { throw StoreError.notFound }
        try database.writer.write { db in
            try db.execute(
                sql: """
                    INSERT INTO setting (key, value, modifiedAt) VALUES (?, ?, ?)
                    ON CONFLICT(key) DO UPDATE SET value = excluded.value, modifiedAt = excluded.modifiedAt
                    """,
                arguments: [key.name, text, now()]
            )
        }
    }
}
