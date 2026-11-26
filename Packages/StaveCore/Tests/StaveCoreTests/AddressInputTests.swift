import Testing
@testable import StaveCore

struct AddressInputTests {
    @Test func bareHostGetsHttps() {
        #expect(AddressInput.classify("example.com") == .url("https://example.com"))
        #expect(AddressInput.classify("Example.com/a?b=1") == .url("https://Example.com/a?b=1"))
        #expect(AddressInput.classify("example.com:8080/x") == .url("https://example.com:8080/x"))
    }

    @Test func httpSchemeIsKeptWhateverTheCase() {
        #expect(AddressInput.classify("HTTP://example.org") == .url("HTTP://example.org"))
        #expect(AddressInput.classify("https://example.org/a b") == .search("https://example.org/a b"))
        #expect(AddressInput.classify("https://") == .search("https://"))
    }

    @Test func localhostAndIPv4GetHttp() {
        #expect(AddressInput.classify("localhost:3000/x") == .url("http://localhost:3000/x"))
        #expect(AddressInput.classify("localhost") == .url("http://localhost"))
        #expect(AddressInput.classify("192.168.1.10") == .url("http://192.168.1.10"))
        #expect(AddressInput.classify("192.168.1.10:80/a") == .url("http://192.168.1.10:80/a"))
        #expect(AddressInput.classify("256.1.1.1") == .search("256.1.1.1"))
    }

    @Test func otherTextIsASearch() {
        for text in ["foo bar", "a.b", "1.5", "user@example.com", "example.com@evil.example.net", "exa", "example.com:abc", "bücher.example"] {
            #expect(AddressInput.classify(text) == .search(text), "\(text)")
        }
    }

    @Test func blankIsEmpty() {
        #expect(AddressInput.classify("   ") == .empty)
        #expect(AddressInput.classify("") == .empty)
        #expect(AddressInput.classify("  example.com \n") == .url("https://example.com"))
    }

    @Test func nonWebSchemesBecomeSearches() {
        for text in ["javascript:alert(1)", "JavaScript:void(0)", "file:///etc/hosts", "data:text/html,x", "about:blank", "ftp://example.com", "javascript.example.com:1/x y"] {
            #expect(AddressInput.classify(text) == .search(text), "\(text)")
        }
    }

    @Test func trickyShapesBecomeSearches() {
        let shapes = [
            "example.com\tx", "example.com\nx", "exa\u{200B}mple.com", "http:javascript:alert(1)", "https:example.com",
            "//example.com", "example.com:80@evil.example", "example\u{3002}com", "example\u{FF0E}com",
        ]
        for text in shapes { #expect(AddressInput.classify(text) == .search(text), "\(text.debugDescription)") }
        #expect(AddressInput.classify("  example.com\tx\n") == .search("example.com\tx"))
    }

    @Test func ipv4WithLeadingZerosIsASearch() {
        #expect(AddressInput.classify("192.168.001.010") == .search("192.168.001.010"))
        #expect(AddressInput.classify("10.0.0.1") == .url("http://10.0.0.1"))
    }

    // MARK: Typed links for other apps (plan 5, Task 15)

    /// A typed `mailto:` or `tel:` is a link to hand to another app, as in Safari: it reaches the policy as `.typed`, which asks.
    @Test func typedMailtoAsks() {
        #expect(AddressInput.classify("mailto:a@example.com") == .externalLink("mailto:a@example.com"))
        #expect(AddressInput.classify("  MAILTO:a@example.com?subject=Hi  ") == .externalLink("MAILTO:a@example.com?subject=Hi"))
        #expect(AddressInput.classify("tel:+15551234567") == .externalLink("tel:+15551234567"))
        #expect(AddressInput.classify("Tel:5551234") == .externalLink("Tel:5551234"))
        // The policy turns it into the external-app question.
        #expect(NavigationPolicy.decide("mailto:a@example.com", isMainFrame: true, source: .typed) == .askToOpenExternally("mailto:a@example.com"))
        #expect(NavigationPolicy.decide("tel:5551234", isMainFrame: true, source: .typed) == .askToOpenExternally("tel:5551234"))
    }

    /// Everything else with a scheme stays a search (plan 4 Review Focus 1), and a malformed mailto: or tel: is one too.
    @Test func otherTypedSchemesStayASearch() {
        let searches = ["mailto:", "tel:", "mailto: a@example.com", "mailto:a b", "sms:5551234", "zoommtg://x", "mailto\u{200B}:a@example.com", "mailto:a@example.com\u{0007}"]
        for text in searches { #expect(AddressInput.classify(text) == .search(text), "\(text.debugDescription)") }
        #expect(AddressInput.classify("javascript:alert(1)") == .search("javascript:alert(1)"))
        #expect(AddressInput.classify("data:text/html,x") == .search("data:text/html,x"))
    }

    /// A typed link over the length cap that links from other apps use is a search, never handed over.
    @Test func overLongTypedMailtoIsASearch() {
        let long = "mailto:" + String(repeating: "a", count: ExternalOpen.maximumURLLength)
        #expect(AddressInput.classify(long) == .search(long))
    }

    @Test func externalLinkIsNeverStoredAsATabAddress() {
        #expect(AddressInput.isExternalLink("mailto:a@example.com"))
        #expect(AddressInput.isExternalLink("TEL:5551234"))
        #expect(!AddressInput.isExternalLink("https://example.com"))
        #expect(!AddressInput.isExternalLink("zoommtg://x"))
    }
}
