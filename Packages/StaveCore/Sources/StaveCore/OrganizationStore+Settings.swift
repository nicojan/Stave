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
        let text = try Self.encoded(value)
        let stamp = now()
        try database.writer.write { db in try Self.upsert(db, key: key.name, text: text, at: stamp) }
    }

    /// Finishes the first-run screen: the chosen engine and `firstRunCompleted` in one transaction, so a failure leaves neither.
    public func completeFirstRun(engine: SearchEngine) throws {
        let engineText = try Self.encoded(Optional(engine))
        let doneText = try Self.encoded(true)
        let stamp = now()
        try database.writer.write { db in
            try Self.upsert(db, key: SettingKeys.searchEngine.name, text: engineText, at: stamp)
            try Self.upsert(db, key: SettingKeys.firstRunCompleted.name, text: doneText, at: stamp)
        }
    }

    private static func encoded<V: Encodable>(_ value: V) throws -> String {
        let data = try JSONEncoder().encode(value)
        guard let text = String(data: data, encoding: .utf8) else { throw StoreError.notFound }
        return text
    }

    private static func upsert(_ db: Database, key: String, text: String, at stamp: Date) throws {
        try db.execute(
            sql: """
                INSERT INTO setting (key, value, modifiedAt) VALUES (?, ?, ?)
                ON CONFLICT(key) DO UPDATE SET value = excluded.value, modifiedAt = excluded.modifiedAt
                """,
            arguments: [key, text, stamp]
        )
    }
}
