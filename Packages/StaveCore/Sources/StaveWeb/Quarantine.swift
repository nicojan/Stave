import CoreServices
import Foundation

/// Where a download came from, for the quarantine record Gatekeeper reads: the file's own URL and the page that offered it. With both,
/// Gatekeeper's "downloaded from" names the site rather than nothing (decision 23).
public struct QuarantineSource: Equatable, Sendable {
    /// The URL the bytes came from (for a `data:` or `blob:` download, the page that made it).
    public var download: URL?
    /// The page the download was started from.
    public var page: URL?

    public init(download: URL?, page: URL?) {
        self.download = download
        self.page = page
    }
}

/// Marks a finished download so Gatekeeper checks it (plan 3, decision 12).
public enum Quarantine {
    static let agentName = "Stave"

    /// The quarantine record's properties: Stave as the agent, a web download, and the source's data and origin URLs when known.
    public static func properties(for source: QuarantineSource?) -> [String: Any] {
        var properties: [String: Any] = [
            kLSQuarantineAgentNameKey as String: agentName,
            kLSQuarantineTypeKey as String: kLSQuarantineTypeWebDownload as String,
        ]
        if let download = source?.download { properties[kLSQuarantineDataURLKey as String] = download }
        if let page = source?.page { properties[kLSQuarantineOriginURLKey as String] = page }
        return properties
    }

    public static func mark(_ file: URL, source: QuarantineSource?) throws {
        var values = URLResourceValues()
        values.quarantineProperties = properties(for: source)
        var target = file
        try target.setResourceValues(values)
    }

    /// Whether the file already carries Stave's quarantine record.
    public static func isMarked(_ file: URL) -> Bool {
        let values = try? URL(fileURLWithPath: file.path).resourceValues(forKeys: [.quarantinePropertiesKey])
        return values?.quarantineProperties?[kLSQuarantineAgentNameKey as String] as? String == agentName
    }
}
