import Foundation
import Testing

@testable import StaveCore

@Suite("HTTP auth challenge text and handling")
struct AuthChallengeTests {
    @Test func titleNamesTheHost() {
        #expect(AuthText.title(for: AuthChallenge(host: "example.org")) == "example.org wants you to sign in")
    }

    @Test func proxyTitleSaysSo() {
        #expect(AuthText.title(for: AuthChallenge(host: "proxy.example.net", isProxy: true)) == "The proxy proxy.example.net wants you to sign in")
    }

    /// A sign-in sheet names the exact server (Chrome does), so `www.` and a non-default port stay, unlike `HostText`.
    @Test func authKeepsWWWAndPort() {
        #expect(AuthChallenge.hostLabel(host: "WWW.Example.com", port: 8443, scheme: "https") == "www.example.com:8443")
        #expect(AuthChallenge.hostLabel(host: "www.example.com", port: 443, scheme: "https") == "www.example.com")
        #expect(AuthChallenge.hostLabel(host: "example.com", port: 80, scheme: "http") == "example.com")
        #expect(AuthChallenge.hostLabel(host: "example.com", port: 8080, scheme: "http") == "example.com:8080")
        // 443 is not http's default port, and a port of 0 means WebKit gave none.
        #expect(AuthChallenge.hostLabel(host: "example.com", port: 443, scheme: "http") == "example.com:443")
        #expect(AuthChallenge.hostLabel(host: "example.com", port: 0, scheme: "https") == "example.com")
        #expect(AuthChallenge.hostLabel(host: "::1", port: 8080, scheme: "http") == "[::1]:8080")
    }

    @Test func realmIsShownInQuotes() {
        #expect(AuthText.detail(for: AuthChallenge(host: "example.org", realm: "test")) == "“test”")
    }

    @Test func noRealmNoFailureSaysNothing() {
        #expect(AuthText.detail(for: AuthChallenge(host: "example.org")) == "")
        #expect(AuthText.detail(for: AuthChallenge(host: "example.org", realm: "  \n ")) == "")
    }

    @Test func realmIsCapped() {
        let detail = AuthText.detail(for: AuthChallenge(host: "example.org", realm: String(repeating: "a", count: 5_000)))
        #expect(detail == "“" + String(repeating: "a", count: AuthText.realmLimit) + "…”")
    }

    /// The realm is the site's own words: line breaks and runs of spaces can't lay out a fake message of the site's choosing.
    @Test func realmIsOneLine() {
        let detail = AuthText.detail(for: AuthChallenge(host: "example.org", realm: "Staff\n\nArea   two"))
        #expect(detail == "“Staff Area two”")
    }

    @Test func failureCountShowsRetryText() {
        let retry = AuthText.detail(for: AuthChallenge(host: "example.org", realm: "test", previousFailureCount: 1))
        #expect(retry == "Your user name or password was wrong.\n“test”")
        #expect(AuthText.detail(for: AuthChallenge(host: "example.org", previousFailureCount: 2)) == "Your user name or password was wrong.")
        #expect(!AuthText.detail(for: AuthChallenge(host: "example.org", realm: "test", previousFailureCount: 0)).contains("wrong"))
    }

    @Test func labels() {
        #expect(AuthText.userNameLabel == "User Name")
        #expect(AuthText.passwordLabel == "Password")
        #expect(AuthText.signInButton == "Sign In")
        #expect(AuthText.cancelButton == "Cancel")
    }

    @Test func digestAndNTLMAsk() {
        #expect(AuthChallenge.handling(method: NSURLAuthenticationMethodHTTPBasic) == .ask)
        #expect(AuthChallenge.handling(method: NSURLAuthenticationMethodHTTPDigest) == .ask)
        #expect(AuthChallenge.handling(method: NSURLAuthenticationMethodNTLM) == .ask)
    }

    /// WebKit continues without a certificate, as Safari and Chrome do when no identity exists (plan 3 did the same).
    @Test func clientCertificateContinuesWithoutOne() {
        #expect(AuthChallenge.handling(method: NSURLAuthenticationMethodClientCertificate) == .defaultHandling)
    }

    @Test func defaultMethodAsks() {
        #expect(AuthChallenge.handling(method: NSURLAuthenticationMethodDefault) == .ask)
    }

    /// A right-to-left override would make the realm read backwards, or reorder the host beside it.
    @Test func realmWithRightToLeftOverrideIsCleaned() {
        let realm = "Admin\u{202E}gpj.exe\u{202C}\u{2066}x\u{2069}\u{200E}\u{200F}\u{200B}\u{FEFF}"
        #expect(AuthText.cleanRealm(realm) == "Admingpj.exex")
        #expect(AuthText.cleanRealm("a\u{0000}b\u{0007}c") == "abc")
        #expect(AuthText.detail(for: AuthChallenge(host: "example.org", realm: realm)) == "“Admingpj.exex”")
    }

    /// A realm can't close Stave's quotes and put words outside them.
    @Test func realmWithQuotesCannotCloseTheQuotes() {
        let detail = AuthText.detail(for: AuthChallenge(host: "example.org", realm: "x” Enter your bank password “y \"z\" «w»"))
        #expect(detail == "“x' Enter your bank password 'y 'z' 'w'”")
        #expect(!AuthText.cleanRealm("\"“”„‟«»")!.contains { "\"“”„‟«»".contains($0) })
    }

    /// Item 6: primes, ornament quotes and every other scalar with the Quotation_Mark property can't stand in for Stave's closing quote.
    @Test func realmWithQuoteLookAlikesCannotCloseTheQuotes() {
        let detail = AuthText.detail(for: AuthChallenge(host: "example.org", realm: "x\u{2033} Enter your password \u{2036}y"))
        #expect(detail == "“x' Enter your password 'y”")
        let lookAlikes = "\u{2033}\u{2036}\u{02EE}\u{FF02}\u{301D}\u{301E}\u{301F}\u{275D}\u{275E}\u{2018}\u{2019}\u{2039}\u{203A}\u{300C}\u{300D}\u{FF07}\u{201A}\u{201B}"
        let cleaned = AuthText.cleanRealm(lookAlikes) ?? ""
        #expect(!cleaned.isEmpty)
        #expect(cleaned.unicodeScalars.allSatisfy { $0 == "'" })
        #expect(cleaned.count == lookAlikes.unicodeScalars.count)
        // Every scalar the Unicode Quotation_Mark property covers is neutralised, not only the ones listed above.
        for value in UInt32(0)...0xFFFF {
            guard let scalar = Unicode.Scalar(value), scalar.properties.isQuotationMark else { continue }
            #expect(AuthText.cleanRealm("a\(scalar)b") == "a'b", "U+\(String(value, radix: 16)) was kept")
        }
    }

    /// One character can carry any number of combining marks: the scalar cap stops that, and the character cap stops the long text.
    @Test func realmWithStackedMarksIsCapped() {
        let stacked = "a" + String(repeating: "\u{0301}", count: 5_000)
        let cleaned = AuthText.cleanRealm(stacked)
        #expect(cleaned == "…")
        let many = String(repeating: "e\u{0301}\u{0302}\u{0303}", count: 300)
        let capped = AuthText.cleanRealm(many) ?? ""
        #expect(capped.unicodeScalars.count <= AuthText.realmScalarLimit + 1)
        #expect(capped.hasSuffix("…"))
        #expect(capped.count <= AuthText.realmLimit + 1)
        // Two plain characters, then one with 399 marks: 2 + 400 scalars is over the cap, so it is dropped whole, never split.
        let overByOne = AuthText.cleanRealm("ab" + "c" + String(repeating: "\u{0301}", count: 399))
        #expect(overByOne == "ab…")
        let exactly = "ab" + "c" + String(repeating: "\u{0301}", count: 397)
        #expect(AuthText.cleanRealm(exactly) == exactly)
    }

    @Test func authAnswerNeverPrintsThePassword() {
        let answer = AuthAnswer(user: "ann", password: "hunter2-secret")
        var dumped = ""
        dump(answer, to: &dumped)
        let texts = ["\(answer)", String(describing: answer), String(reflecting: answer), dumped, "\(Mirror(reflecting: answer).children.map { "\($0.value)" })"]
        for text in texts {
            #expect(!text.contains("hunter2-secret"), "\(text)")
        }
        #expect(String(describing: answer).contains("ann"))
        #expect(answer.password == "hunter2-secret")
    }

    /// Once Stave answers every challenge, a server-trust challenge that isn't passed on would fail every HTTPS load.
    @Test func negotiateAndServerTrustUseDefaultHandling() {
        for method in [NSURLAuthenticationMethodServerTrust, NSURLAuthenticationMethodNegotiate, NSURLAuthenticationMethodHTMLForm, "NSURLAuthenticationMethodSomethingNew", ""] {
            #expect(AuthChallenge.handling(method: method) == .defaultHandling, "\(method)")
        }
    }
}
