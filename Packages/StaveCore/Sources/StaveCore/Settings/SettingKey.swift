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
    /// Where a link from another app opens (decision 7, question 14).
    public static let externalLinkTarget = SettingKey<ExternalLinkTarget>(name: "externalLinkTarget", defaultValue: .lastUsed)
    /// "Remove history items" (decision 9, question 15): one year by default, as in Safari.
    public static let historyRetention = SettingKey<HistoryRetention>(name: "historyRetention", defaultValue: .year)
    /// "Remove download list items" (decision 33, question 22): after one day by default, as in Safari.
    public static let downloadListRetention = SettingKey<DownloadListRetention>(name: "downloadListRetention", defaultValue: .day)
    /// "Archive idle tabs after" (decision 34, question 27): never by default.
    public static let autoArchiveAfter = SettingKey<AutoArchiveAfter>(name: "autoArchiveAfter", defaultValue: .never)
    /// When "Archive idle tabs after" last changed from Never to a limit; nil before that. A tab's idle time never starts before this, so
    /// turning the setting on does not archive everything that was already old.
    public static let autoArchiveEnabledAt = SettingKey<Date?>(name: "autoArchiveEnabledAt", defaultValue: nil)
    /// Website data stores of deleted profiles and containers that are not yet removed from disk (H2). Written in the transaction that deletes
    /// the rows and trimmed one ID at a time after each removal succeeds; the next launch retries what is left.
    public static let pendingStoreRemovals = SettingKey<[UUID]>(name: "pendingStoreRemovals", defaultValue: [])
    /// Stores whose removal succeeded and that the next launch checks against WebKit's listing before they are forgotten (R2-H1).
    public static let storeRemovalsToVerify = SettingKey<[UUID]>(name: "storeRemovalsToVerify", defaultValue: [])
    public static let sidebarWidth = SettingKey<Double>(name: "sidebarWidth", defaultValue: 260)
}
