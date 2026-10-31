import Foundation

/// A typed key into the `setting` table. The stored value is the JSON encoding of `Value`.
public struct SettingKey<Value: Codable & Sendable & Equatable>: Sendable {
    public let name: String
    public let defaultValue: Value

    public init(name: String, defaultValue: Value) {
        self.name = name
        self.defaultValue = defaultValue
    }
}

/// Every setting Stave stores. Not named "Settings": that clashes with SwiftUI's scene.
public enum SettingKeys {
    public static let workspaceShortcutsEnabled = SettingKey<Bool>(name: "workspaceShortcutsEnabled", defaultValue: true)
    public static let compactMode = SettingKey<Bool>(name: "compactMode", defaultValue: false)
    public static let firstRunCompleted = SettingKey<Bool>(name: "firstRunCompleted", defaultValue: false)
    public static let searchEngine = SettingKey<SearchEngine?>(name: "searchEngine", defaultValue: nil)
    public static let newTabEdge = SettingKey<NewTabEdge>(name: "newTabEdge", defaultValue: .top)
    public static let sidebarWidth = SettingKey<Double>(name: "sidebarWidth", defaultValue: 260)
}
