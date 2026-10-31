import Foundation
import StaveCore

/// Owns the opened store and the objects every window shares, for the lifetime of the process. The data folder comes from the Debug
/// launch option or from the bundle id and the Application Support URL (via `StavePaths`), never from a framework default.
@MainActor
final class AppEnvironment {
    let store: OrganizationStore
    let dataDirectory: URL
    let revision: StoreRevision
    let livePages: LivePageRegistry
    let session: WindowSession
    /// The one sidebar width of the app, shared by every window.
    let sidebarWidth: SidebarWidthModel
    /// The ⌃1–9 setting as live state, read by the Workspaces menu and written by Settings.
    let workspaceShortcuts: WorkspaceShortcutsSetting
    /// The compact-mode setting for Settings and the View menu; writing it bumps `revision`, so every window follows.
    let compactMode: CompactModeSetting
    /// The folder Arc's files are looked for under: the Debug override, or the real home.
    let arcHome: URL

    /// Opens (creating if needed) the database and makes sure a profile exists, then runs the launch maintenance and, when asked, seeds
    /// the sample. Throws `StoreError.newerSchema` without touching the file when the data was written by a newer Stave.
    init(dataDirectory: URL, arcHome: URL, seedSample: Bool) throws {
        try FileManager.default.createDirectory(at: dataDirectory, withIntermediateDirectories: true)
        let database = try StaveDatabase.open(at: StavePaths.databaseFile(in: dataDirectory))
        let store = OrganizationStore(database: database)
        _ = try store.ensureDefaultProfile()
        try store.launchMaintenance()
        #if DEBUG
        if seedSample { try SampleOrganization.seed(into: store) }
        #endif
        self.store = store
        self.dataDirectory = dataDirectory
        self.arcHome = arcHome
        self.revision = StoreRevision()
        self.livePages = LivePageRegistry()
        let session = WindowSession(store: store)
        session.onSaveError = { NSLog("Stave: could not save window state: \($0)") }
        self.session = session
        let sidebarWidth = SidebarWidthModel(store: store)
        sidebarWidth.onSaveError = { NSLog("Stave: could not save the sidebar width: \($0)") }
        self.sidebarWidth = sidebarWidth
        let shortcuts = WorkspaceShortcutsSetting(store: store)
        shortcuts.onSaveError = { NSLog("Stave: could not save the workspace shortcut setting: \($0)") }
        self.workspaceShortcuts = shortcuts
        let compact = CompactModeSetting(store: store, revision: revision)
        compact.onSaveError = { NSLog("Stave: could not save the compact mode setting: \($0)") }
        self.compactMode = compact
    }

    /// Launches with the Debug options when given, else the real bundle id and Application Support folder.
    static func live(options: DebugLaunchOptions) throws -> AppEnvironment {
        let directory: URL
        if let override = options.dataDirectory {
            directory = override
        } else {
            let support = try FileManager.default.url(
                for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true
            )
            directory = StavePaths.dataDirectory(bundleIdentifier: Bundle.main.bundleIdentifier!, applicationSupport: support)
        }
        return try AppEnvironment(
            dataDirectory: directory,
            arcHome: options.arcHome ?? FileManager.default.homeDirectoryForCurrentUser,
            seedSample: options.seedSample
        )
    }
}
