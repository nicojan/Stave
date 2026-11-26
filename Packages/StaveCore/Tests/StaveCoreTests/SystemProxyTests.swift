import Foundation
import Testing

@testable import StaveCore

@Suite("System proxy hosts")
struct SystemProxyTests {
    private let settings: [String: Any] = [
        "HTTPProxy": "Proxy.Example.net", "HTTPEnable": 1, "HTTPPort": 8080,
        "HTTPSProxy": "secure.example.net", "HTTPSEnable": 1,
        "SOCKSProxy": "socks.example.net", "SOCKSEnable": 1,
    ]

    @Test func enabledHTTPAndHTTPSProxiesMatch() {
        #expect(SystemProxy.isProxyHost("proxy.example.net", in: settings))
        #expect(SystemProxy.isProxyHost("SECURE.example.net", in: settings))
        #expect(!SystemProxy.isProxyHost("example.net", in: settings))
        #expect(!SystemProxy.isProxyHost("socks.example.net", in: settings))
    }

    @Test func disabledOrMissingProxiesDoNotMatch() {
        let off: [String: Any] = ["HTTPProxy": "proxy.example.net", "HTTPEnable": 0, "HTTPSProxy": "secure.example.net"]
        #expect(!SystemProxy.isProxyHost("proxy.example.net", in: off))
        #expect(!SystemProxy.isProxyHost("secure.example.net", in: off))
        #expect(!SystemProxy.isProxyHost("proxy.example.net", in: [:]))
        #expect(!SystemProxy.isProxyHost("proxy.example.net", in: nil))
        #expect(!SystemProxy.isProxyHost("", in: ["HTTPProxy": "", "HTTPEnable": 1]))
    }

    @Test func wrongTypesAreIgnored() {
        #expect(SystemProxy.hosts(in: ["HTTPProxy": 5, "HTTPEnable": 1]).isEmpty)
        #expect(SystemProxy.hosts(in: ["HTTPProxy": "proxy.example.net", "HTTPEnable": "yes"]).isEmpty)
    }

    /// A PAC file or WPAD hides the proxy's name from the settings: every proxy challenge is accepted then.
    @Test func pacAloneAcceptsAnyProxy() {
        let pac: [String: Any] = ["ProxyAutoConfigEnable": 1, "ProxyAutoConfigURLString": "http://pac.example.net/proxy.pac"]
        #expect(SystemProxy.hosts(in: pac).isEmpty)
        #expect(SystemProxy.usesAutoConfiguration(in: pac))
        #expect(SystemProxy.isProxyHost("anything.example.net", in: pac))
        #expect(SystemProxy.isProxyHost("::1", in: pac))
    }

    @Test func wpadAloneAcceptsAnyProxy() {
        let wpad: [String: Any] = ["ProxyAutoDiscoveryEnable": 1]
        #expect(SystemProxy.hosts(in: wpad).isEmpty)
        #expect(SystemProxy.usesAutoConfiguration(in: wpad))
        #expect(SystemProxy.isProxyHost("anything.example.net", in: wpad))
    }

    @Test func autoConfigurationSwitchedOffAcceptsNothing() {
        let off: [String: Any] = ["ProxyAutoConfigEnable": 0, "ProxyAutoDiscoveryEnable": 0, "ProxyAutoConfigURLString": "http://pac.example.net/proxy.pac"]
        #expect(!SystemProxy.usesAutoConfiguration(in: off))
        #expect(!SystemProxy.isProxyHost("anything.example.net", in: off))
        #expect(!SystemProxy.usesAutoConfiguration(in: nil))
        #expect(!SystemProxy.usesAutoConfiguration(in: ["ProxyAutoConfigEnable": "yes"]))
    }

    @Test func ipv6ProxyMatchesWithOrWithoutBrackets() {
        let v6: [String: Any] = ["HTTPProxy": "::1", "HTTPEnable": 1]
        #expect(SystemProxy.isProxyHost("[::1]", in: v6))
        #expect(SystemProxy.isProxyHost("::1", in: v6))
    }
}
