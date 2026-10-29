import Foundation

/// Resolves where Stave keeps its data. The folder is always explicit, never a framework default.
public enum StavePaths {
    public static let databaseFileName = "stave.sqlite"
    private static let debugSuffix = ".debug"

    /// `Stave` for release bundle IDs, `Stave-debug` for any ID ending in `.debug`.
    public static func dataDirectory(bundleIdentifier: String, applicationSupport: URL) -> URL {
        let name = bundleIdentifier.hasSuffix(debugSuffix) ? "Stave-debug" : "Stave"
        return applicationSupport.appendingPathComponent(name, isDirectory: true)
    }

    public static func databaseFile(in dataDirectory: URL) -> URL {
        dataDirectory.appendingPathComponent(databaseFileName, isDirectory: false)
    }
}
