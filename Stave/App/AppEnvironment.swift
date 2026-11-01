import ChorusEngine
import Foundation
import StaveCore
import StaveWeb

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
    /// The search-engine setting for Settings; writing it bumps `revision`.
    let searchEngine: SearchEngineSetting
    /// The folder Arc's files are looked for under: the Debug override, or the real home.
    let arcHome: URL
    /// Every page's website data store; never `WKWebsiteDataStore.default()`.
    let webStores: WebDataStores
    let contentBlocker: ContentBlockerManager
    /// The live pages of every window, keyed by tab.
    let pageHost: PageHost
    /// Retained here for the app's life: `PageHost` and its pages hold the writer weakly.
    let pageWriter: StorePageWriter
    /// Downloads in memory, per profile.
    let downloads: DownloadList
    /// The writer for pop-up pages, which are no store tabs: it drops every write. Retained here for the same reason as `pageWriter`.
    let popupWriter = DiscardingPageWriter()
    /// Every open pop-up window, by opener tab.
    let popups = PopupRegistry()

    /// Opens (creating if needed) the database and makes sure a profile exists, then runs the launch maintenance and, when asked, seeds
    /// the sample. Throws `StoreError.newerSchema` without touching the file when the data was written by a newer Stave.
    init(dataDirectory: URL, arcHome: URL, seedSample: Bool) throws {
        try FileManager.default.createDirectory(at: dataDirectory, withIntermediateDirectories: true)
        if arcHome.lastPathComponent == LaunchArguments.isolatedArcHomeName, arcHome.deletingLastPathComponent().standardizedFileURL == dataDirectory.standardizedFileURL {
            try FileManager.default.createDirectory(at: arcHome, withIntermediateDirectories: true)
        }
        let database = try StaveDatabase.open(at: StavePaths.databaseFile(in: dataDirectory))
        let store = OrganizationStore(database: database)
        _ = try store.ensureDefaultProfile()
        try store.launchMaintenance()
        #if DEBUG
        if seedSample, try SampleOrganization.seed(into: store) { try SampleOrganization.seedHostileStoredURL(into: store) }
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
        let engine = SearchEngineSetting(store: store, revision: revision)
        engine.onSaveError = { NSLog("Stave: could not save the search engine: \($0)") }
        self.searchEngine = engine
        let writer = StorePageWriter(store: store, revision: revision)
        self.pageWriter = writer
        self.downloads = DownloadList()
        let webStores = WebDataStores()
        self.webStores = webStores
        let blocker = ContentBlockerManager()
        self.contentBlocker = blocker
        let host = PageHost(
            stores: webStores, contentBlocker: blocker, siteSettings: writer,
            applicationName: UserAgent.applicationName(safariVersion: Self.systemSafariVersion())
        )
        self.pageHost = host
        // An opener with pop-ups open never hibernates: the pop-up's `window.opener` (an OAuth sign-in, say) needs its page (ruling R14).
        let popups = self.popups
        host.hasOpenPopups = { [weak popups] id in popups?.hasPopups(openedBy: id) ?? false }
        // A snapshot stands in only for a tab another window shows; one with no owner and no live page is dropped.
        let livePages = self.livePages
        host.hasOwner = { [weak livePages] id in livePages?.owner(of: id) != nil }
        // Lists that compile after pages were made are attached to them, taking effect from each page's next load.
        blocker.onReady = { [weak host] in host?.reattachRuleLists() }
        blocker.start()
    }

    /// The system Safari's version, so the user agent never claims a newer Safari than this Mac's WebKit; nil when it can't be read.
    private static func systemSafariVersion() -> String? {
        Bundle(url: URL(fileURLWithPath: "/Applications/Safari.app", isDirectory: true))?
            .object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
    }

    /// `~/Downloads`, from FileManager.
    static var downloadsDirectory: URL {
        FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Downloads", isDirectory: true)
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
