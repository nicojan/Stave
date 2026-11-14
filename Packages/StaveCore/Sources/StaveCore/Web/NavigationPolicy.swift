/// Where a navigation came from, which decides how hostile its URL may be.
public enum NavigationSource: Sendable, Equatable {
    case stored, restored, typed
    /// A navigation the page makes. `grantedFolder` is the tab's opened-file grant (`OpenedFile.readAccessURL`'s path), kept in memory only:
    /// a user-clicked main-frame `file:` link inside it opens.
    case page(userGesture: Bool, grantedFolder: String? = nil)
    /// The HTML file the user opened (Finder, a drop, File ▸ Open File…), with the folder (or the file alone) WebKit may read (decision 6).
    case openedFile(grantedFolder: String)
}

public enum NavigationDecision: Sendable, Equatable {
    case allow
    case askToOpenExternally(String)
    /// `nil` refuses silently.
    case refuse(PageFailure?)
}

/// The main-frame and subframe navigation decision table (plan 3, decision 5).
public enum NavigationPolicy {
    private static let handledSchemes: Set<String> = ["http", "https", "about", "blob", "data", "file", "javascript"]

    public static func decide(_ url: String, isMainFrame: Bool, source: NavigationSource) -> NavigationDecision {
        let scheme = URLScheme.scheme(of: url)
        guard isMainFrame else {
            if URLScheme.hasWebAuthority(url) { return .allow }
            if let scheme, ["about", "data", "blob"].contains(scheme) { return .allow }
            return .refuse(nil)
        }
        if URLScheme.hasWebAuthority(url) { return .allow }
        if scheme == "file" { return decideFile(url, source: source) }
        if scheme == "about", url.lowercased() == "about:blank" { return .allow }
        if scheme == "blob", case .page = source { return .allow }
        if let scheme, !handledSchemes.contains(scheme) {
            switch source {
            case .typed, .page(true, _): return .askToOpenExternally(url)
            case .page(false, _): return .refuse(nil)
            case .stored, .restored, .openedFile: break
            }
        }
        if case .page = source { return .refuse(nil) }
        return .refuse(.refused(url: url))
    }

    /// A main-frame `file:` URL (decision 6, question 13): the opened file, or a clicked link inside the tab's grant. A stored or restored
    /// one waits for "Open Again"; a script-started one is refused silently; one typed or clicked outside the grant shows the refused panel.
    private static func decideFile(_ url: String, source: NavigationSource) -> NavigationDecision {
        switch source {
        case .openedFile(let folder), .page(true, let folder?):
            return OpenedFile.isInside(url, grantedFolder: folder) ? .allow : .refuse(.refused(url: url))
        case .page:
            return .refuse(nil)
        case .stored, .restored:
            return .refuse(.fileNotReopened(url: url))
        case .typed:
            return .refuse(.refused(url: url))
        }
    }
}

public enum LinkDisposition: Sendable, Equatable {
    case current
    case newTab(select: Bool)

    public static func decide(command: Bool, shift: Bool, targetsNewWindow: Bool) -> LinkDisposition {
        if command { return .newTab(select: shift) }
        if targetsNewWindow { return .newTab(select: true) }
        return .current
    }
}

public enum OpenRoute: Sendable, Equatable {
    case sidebarTab
    case popupWindow

    /// A page that asks for a size, or for a pop-up outright, gets a window; anything else becomes a tab.
    public static func route(width: Double?, height: Double?, popupRequested: Bool) -> OpenRoute {
        popupRequested || width != nil || height != nil ? .popupWindow : .sidebarTab
    }
}
