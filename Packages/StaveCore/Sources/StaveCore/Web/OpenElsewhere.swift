import Foundation

/// The other browsers View ▸ Open in Safari / Open in Chrome and the site panel can hand a page to (plan 5, decision 25).
public enum OpenElsewhereApp: String, CaseIterable, Sendable {
    case safari, chrome

    public var bundleID: String {
        switch self {
        case .safari: "com.apple.Safari"
        case .chrome: "com.google.Chrome"
        }
    }

    public var menuTitle: String {
        switch self {
        case .safari: "Open in Safari"
        case .chrome: "Open in Chrome"
        }
    }
}

public enum OpenElsewhere {
    /// The apps to offer: only those installed, in a fixed order (Safari, then Chrome).
    public static func available(installed: Set<String>) -> [OpenElsewhereApp] {
        OpenElsewhereApp.allCases.filter { installed.contains($0.bundleID) }
    }

    /// The one thing handed over: the page's own http or https address, nothing else. Nil for a blank tab, a file, `data:` or any other scheme.
    public static func url(forPageURL address: String) -> URL? {
        guard URLScheme.hasWebAuthority(address) else { return nil }
        return URL(string: address)
    }
}
