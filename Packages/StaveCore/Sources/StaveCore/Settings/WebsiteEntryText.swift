import Foundation

/// How Settings ▸ Websites words one stored answer or value.
public enum WebsiteEntryText {
    /// The words for a stored answer; the per-site panel reads the same ones.
    public static let allow = "Allow"
    public static let block = "Block"
    public static let on = "On"
    public static let off = "Off"

    /// A zoom factor as a percentage: 1.5 reads "150%".
    public static func zoomPercent(_ level: Double) -> String { "\(Int((level * 100).rounded()))%" }

    /// What the row is about: "Camera", "Microphone", "Content blocking", "Zoom", "User agent".
    public static func label(_ kind: SiteEntry.Kind) -> String {
        switch kind {
        case .setting(.camera): "Camera"
        case .setting(.microphone): "Microphone"
        case .setting(.contentBlocking): "Content blocking"
        case .value(.zoom): "Zoom"
        case .value(.userAgent): "User agent"
        }
    }

    /// The stored answer in words: Allow / Block (content blocking's deny means blocking is off for the site), a zoom as a percentage,
    /// anything else as its stored text without JSON quotes.
    public static func value(_ entry: SiteEntry) -> String {
        switch entry.kind {
        case .setting(.contentBlocking): entry.stored == SiteDecision.deny.rawValue ? off : on
        case .setting: entry.stored == SiteDecision.allow.rawValue ? allow : block
        case .value(.zoom):
            Double(entry.stored).map(zoomPercent) ?? entry.stored
        case .value(.userAgent): userAgentWords(entry.stored)
        }
    }

    /// A stored agent as its title; text no agent has (an older or foreign row) shows as stored, without JSON quotes.
    private static func userAgentWords(_ stored: String) -> String {
        let text = stored.trimmingCharacters(in: CharacterSet(charactersIn: "\""))
        return SiteUserAgent(rawValue: text)?.title ?? text
    }

    /// What the row shows beside the host: "Camera: Allow".
    public static func detail(_ entry: SiteEntry) -> String { "\(label(entry.kind)): \(value(entry))" }

    /// One line for the row and for VoiceOver: "example.com: Camera, Allow".
    public static func summary(_ entry: SiteEntry) -> String {
        "\(entry.host): \(label(entry.kind)), \(value(entry))"
    }
}
