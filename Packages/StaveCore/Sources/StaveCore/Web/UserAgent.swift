import Foundation

/// What a site is told the browser is (plan 5, decision 24): Stave's own string, Safari's, or Chrome's on a Mac. Stored as the `userAgent`
/// site value; the default stores nothing, like zoom at 100 %.
public enum SiteUserAgent: String, Codable, CaseIterable, Sendable {
    case standard, safari, chrome

    /// The row's option and Settings ▸ Websites word: "Default", "Safari", "Chrome on Mac".
    public var title: String {
        switch self {
        case .standard: "Default"
        case .safari: "Safari"
        case .chrome: "Chrome on Mac"
        }
    }

    /// What is stored: nil (no row) for the default.
    public var storedValue: String? { self == .standard ? nil : rawValue }

    /// Reads a stored value; none, or text no agent has (a hostile or older row), is the default.
    public init(stored: String?) {
        self = stored.flatMap(SiteUserAgent.init(rawValue:)) ?? .standard
    }
}

public enum UserAgent {
    private static let fallbackVersion = "17.0"

    /// A Chrome major version and the day it reached stable (8 September 2026, Chrome 153, the first on the 14-day stable cycle): the
    /// anchor `chromeMajorVersion(on:)` counts from. Chrome 157 (3 November 2026) fits it. Moving the anchor forward is optional upkeep.
    public static let chromeAnchorVersion = 153
    public static let chromeAnchorDate = Date(timeIntervalSince1970: 1_788_825_600)
    /// Days between Chrome majors since 153 (a 14-day stable cycle). If Chrome slows again this runs ahead; re-check on the release checklist.
    public static let chromeCycleDays = 14

    /// The Chrome major version for a day: the anchor plus one per cycle since it, so the string doesn't go stale as releases ship.
    /// Never below the anchor (a day before it, such as a test clock, gets the anchor's version).
    public static func chromeMajorVersion(on date: Date) -> Int {
        let days = Int(date.timeIntervalSince(chromeAnchorDate) / 86_400)
        return chromeAnchorVersion + max(0, days) / chromeCycleDays
    }

    /// The "Version/x Safari/y" application name, so sites see the system Safari. Only the leading run of digits and dots of the version is
    /// kept, and it must start with a digit (a version of only dots falls back).
    public static func applicationName(safariVersion: String?) -> String {
        let run = String((safariVersion ?? "").prefix { $0.isASCII && ($0.isNumber || $0 == ".") })
        let usable = run.first?.isNumber == true
        return "Version/\(usable ? run : fallbackVersion) Safari/605.1.15"
    }

    /// The `customUserAgent` for an agent; nil for the default, which keeps WebKit's own string with Stave's application name.
    public static func string(for agent: SiteUserAgent, safariVersion: String?, now: Date = Date()) -> String? {
        string(for: agent, applicationName: applicationName(safariVersion: safariVersion), now: now)
    }

    /// The same, from the application name the pages were made with (`applicationName(safariVersion:)`).
    public static func string(for agent: SiteUserAgent, applicationName: String, now: Date = Date()) -> String? {
        let platform = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7)"
        switch agent {
        case .standard: return nil
        case .safari: return "\(platform) AppleWebKit/605.1.15 (KHTML, like Gecko) \(applicationName)"
        case .chrome: return "\(platform) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/\(chromeMajorVersion(on: now)).0.0.0 Safari/537.36"
        }
    }
}
