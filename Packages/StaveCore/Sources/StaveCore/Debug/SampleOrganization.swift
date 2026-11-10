import Foundation

/// A synthetic organization for by-hand checks and sidebar tests. Every URL is on example.com/.org/.net and every title is invented.
public enum SampleOrganization {
    private static let japaneseTitle = "日本の天気予報"
    private static let longTitle = String(repeating: "Long title ", count: 20).prefix(200).description

    /// Writes the sample when the store has no tabs and returns true; otherwise writes nothing and returns false.
    @discardableResult
    public static func seed(into store: OrganizationStore) throws -> Bool {
        guard try store.isTabless() else { return false }
        let profile = try store.ensureDefaultProfile()
        let home = try requireFirst(try store.workspaces(profileID: profile.id))
        let work = try store.createWorkspace(profileID: profile.id, name: "Work", icon: "💼", colorHex: "#3478F6")
        let google = try store.createContainer(profileID: profile.id, name: "Work Google", colorHex: "#34C759")

        try seedEssentials(store, home: home)
        try seedHomePinned(store, home: home)
        try seedRegular(store, home: home, container: google)
        try seedWork(store, work: work)
        return true
    }

    private static func requireFirst(_ list: [Workspace]) throws -> Workspace {
        guard let first = list.first else { throw StoreError.notFound }
        return first
    }

    private static func tab(_ store: OrganizationStore, _ url: String, _ title: String, in workspace: Workspace, container: Container? = nil) throws -> Tab {
        try store.openTab(url: url, title: title, workspaceID: workspace.id, origin: .commandBar, containerID: container?.id, edge: .bottom)
    }

    private static func seedEssentials(_ store: OrganizationStore, home: Workspace) throws {
        for (url, title) in [
            ("https://mail.example.com/", "Mail"),
            ("https://calendar.example.org/", "Calendar"),
            ("https://notes.example.net/", "Notes"),
        ] {
            try store.makeEssential(try tab(store, url, title, in: home).id)
        }
    }

    private static func seedHomePinned(_ store: OrganizationStore, home: Workspace) throws {
        let reading = try store.createFolder(workspaceID: home.id, parentFolderID: nil, title: "Reading")
        let later = try store.createFolder(workspaceID: home.id, parentFolderID: reading.id, title: "Later")
        for (url, title) in [("https://example.com/later/one", "Saved essay"), ("https://example.org/later/two", japaneseTitle)] {
            try store.pinTab(try tab(store, url, title, in: home).id, folderID: later.id)
        }
        try store.pinTab(try tab(store, "https://news.example.com/", "Morning headlines", in: home).id, folderID: reading.id)
        let drifting = try tab(store, "https://blog.example.net/", "Field notes", in: home)
        try store.pinTab(drifting.id, folderID: reading.id)
        try store.updateNavigation(tabID: drifting.id, url: "https://blog.example.net/posts/42", title: "Post 42", faviconURL: nil, interactionState: nil)
        for (url, title) in [("https://docs.example.org/", "Reference docs"), ("https://board.example.net/", "Project board")] {
            try store.pinTab(try tab(store, url, title, in: home).id, folderID: nil)
        }
    }

    private static func seedRegular(_ store: OrganizationStore, home: Workspace, container: Container) throws {
        _ = try tab(store, "https://example.com/recipes", "Weeknight recipes", in: home)
        _ = try tab(store, "https://example.org/maps", longTitle, in: home)
        _ = try tab(store, "https://shop.example.net/cart", "Shopping cart", in: home)
        _ = try tab(store, "https://drive.example.com/files", "Shared files", in: home, container: container)
        for (url, title) in [("https://example.com/old-1", "Old receipt"), ("https://example.net/old-2", "Closed forum thread")] {
            _ = try store.closeTab(try tab(store, url, title, in: home).id)
        }
    }

    private static func seedWork(_ store: OrganizationStore, work: Workspace) throws {
        try store.pinTab(try tab(store, "https://tracker.example.org/", "Issue tracker", in: work).id, folderID: nil)
        _ = try tab(store, "https://wiki.example.com/handbook", "Team handbook", in: work)
        _ = try tab(store, "https://example.net/standup", "Standup notes", in: work)
    }
}
