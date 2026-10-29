import Foundation

/// Arc's default file locations and the one-call import: parse, plan, write.
public enum ArcImporter {
    public static func sidebarFile(home: URL) -> URL {
        arcFolder(home: home).appendingPathComponent("StorableSidebar.json")
    }

    public static func localStateFile(home: URL) -> URL {
        arcFolder(home: home)
            .appendingPathComponent("User Data", isDirectory: true)
            .appendingPathComponent("Local State")
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

    private static func arcFolder(home: URL) -> URL {
        home.appendingPathComponent("Library", isDirectory: true)
            .appendingPathComponent("Application Support", isDirectory: true)
            .appendingPathComponent("Arc", isDirectory: true)
    }
}
