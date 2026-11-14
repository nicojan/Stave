import Foundation

/// The one host rule for every place that shows or keys a host (plan 5 decision 3): the address field, monograms and
/// site keys (`SiteHost`). A hand parser, not `URL(string:)`, whose handling differs by OS version.
public enum HostText {
    /// The host of a web URL (`http`/`https`) or of a bare host (`example.com`, `www.example.org:8080`): lowercased,
    /// port and user info dropped, an IPv6 host kept in brackets, one leading `www.` stripped. IDN hosts stay punycode.
    /// Nil for a non-web URL (`file:`, `about:`, `mailto:`, `data:`, …) or when nothing is left.
    public static func host(of url: String) -> String? {
        guard let authority = authority(of: url) else { return nil }
        guard let host = hostPart(of: authority) else { return nil }
        var result = host.lowercased()
        if result.hasPrefix("www.") { result.removeFirst(4) }
        return result.isEmpty ? nil : result
    }

    /// Whether the host's first label is punycode (`xn--`, any case). Only the first label decides, so
    /// `shop.xn--bcher-kva.example` is not punycode for the monogram (plan 5 question 4).
    public static func isPunycode(_ host: String) -> Bool {
        let firstLabel = host.prefix { $0 != "." }
        return firstLabel.lowercased().hasPrefix("xn--")
    }

    /// The text between `://` (or the start, for a bare host) and the first `/`, `?` or `#`; nil for a non-web address.
    private static func authority(of url: String) -> Substring? {
        var text = Substring(url)
        if text.contains("://") {
            guard URLScheme.hasWebAuthority(url), let colon = text.firstIndex(of: ":") else { return nil }
            text = text[text.index(colon, offsetBy: 3)...]
        } else if let colon = text.firstIndex(of: ":"), URLScheme.scheme(of: url) != nil {
            // "mailto:x" and "data:..." are non-web; "example.com:8443" is a bare host with a port.
            let afterColon = text[text.index(after: colon)...].prefix { $0 != "/" && $0 != "?" && $0 != "#" }
            guard !afterColon.isEmpty, afterColon.allSatisfy(\.isASCII), afterColon.allSatisfy(\.isNumber) else { return nil }
        }
        return text.prefix { $0 != "/" && $0 != "?" && $0 != "#" }
    }

    /// The host within an authority: after the last `@`, without the port, an IPv6 literal kept with its brackets.
    private static func hostPart(of authority: Substring) -> Substring? {
        var host = authority
        if let at = host.lastIndex(of: "@") { host = host[host.index(after: at)...] }
        if host.hasPrefix("[") {
            guard let close = host.firstIndex(of: "]") else { return nil }
            return host[host.startIndex...close]
        }
        if let colon = host.firstIndex(of: ":") { return host[host.startIndex..<colon] }
        return host
    }
}
