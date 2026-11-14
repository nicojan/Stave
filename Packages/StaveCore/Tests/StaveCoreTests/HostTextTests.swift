import Foundation
import Testing
@testable import StaveCore

/// Plan 5 decisions 3 and 4: one host rule for display and site keys, and one-letter monograms.
struct HostTextTests {
    private func tab(url: String = "", title: String = "") -> Tab {
        Tab(slotID: UUID(), url: url, title: title)
    }

    @Test func hostRule() {
        #expect(HostText.host(of: "https://WWW.Example.com:8443/a?q#f") == "example.com")
        #expect(HostText.host(of: "http://user:pw@Example.NET/p") == "example.net")
        #expect(HostText.host(of: "https://example.com@example.net/x") == "example.net")
        #expect(HostText.host(of: "http://[::1]:8080/") == "[::1]")
        #expect(HostText.host(of: "https://[2001:DB8::1]/") == "[2001:db8::1]")
        #expect(HostText.host(of: "https://www.www.example.org/") == "www.example.org") // stripped once
        #expect(HostText.host(of: "https://xn--bcher-kva.example/") == "xn--bcher-kva.example")
        #expect(HostText.host(of: "EXAMPLE.org") == "example.org")
        #expect(HostText.host(of: "www.example.org:8080") == "example.org")
        #expect(HostText.host(of: "https://www./") == nil)
        #expect(HostText.host(of: "https:///x") == nil)
        #expect(HostText.host(of: "http://[::1/") == nil)
        #expect(HostText.host(of: "") == nil)
        for nonWeb in ["file:///etc/hosts", "about:blank", "mailto:a@example.com", "data:text/html,x", "javascript:alert(1)", "ftp://example.com/"] {
            #expect(HostText.host(of: nonWeb) == nil, "\(nonWeb)")
        }
    }

    @Test func punycodeIsTheFirstLabel() {
        #expect(HostText.isPunycode("xn--bcher-kva.example"))
        #expect(HostText.isPunycode("XN--bcher-kva.example"))
        #expect(!HostText.isPunycode("shop.xn--bcher-kva.example"))
        #expect(!HostText.isPunycode("example.xn--p1ai"))
        #expect(!HostText.isPunycode("example.com"))
        #expect(!HostText.isPunycode(""))
    }

    @Test func uppercaseWWWIsStripped() {
        #expect(DisplayText.address(for: "https://WWW.Example.com/a") == "example.com")
        #expect(DisplayText.monogram(for: tab(url: "https://WWW.Example.com/a")) == "E")
    }

    @Test func monogramIsOneCharacter() {
        #expect(DisplayText.monogram(for: tab(title: "ßeta")) == "S")
        #expect(DisplayText.monogram(for: tab(title: "ﬁsh")) == "F")
    }

    @Test func monogramSkipsLeadingWhitespace() {
        #expect(DisplayText.monogram(for: tab(title: "  lead")) == "L")
        #expect(DisplayText.monogram(for: tab(title: "\n\tlead")) == "L")
        #expect(DisplayText.monogram(for: tab(title: "   ")) == "?")
    }

    @Test func punycodeMonogramUsesTitle() {
        #expect(DisplayText.monogram(for: tab(url: "https://xn--bcher-kva.example", title: "Bücher")) == "B")
        #expect(DisplayText.address(for: "https://xn--bcher-kva.example") == "xn--bcher-kva.example")
        #expect(DisplayText.monogram(for: tab(url: "https://xn--bcher-kva.example", title: "")) == "?")
        #expect(DisplayText.monogram(for: tab(url: "https://xn--bcher-kva.example", title: "  ")) == "?")
        // Only the first label decides (decision 3, question 4): a later punycode label keeps the host's letter.
        #expect(DisplayText.monogram(for: tab(url: "https://shop.xn--bcher-kva.example", title: "Zed")) == "S")
    }
}
