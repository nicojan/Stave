import Foundation
@testable import StaveCore

/// A fresh database file in its own temp folder. The caller may delete the folder's parent when done.
func makeTempDatabase() throws -> (StaveDatabase, URL) {
    let folder = FileManager.default.temporaryDirectory
        .appendingPathComponent("StaveTests-\(UUID().uuidString)", isDirectory: true)
    let file = folder.appendingPathComponent(StavePaths.databaseFileName)
    let database = try StaveDatabase.open(at: file)
    return (database, file)
}
