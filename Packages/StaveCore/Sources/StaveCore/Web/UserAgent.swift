public enum UserAgent {
    private static let fallbackVersion = "17.0"

    /// The "Version/x Safari/y" application name, so sites see the system Safari. Only the leading run of digits and dots of the version is kept.
    public static func applicationName(safariVersion: String?) -> String {
        let digits = String((safariVersion ?? "").prefix { $0.isASCII && ($0.isNumber || $0 == ".") })
        return "Version/\(digits.isEmpty ? fallbackVersion : digits) Safari/605.1.15"
    }
}
