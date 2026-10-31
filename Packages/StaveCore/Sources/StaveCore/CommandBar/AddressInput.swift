import Foundation

/// What typed text means. Only `http`/`https` text, or scheme-less text that looks like a host, becomes a URL;
/// every other scheme (`javascript:`, `file:`, `data:`, `about:`) and anything with whitespace is a search.
public enum AddressInput: Equatable, Sendable {
    case empty, url(String), search(String)

    public static func classify(_ text: String) -> AddressInput {
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.isEmpty { return .empty }
        if text.unicodeScalars.contains(where: { CharacterSet.whitespacesAndNewlines.contains($0) || CharacterSet.controlCharacters.contains($0) }) {
            return .search(text)
        }
        if let explicit = explicitWebURL(text) { return explicit ? .url(text) : .search(text) }
        switch bareKind(text) {
        case .localOrIP: return .url("http://" + text)
        case .host: return .url("https://" + text)
        case nil: return .search(text)
        }
    }

    /// nil when the text does not start with `http://` or `https://`; otherwise whether it has a host.
    private static func explicitWebURL(_ text: String) -> Bool? {
        let lower = text.lowercased()
        guard lower.hasPrefix("http://") || lower.hasPrefix("https://") else { return nil }
        guard let host = URL(string: text)?.host, !host.isEmpty else { return false }
        return true
    }

    private enum BareKind { case localOrIP, host }

    private static func bareKind(_ text: String) -> BareKind? {
        guard let host = bareHost(text) else { return nil }
        if host.lowercased() == "localhost" || isIPv4(host) { return .localOrIP }
        return isHostName(host) ? .host : nil
    }

    /// The host of scheme-less text: the part before the first `/`, `?` or `#`, without an optional `:port`. nil for `@` or a bad port.
    private static func bareHost(_ text: String) -> String? {
        let authority = text.prefix { !"/?#".contains($0) }
        guard !authority.contains("@") else { return nil }
        guard let colon = authority.lastIndex(of: ":") else { return String(authority) }
        let port = authority[authority.index(after: colon)...]
        guard (1...5).contains(port.count), port.allSatisfy({ $0.isASCII && $0.isNumber }) else { return nil }
        return String(authority[..<colon])
    }

    private static func isIPv4(_ host: String) -> Bool {
        let octets = host.split(separator: ".", omittingEmptySubsequences: false)
        return octets.count == 4 && octets.allSatisfy { octet in
            (1...3).contains(octet.count) && !(octet.count > 1 && octet.hasPrefix("0")) && octet.allSatisfy { $0.isASCII && $0.isNumber } && Int(octet).map { $0 <= 255 } == true
        }
    }

    private static func isHostName(_ host: String) -> Bool {
        let labels = host.split(separator: ".", omittingEmptySubsequences: false)
        guard labels.count >= 2, let last = labels.last else { return false }
        guard last.count >= 2, last.allSatisfy({ $0.isASCII && $0.isLetter }) else { return false }
        return labels.allSatisfy { label in
            !label.isEmpty && label.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-") }
        }
    }
}
