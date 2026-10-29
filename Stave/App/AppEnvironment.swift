import Foundation
import StaveCore

/// Owns the opened store for the lifetime of the process. The data folder comes only from the bundle id and the
/// Application Support URL (via `StavePaths`), never from a framework default.
@MainActor
final class AppEnvironment: ObservableObject {
    let store: OrganizationStore
    let dataDirectory: URL

    /// Bumped after every write the UI should show; views re-read their snapshot when it changes.
    @Published private(set) var refreshToken = 0

    /// Opens (creating if needed) the database and makes sure a profile exists. Throws `StoreError.newerSchema`
    /// without touching the file when the data was written by a newer Stave.
    init(bundleIdentifier: String, applicationSupport: URL) throws {
        let directory = StavePaths.dataDirectory(bundleIdentifier: bundleIdentifier, applicationSupport: applicationSupport)
        let database = try StaveDatabase.open(at: StavePaths.databaseFile(in: directory))
        let store = OrganizationStore(database: database)
        _ = try store.ensureDefaultProfile()
        self.store = store
        self.dataDirectory = directory
    }

    /// Launches with the real bundle id and Application Support folder.
    static func live() throws -> AppEnvironment {
        let support = try FileManager.default.url(
            for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true
        )
        return try AppEnvironment(bundleIdentifier: Bundle.main.bundleIdentifier!, applicationSupport: support)
    }

    func noteStoreChanged() { refreshToken += 1 }
}
