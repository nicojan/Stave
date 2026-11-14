import Foundation

/// The text the sidebar and content placeholder show for a tab or address. Pure rules; the views only place the result.
public enum DisplayText {
    /// The title, or the URL's host when the title is empty, or the URL itself.
    public static func title(for tab: Tab) -> String { title(title: tab.title, url: tab.url) }

    /// The one rule for any record with a title and a URL (open or archived tab).
    public static func title(title: String, url: String) -> String {
        guard title.isEmpty else { return title }
        if let host = URL(string: url)?.host, !host.isEmpty { return host }
        return url.isEmpty ? newTabTitle : url
    }

    /// What a tab with neither a title nor an address (a fresh container tab) is called.
    public static let newTabTitle = "New Tab"

    /// `HostText`'s host (lowercased, no port, no leading `www.`, punycode as WebKit reports it); the whole string when
    /// there is no web host.
    public static func address(for url: String) -> String {
        HostText.host(of: url) ?? url
    }

    /// One character: the first letter of the host, else of the title, uppercased; `"?"` when both are empty. A host whose
    /// first label is punycode (`xn--`) gives way to the title (plan 5 question 4). Leading whitespace is skipped, and only
    /// the first `Character` of the uppercased form is kept, so "ßeta" gives "S" and "ﬁsh" gives "F" (decision 4).
    public static func monogram(for tab: Tab) -> String {
        let host = HostText.host(of: tab.url).flatMap { HostText.isPunycode($0) ? nil : $0 }
        let source = (host ?? tab.title).trimmingCharacters(in: .whitespacesAndNewlines)
        guard let first = source.uppercased().first else { return "?" }
        return String(first)
    }
}

/// Where a workspace's stored `icon` string points: an emoji, or an SF Symbol name (the view falls back to `square.grid.2x2` when the name is unknown).
public enum WorkspaceIcon: Equatable, Sendable {
    case emoji(String), symbol(String)

    public static let fallbackSymbol = "square.grid.2x2"

    public init(stored: String) {
        if stored.isEmpty {
            self = .symbol(Self.fallbackSymbol)
        } else if stored.unicodeScalars.contains(where: { !$0.isASCII }) {
            self = .emoji(stored)
        } else {
            self = .symbol(stored)
        }
    }
}
