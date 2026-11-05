import Foundation
import GRDB

public enum SiteSettingKey: String, Codable, Sendable { case camera, microphone, contentBlocking }

/// For `contentBlocking`, `.deny` means blocking is off for the site.
public enum SiteDecision: String, Codable, Sendable { case allow, deny }

/// A remembered per-site choice, scoped to a profile. Not user data: removing one needs no archive.
public struct SiteSetting: Codable, FetchableRecord, PersistableRecord, Sendable, Identifiable, Equatable {
    public static let databaseTableName = "siteSetting"

    public var id: UUID
    public var profileID: UUID
    public var host: String
    public var key: SiteSettingKey
    public var decision: SiteDecision
    public var modifiedAt: Date

    public init(id: UUID = UUID(), profileID: UUID, host: String, key: SiteSettingKey, decision: SiteDecision, modifiedAt: Date = Date()) {
        self.id = id; self.profileID = profileID; self.host = host; self.key = key
        self.decision = decision; self.modifiedAt = modifiedAt
    }
}

/// The key a site's settings are stored under: the lowercased host with no port and no leading "www.".
public enum SiteHost {
    /// Accepts a web URL or a bare host. Nil for a non-web URL or an empty host.
    public static func normalized(_ urlOrHost: String) -> String? {
        var text = Substring(urlOrHost)
        if text.contains("://") {
            guard URLScheme.hasWebAuthority(urlOrHost), let colon = text.firstIndex(of: ":") else { return nil }
            text = text[text.index(colon, offsetBy: 3)...]
        } else if let colon = text.firstIndex(of: ":"), URLScheme.scheme(of: urlOrHost) != nil {
            // "mailto:x" and "data:..." are non-web; "example.com:8443" is a bare host with a port.
            let afterColon = text[text.index(after: colon)...].prefix { $0 != "/" && $0 != "?" && $0 != "#" }
            guard !afterColon.isEmpty, afterColon.allSatisfy(\.isASCII), afterColon.allSatisfy(\.isNumber) else { return nil }
        }
        var authority = text.prefix { $0 != "/" && $0 != "?" && $0 != "#" }
        if let at = authority.lastIndex(of: "@") { authority = authority[authority.index(after: at)...] }
        var host = authority
        if host.hasPrefix("[") {
            guard let close = host.firstIndex(of: "]") else { return nil }
            host = host[host.startIndex...close]
        } else if let colon = host.firstIndex(of: ":") {
            host = host[host.startIndex..<colon]
        }
        var result = host.lowercased()
        if result.hasPrefix("www.") { result.removeFirst(4) }
        return result.isEmpty ? nil : result
    }
}
