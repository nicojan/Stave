import Foundation

/// Arc's default file locations and the one-call import: parse, plan, write.
public enum ArcImporter {
    /// Local State is a small JSON file; anything larger is not read.
    public static let maximumLocalStateSize = 16 * 1024 * 1024

    public static func sidebarFile(home: URL) -> URL {
        arcFolder(home: home).appendingPathComponent("StorableSidebar.json")
    }

    public static func localStateFile(home: URL) -> URL {
        arcFolder(home: home)
            .appendingPathComponent("User Data", isDirectory: true)
            .appendingPathComponent("Local State")
    }

    /// Local State sits in `User Data` beside the sidebar file in Arc's own folder layout.
    public static func localStateFile(nextTo sidebarFile: URL) -> URL {
        sidebarFile.deletingLastPathComponent()
            .appendingPathComponent("User Data", isDirectory: true)
            .appendingPathComponent("Local State")
    }

    /// True when a regular file exists at Arc's default sidebar location.
    public static func isAvailable(home: URL) -> Bool {
        regularFileSize(at: sidebarFile(home: home)) != nil
    }

    /// Reads a sidebar file from disk. The size is checked before any byte is read; a missing file, a directory or a read failure is `.unreadable`. An unreadable Local State counts as absent.
    public static func run(
        sidebarFile: URL,
        localStateFile: URL?,
        options: ArcImportOptions,
        into store: OrganizationStore
    ) throws -> ArcImportReport {
        guard let size = regularFileSize(at: sidebarFile) else { throw ArcImportError.unreadable }
        guard size <= ArcSidebarParser.maximumFileSize else { throw ArcImportError.fileTooLarge }
        guard let sidebar = try? Data(contentsOf: sidebarFile.resolvingSymlinksInPath()) else { throw ArcImportError.unreadable }
        let localState = localStateFile.flatMap(readLocalState)
        return try run(sidebar: sidebar, localState: localState, options: options, into: store)
    }

    public static func run(
        sidebar: Data,
        localState: Data?,
        options: ArcImportOptions,
        into store: OrganizationStore
    ) throws -> ArcImportReport {
        let parsed = try ArcSidebarParser.parse(sidebar)
        let names = localState.map { ArcProfileNames.names(fromLocalState: $0) } ?? [:]
        let plan = ArcImportPlanner.plan(parsed, options: options, profileNames: names)
        return try store.importArc(plan)
    }

    /// Local State bytes, or nil (treated as absent) when it is not a regular file, is over the cap or cannot be read.
    private static func readLocalState(_ url: URL) -> Data? {
        let resolved = url.resolvingSymlinksInPath()
        guard let size = regularFileSize(at: resolved), size <= maximumLocalStateSize else { return nil }
        return try? Data(contentsOf: resolved)
    }

    /// The size of a regular file after resolving symlinks, or nil for anything else (missing, a directory, a device, a FIFO).
    private static func regularFileSize(at link: URL) -> Int? {
        let url = link.resolvingSymlinksInPath()
        let keys: Set<URLResourceKey> = [.isRegularFileKey, .fileSizeKey]
        guard let values = try? url.resourceValues(forKeys: keys), values.isRegularFile == true else { return nil }
        return values.fileSize
    }

    private static func arcFolder(home: URL) -> URL {
        home.appendingPathComponent("Library", isDirectory: true)
            .appendingPathComponent("Application Support", isDirectory: true)
            .appendingPathComponent("Arc", isDirectory: true)
    }
}
