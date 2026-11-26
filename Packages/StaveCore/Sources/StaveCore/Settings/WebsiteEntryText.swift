import Foundation

/// How Settings ▸ Websites words one stored answer or value.
public enum WebsiteEntryText {
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
        case .setting(.contentBlocking): entry.stored == SiteDecision.deny.rawValue ? "Off" : "On"
        case .setting: entry.stored == SiteDecision.allow.rawValue ? "Allow" : "Block"
        case .value(.zoom):
            Double(entry.stored).map { "\(Int(($0 * 100).rounded()))%" } ?? entry.stored
        case .value(.userAgent): entry.stored.trimmingCharacters(in: CharacterSet(charactersIn: "\""))
        }
    }

    /// What the row shows beside the host: "Camera: Allow".
    public static func detail(_ entry: SiteEntry) -> String { "\(label(entry.kind)): \(value(entry))" }

    /// One line for the row and for VoiceOver: "example.com: Camera, Allow".
    public static func summary(_ entry: SiteEntry) -> String {
        "\(entry.host): \(label(entry.kind)), \(value(entry))"
    }
}
