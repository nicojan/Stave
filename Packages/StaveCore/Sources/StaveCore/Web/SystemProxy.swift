import Foundation

/// Which hosts the system's proxy settings name (`CFNetworkCopySystemProxySettings`), so a proxy's sign-in challenge is trusted only when the
/// proxy is one the user's Mac is set to use. A pure function of the settings dictionary.
public enum SystemProxy {
    /// `kCFNetworkProxiesHTTPProxy`, `kCFNetworkProxiesHTTPEnable`, `kCFNetworkProxiesHTTPSProxy`, `kCFNetworkProxiesHTTPSEnable`.
    private static let pairs = [("HTTPProxy", "HTTPEnable"), ("HTTPSProxy", "HTTPSEnable")]

    /// The enabled HTTP and HTTPS proxy hosts, lowercased and IPv6 bracketed.
    public static func hosts(in settings: [String: Any]?) -> Set<String> {
        guard let settings else { return [] }
        var found: Set<String> = []
        for (proxyKey, enableKey) in pairs {
            guard let host = settings[proxyKey] as? String, (settings[enableKey] as? NSNumber)?.intValue ?? 0 != 0 else { continue }
            let key = Self.hostKey(host)
            if !key.isEmpty { found.insert(key) }
        }
        return found
    }

    /// `kCFNetworkProxiesProxyAutoConfigEnable` and `kCFNetworkProxiesProxyAutoDiscoveryEnable`.
    private static let autoKeys = ["ProxyAutoConfigEnable", "ProxyAutoDiscoveryEnable"]

    /// A PAC file or WPAD is on, so the proxy that asks can't be told from the settings.
    public static func usesAutoConfiguration(in settings: [String: Any]?) -> Bool {
        guard let settings else { return false }
        return autoKeys.contains { (settings[$0] as? NSNumber)?.intValue ?? 0 != 0 }
    }

    /// True for a named proxy, and for any host while a PAC file or WPAD is on.
    public static func isProxyHost(_ host: String, in settings: [String: Any]?) -> Bool {
        usesAutoConfiguration(in: settings) || hosts(in: settings).contains(hostKey(host))
    }

    /// Lowercased, trimmed, an IPv6 host in brackets (`::1` and `[::1]` are the same host).
    public static func hostKey(_ host: String) -> String {
        let lowered = host.trimmingCharacters(in: .whitespaces).lowercased()
        return lowered.contains(":") && !lowered.hasPrefix("[") ? "[\(lowered)]" : lowered
    }
}
