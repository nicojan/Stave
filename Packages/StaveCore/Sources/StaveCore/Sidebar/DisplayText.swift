import Foundation

/// The text the sidebar and content placeholder show for a tab or address. Pure rules; the views only place the result.
public enum DisplayText {
    /// The title, or the URL's host when the title is empty, or the URL itself.
    public static func title(for tab: Tab) -> String {
        guard tab.title.isEmpty else { return tab.title }
        if let host = URL(string: tab.url)?.host, !host.isEmpty { return host }
        return tab.url
    }

    /// The URL's host without a leading `www.`; the whole string when there is no host.
    public static func address(for url: String) -> String {
        host(of: url) ?? url
    }

    /// The first character of the host (without `www.`), else of the title, uppercased; `"?"` when both are empty.
    public static func monogram(for tab: Tab) -> String {
        let source = host(of: tab.url) ?? tab.title
        guard let first = source.first else { return "?" }
        return String(first).uppercased()
    }

    private static func host(of url: String) -> String? {
        guard let host = URL(string: url)?.host, !host.isEmpty else { return nil }
        let stripped = host.hasPrefix("www.") ? String(host.dropFirst(4)) : host
        return stripped.isEmpty ? nil : stripped
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
