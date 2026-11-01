/// Reads the scheme of an address without `URL(string:)`, whose handling of spaces and non-ASCII differs by OS version.
public enum URLScheme {
    /// The text before the first ":" when it is a syntactically valid RFC 3986 scheme, lowercased; otherwise nil.
    public static func scheme(of text: String) -> String? {
        guard let colon = text.firstIndex(of: ":") else { return nil }
        let prefix = text[text.startIndex..<colon]
        guard let first = prefix.unicodeScalars.first, isASCIILetter(first) else { return nil }
        let valid = prefix.unicodeScalars.allSatisfy { isASCIILetter($0) || ("0"..."9").contains($0) || "+-.".unicodeScalars.contains($0) }
        return valid ? prefix.lowercased() : nil
    }

    /// http or https, then "//" and a non-empty authority (up to the first "/", "?" or "#").
    public static func hasWebAuthority(_ text: String) -> Bool {
        guard let scheme = scheme(of: text), scheme == "http" || scheme == "https" else { return false }
        let rest = text.dropFirst(scheme.count + 1)
        guard rest.hasPrefix("//") else { return false }
        let authority = rest.dropFirst(2).prefix { $0 != "/" && $0 != "?" && $0 != "#" }
        return !authority.isEmpty
    }

    private static func isASCIILetter(_ scalar: Unicode.Scalar) -> Bool {
        ("a"..."z").contains(scalar) || ("A"..."Z").contains(scalar)
    }
}
