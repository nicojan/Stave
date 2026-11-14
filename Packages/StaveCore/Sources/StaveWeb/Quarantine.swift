import CoreServices
import Foundation

/// Marks a finished download so Gatekeeper checks it (plan 3, decision 12).
public enum Quarantine {
    public static func mark(_ file: URL, source: URL?) throws {
        var properties: [String: Any] = [
            kLSQuarantineAgentNameKey as String: "Stave",
            kLSQuarantineTypeKey as String: kLSQuarantineTypeWebDownload as String,
        ]
        if let source { properties[kLSQuarantineDataURLKey as String] = source }
        var values = URLResourceValues()
        values.quarantineProperties = properties
        var target = file
        try target.setResourceValues(values)
    }
}
