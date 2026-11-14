/// Where a navigation came from, which decides how hostile its URL may be.
public enum NavigationSource: Sendable, Equatable {
    case stored, restored, typed, page(userGesture: Bool)
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
        if scheme == "about", url.lowercased() == "about:blank" { return .allow }
        if scheme == "blob", case .page = source { return .allow }
        if let scheme, !handledSchemes.contains(scheme) {
            switch source {
            case .typed, .page(userGesture: true): return .askToOpenExternally(url)
            case .page(userGesture: false): return .refuse(nil)
            case .stored, .restored: break
            }
        }
        if case .page = source { return .refuse(nil) }
        return .refuse(.refused(url: url))
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
