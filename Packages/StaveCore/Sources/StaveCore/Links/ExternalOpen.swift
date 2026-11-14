import Foundation

/// The read access an opened HTML file gets (decision 6, question 13): its folder, so its sibling images and CSS load, or the file alone when
/// that folder is `/` or the home folder. Paths are standardized and symlinks resolved first.
public enum OpenedFile {
    /// The file extensions Stave opens as HTML files (`public.html`, `public.xhtml`).
    public static let htmlExtensions: Set<String> = ["html", "htm", "xhtml", "xht"]

    public static func readAccessURL(for file: URL, home: URL) -> URL {
        let resolvedFile = resolved(file)
        let folder = resolvedFile.deletingLastPathComponent()
        let folderPath = folder.path
        guard folderPath != "/", folderPath != resolved(home).path else { return resolvedFile }
        return URL(fileURLWithPath: folderPath, isDirectory: true)
    }

    /// The standardized path with its symlinks resolved, as far as the file system has them: a path that doesn't exist (or whose last part
    /// doesn't yet) keeps the parts that can't be resolved. Never fails.
    public static func resolved(_ url: URL) -> URL {
        let standardized = url.standardizedFileURL
        if let real = realPath(standardized.path) { return URL(fileURLWithPath: real) }
        let parent = standardized.deletingLastPathComponent()
        guard parent.path != standardized.path, let realParent = realPath(parent.path) else { return standardized }
        return URL(fileURLWithPath: realParent).appendingPathComponent(standardized.lastPathComponent)
    }

    /// The resolved path of a `file:` address on this Mac (no host, or `localhost`); nil for anything else.
    public static func path(ofFileURL text: String) -> String? {
        guard URLScheme.scheme(of: text) == "file", let url = URL(string: text), url.isFileURL else { return nil }
        if let host = url.host, !host.isEmpty, host.lowercased() != "localhost" { return nil }
        return resolved(url).path
    }

    /// Whether a `file:` address is the granted folder, inside it, or the granted file itself.
    public static func isInside(_ text: String, grantedFolder: String) -> Bool {
        guard let path = path(ofFileURL: text) else { return false }
        let folder = grantedFolder.count > 1 && grantedFolder.hasSuffix("/") ? String(grantedFolder.dropLast()) : grantedFolder
        return path == folder || path.hasPrefix(folder == "/" ? "/" : folder + "/")
    }

    public static func isHTML(_ url: URL) -> Bool {
        htmlExtensions.contains(url.pathExtension.lowercased())
    }

    /// The file a drop on a window opens (decision 6): its first HTML file; nil when it carries none, so the drop does nothing.
    public static func firstHTML(_ urls: [URL]) -> URL? {
        urls.first { $0.isFileURL && isHTML($0) }
    }

    private static func realPath(_ path: String) -> String? {
        guard let pointer = realpath(path, nil) else { return nil }
        defer { free(pointer) }
        return String(cString: pointer)
    }
}

/// Where a link from another app opens (decision 7): the most recently active browser window, or a chosen profile and workspace.
public enum ExternalLinkTarget: Codable, Sendable, Equatable, Hashable {
    case lastUsed
    case workspace(profileID: UUID, workspaceID: UUID)
}

/// One open browser window, as routing sees it. The app passes its browser windows only, most recently active first: a private window is
/// another kind of window (`PrivateWindowController`) and is never summarized, so it can never receive a link.
public struct WindowSummary: Sendable, Equatable {
    public var windowID: UUID
    public var profileID: UUID
    public var workspaceID: UUID

    public init(windowID: UUID, profileID: UUID, workspaceID: UUID) {
        self.windowID = windowID
        self.profileID = profileID
        self.workspaceID = workspaceID
    }
}

public enum ExternalRoute: Sendable, Equatable {
    /// An open window takes the link, switching to `switchTo` first when it is set.
    case existing(windowID: UUID, switchTo: UUID?)
    case newWindow(profileID: UUID, workspaceID: UUID)
}

/// What `application(_:open:)` does with one URL.
public enum ExternalLink: Sendable, Equatable {
    /// Goes through the policy as `.typed`.
    case web(String)
    /// An HTML file, opened through `.openedFile`.
    case file(URL)
    /// Refused before the policy (too long, or a file that isn't HTML); the text is what the refused panel shows.
    case refused(String)
}

/// Links and files from other apps (decisions 6 and 7, questions 13 and 14).
public enum ExternalOpen {
    /// A longer URL from another app is refused before the policy sees it.
    public static let maximumURLLength = 32_768
    /// How much of a refused URL the panel shows.
    static let shownLength = 2_048

    public static func accepts(_ url: String) -> Bool {
        url.utf8.count <= maximumURLLength
    }

    public static func classify(_ url: URL) -> ExternalLink {
        let text = url.absoluteString
        guard accepts(text) else { return .refused(shown(text)) }
        if url.isFileURL { return OpenedFile.isHTML(url) ? .file(url) : .refused(text) }
        return .web(text)
    }

    /// A refused URL cut to what a panel can show.
    static func shown(_ text: String) -> String {
        text.count > shownLength ? String(text.prefix(shownLength)) + "…" : text
    }

    /// Where a link lands. Nil only when there is no profile at all, which the caller reports.
    public static func route(
        target: ExternalLinkTarget,
        windows: [WindowSummary],
        workspacesByProfile: [(profileID: UUID, workspaceIDs: [UUID])],
        lastSession: (profileID: UUID, workspaceID: UUID)?
    ) -> ExternalRoute? {
        guard case .workspace(let profileID, let workspaceID) = target,
              let profile = workspacesByProfile.first(where: { $0.profileID == profileID }),
              let chosen = profile.workspaceIDs.contains(workspaceID) ? workspaceID : profile.workspaceIDs.first else {
            return lastUsed(windows: windows, workspacesByProfile: workspacesByProfile, lastSession: lastSession)
        }
        if let showing = windows.first(where: { $0.profileID == profileID && $0.workspaceID == chosen }) {
            return .existing(windowID: showing.windowID, switchTo: nil)
        }
        if let ofProfile = windows.first(where: { $0.profileID == profileID }) {
            return .existing(windowID: ofProfile.windowID, switchTo: chosen)
        }
        return .newWindow(profileID: profileID, workspaceID: chosen)
    }

    private static func lastUsed(
        windows: [WindowSummary],
        workspacesByProfile: [(profileID: UUID, workspaceIDs: [UUID])],
        lastSession: (profileID: UUID, workspaceID: UUID)?
    ) -> ExternalRoute? {
        if let first = windows.first { return .existing(windowID: first.windowID, switchTo: nil) }
        if let lastSession, workspacesByProfile.contains(where: { $0.profileID == lastSession.profileID && $0.workspaceIDs.contains(lastSession.workspaceID) }) {
            return .newWindow(profileID: lastSession.profileID, workspaceID: lastSession.workspaceID)
        }
        for profile in workspacesByProfile {
            if let workspaceID = profile.workspaceIDs.first { return .newWindow(profileID: profile.profileID, workspaceID: workspaceID) }
        }
        return nil
    }
}
