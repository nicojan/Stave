import Foundation

/// Reads profile display names from Chromium-style `Local State` bytes.
public enum ArcProfileNames {
    /// Returns `[directoryBasename: name]` from `profile.info_cache.<basename>.name`.
    /// Entries without a string name are skipped; malformed input gives `[:]`. Never throws.
    public static func names(fromLocalState data: Data) -> [String: String] {
        guard let root = try? JSONDecoder().decode(JSONValue.self, from: data),
              let cache = root["profile"]?["info_cache"]?.object else { return [:] }
        return cache.reduce(into: [:]) { result, entry in
            if let name = entry.value["name"]?.string { result[entry.key] = name }
        }
    }
}
