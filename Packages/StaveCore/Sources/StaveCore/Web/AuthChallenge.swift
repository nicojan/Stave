import Foundation

/// What Stave does with an HTTP authentication challenge, by its method.
public enum AuthHandling: Equatable, Sendable {
    /// Basic, Digest, NTLM and the default method: the user is asked for a name and password.
    case ask
    /// Server trust, Negotiate, a client-certificate request and anything else: WebKit's own handling (`.performDefaultHandling`), so its
    /// certificate evaluation, and the certificate-error panel, are unchanged by Stave answering challenges at all. A client-certificate
    /// request continues without a certificate, as in Safari and Chrome when no identity exists (plan 3 did the same).
    case defaultHandling
}

/// What the user typed into the sign-in sheet. Held only until it is handed to WebKit; Stave stores nothing.
/// Printing it, in any form, never shows the password.
public struct AuthAnswer: Equatable, Sendable, CustomStringConvertible, CustomDebugStringConvertible, CustomReflectable {
    public let user: String
    public let password: String

    public init(user: String, password: String) {
        self.user = user
        self.password = password
    }

    public static let redacted = "<redacted>"
    public var description: String { "AuthAnswer(user: \(user), password: \(Self.redacted))" }
    public var debugDescription: String { description }
    public var customMirror: Mirror { Mirror(self, children: ["user": user, "password": Self.redacted], displayStyle: .struct) }
}

/// How an asked sign-in question ended, when it ended by something the user did. A question that the system drops (its tab went away, its
/// page navigated, a failed load) has no reply at all: nil. Only the user's Cancel counts toward `AuthQuestionGate.cancelLimit`.
public enum AuthReply: Equatable, Sendable {
    case signedIn(AuthAnswer)
    /// The user pressed Cancel.
    case cancelled
}

/// An HTTP authentication challenge as the sheet shows it. Data from the network: the realm is the site's own words.
public struct AuthChallenge: Equatable, Sendable {
    /// The server that asks, exactly (`hostLabel`): never the top page's host unless that server is the one asking.
    public let host: String
    public let realm: String?
    public let isProxy: Bool
    public let previousFailureCount: Int

    public init(host: String, realm: String? = nil, isProxy: Bool = false, previousFailureCount: Int = 0) {
        self.host = host
        self.realm = realm
        self.isProxy = isProxy
        self.previousFailureCount = previousFailureCount
    }

    /// The site this challenge's server belongs to, as `HostText` keys a host (no port, no `www.`, no brackets): what a failed navigation to
    /// that site cancels.
    public var siteKey: String {
        Self.siteKey(host: host)
    }

    public static func siteKey(host: String) -> String {
        SiteHost.normalized(host) ?? host.lowercased()
    }

    /// What `URLProtectionSpace` says, as a name: lowercased, with `:port` when the port isn't the scheme's default, and an IPv6 host in
    /// brackets. Not `HostText`: a sign-in sheet names the exact server, so `www.` and the port stay (Chrome's credential prompt does too).
    public static func hostLabel(host: String, port: Int, scheme: String?) -> String {
        let lowered = host.lowercased()
        let name = lowered.contains(":") && !lowered.hasPrefix("[") ? "[\(lowered)]" : lowered
        let defaultPort: Int? = switch scheme?.lowercased() {
        case "http": 80
        case "https": 443
        default: nil
        }
        guard port > 0, port != defaultPort else { return name }
        return "\(name):\(port)"
    }

    public static func handling(method: String) -> AuthHandling {
        switch method {
        case NSURLAuthenticationMethodHTTPBasic, NSURLAuthenticationMethodHTTPDigest, NSURLAuthenticationMethodNTLM, NSURLAuthenticationMethodDefault: .ask
        default: .defaultHandling
        }
    }
}

/// The sign-in sheet's words.
public enum AuthText {
    /// The realm is cut to this many characters, and to `realmScalarLimit` Unicode scalars, then an ellipsis.
    public static let realmLimit = 200
    public static let realmScalarLimit = 400
    public static let retry = "Your user name or password was wrong."
    public static let userNameLabel = "User Name"
    public static let passwordLabel = "Password"
    public static let signInButton = "Sign In"
    public static let cancelButton = "Cancel"

    public static func title(for challenge: AuthChallenge) -> String {
        challenge.isProxy ? "The proxy \(challenge.host) wants you to sign in" : "\(challenge.host) wants you to sign in"
    }

    /// After a failed try, the retry line; then the realm in quotes (`cleanRealm`). Empty when there is neither.
    public static func detail(for challenge: AuthChallenge) -> String {
        var lines: [String] = []
        if challenge.previousFailureCount > 0 { lines.append(retry) }
        if let realm = cleanRealm(challenge.realm), !realm.isEmpty { lines.append("“\(realm)”") }
        return lines.joined(separator: "\n")
    }

    /// Look-alikes of a double quote that the Unicode Quotation_Mark property misses (primes, ornaments, a modifier letter).
    private static let extraQuotes: Set<Unicode.Scalar> = ["\u{2033}", "\u{2036}", "\u{02EE}", "\u{FF02}", "\u{301D}", "\u{301E}", "\u{301F}", "\u{275D}", "\u{275E}"]

    /// Every scalar with the Quotation_Mark property, and the look-alikes the property misses.
    static func isQuoteLookAlike(_ scalar: Unicode.Scalar) -> Bool {
        scalar.properties.isQuotationMark || extraQuotes.contains(scalar)
    }

    /// The realm is the site's own words, shown inside Stave's own quotes: whitespace and line breaks become single spaces, Unicode format
    /// characters (bidi overrides, zero-width characters) and other control characters are dropped, every quote mark and look-alike (any scalar with the Quotation_Mark property, primes, corner and ornament quotes) becomes an apostrophe (so
    /// the realm can't close Stave's quotes and add words outside them), and the result is cut to `realmLimit` characters and
    /// `realmScalarLimit` scalars (a character can hold any number of combining marks), then an ellipsis. Nil for no realm.
    public static func cleanRealm(_ realm: String?) -> String? {
        guard let realm else { return nil }
        var scalars = String.UnicodeScalarView()
        for scalar in realm.unicodeScalars {
            let category = scalar.properties.generalCategory
            if scalar.properties.isWhitespace || category == .lineSeparator || category == .paragraphSeparator {
                scalars.append(" ")
            } else if category == .format || category == .control {
                continue
            } else if isQuoteLookAlike(scalar) {
                scalars.append("'")
            } else {
                scalars.append(scalar)
            }
        }
        let words = String(scalars).split(separator: " ", omittingEmptySubsequences: true).joined(separator: " ")
        var kept = ""
        var count = 0
        var scalarCount = 0
        for character in words {
            let size = character.unicodeScalars.count
            guard count < realmLimit, scalarCount + size <= realmScalarLimit else { return kept + "…" }
            kept.append(character)
            count += 1
            scalarCount += size
        }
        return kept
    }
}
