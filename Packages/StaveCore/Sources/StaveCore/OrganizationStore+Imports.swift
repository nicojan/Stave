import Foundation
import GRDB

public enum ImportSource: String, Codable, Sendable { case arc }

/// One completed import, written in the import's own transaction.
struct ImportRecord: Codable, FetchableRecord, PersistableRecord, Sendable, Identifiable, Equatable {
    static let databaseTableName = "importRecord"

    var id: UUID = UUID()
    var source: ImportSource
    var importedAt: Date
    var modifiedAt: Date
}

extension OrganizationStore {
    /// When the newest import from `source` happened, or nil if there has been none.
    public func lastImport(source: ImportSource) throws -> Date? {
        try database.writer.read { db in
            try ImportRecord
                .filter(Column("source") == source.rawValue)
                .order(Column("importedAt").desc, Column("rowid").desc)
                .fetchOne(db)?.importedAt
        }
    }
}
