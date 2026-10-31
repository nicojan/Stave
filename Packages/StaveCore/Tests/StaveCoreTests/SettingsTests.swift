import Foundation
import GRDB
import Testing
@testable import StaveCore

struct SettingsTests {
    @Test func defaultsWhenUnset() throws {
        let (store, _, _) = try makeTempStore()
        #expect(try store.setting(SettingKeys.workspaceShortcutsEnabled) == true)
        #expect(try store.setting(SettingKeys.compactMode) == false)
        #expect(try store.setting(SettingKeys.firstRunCompleted) == false)
        #expect(try store.setting(SettingKeys.searchEngine) == nil)
        #expect(try store.setting(SettingKeys.newTabEdge) == .top)
        #expect(try store.setting(SettingKeys.sidebarWidth) == 260)
    }

    @Test func roundTripAndReopen() throws {
        let (store, database, file) = try makeTempStore()
        try store.setSetting(SettingKeys.compactMode, true)
        try store.setSetting(SettingKeys.searchEngine, .kagi)
        try store.setSetting(SettingKeys.newTabEdge, .bottom)
        try database.close()

        let reopened = OrganizationStore(database: try StaveDatabase.open(at: file))
        #expect(try reopened.setting(SettingKeys.compactMode) == true)
        #expect(try reopened.setting(SettingKeys.searchEngine) == .kagi)
        #expect(try reopened.setting(SettingKeys.newTabEdge) == .bottom)
    }

    @Test func settingTwiceKeepsOneRowAndStampsTheClock() throws {
        let clock = TestClock()
        let (store, database, _) = try makeTempStore(now: clock.now)
        try store.setSetting(SettingKeys.sidebarWidth, 300)
        clock.advance(by: 10)
        try store.setSetting(SettingKeys.sidebarWidth, 320)
        #expect(try store.setting(SettingKeys.sidebarWidth) == 320)
        let rows = try database.writer.read { db in
            try Row.fetchAll(db, sql: "SELECT modifiedAt FROM setting WHERE key = 'sidebarWidth'")
        }
        #expect(rows.count == 1)
        let stamp: Date = try #require(rows.first?["modifiedAt"])
        #expect(stamp == OrganizationStore.storedPrecision(clock.date))
    }

    @Test func searchEngineCanBeCleared() throws {
        let (store, _, _) = try makeTempStore()
        try store.setSetting(SettingKeys.searchEngine, .kagi)
        try store.setSetting(SettingKeys.searchEngine, nil)
        #expect(try store.setting(SettingKeys.searchEngine) == nil)
    }

    @Test func undecodableFallsBackToDefault() throws {
        let (store, database, _) = try makeTempStore()
        try database.writer.write { db in
            try db.execute(
                sql: "INSERT INTO setting (key, value, modifiedAt) VALUES ('sidebarWidth', 'not json', ?)",
                arguments: [Date()]
            )
        }
        #expect(try store.setting(SettingKeys.sidebarWidth) == 260)
    }

    @Test func displayNames() {
        let names = SearchEngine.allCases.map(\.displayName)
        #expect(names == ["Google", "DuckDuckGo", "Kagi", "Bing", "Ecosia"])
    }

    @Test func searchURLs() {
        #expect(SearchEngine.google.searchURL(for: "a&b c") == "https://www.google.com/search?q=a%26b%20c")
        #expect(SearchEngine.duckDuckGo.searchURL(for: "a&b c") == "https://duckduckgo.com/?q=a%26b%20c")
        #expect(SearchEngine.kagi.searchURL(for: "a&b c") == "https://kagi.com/search?q=a%26b%20c")
        #expect(SearchEngine.bing.searchURL(for: "a&b c") == "https://www.bing.com/search?q=a%26b%20c")
        #expect(SearchEngine.ecosia.searchURL(for: "a&b c") == "https://www.ecosia.org/search?q=a%26b%20c")
        let encoded = SearchEngine.google.searchURL(for: "日本 #1")
        #expect(encoded.hasSuffix("%20%231"))
        #expect(encoded.hasPrefix("https://www.google.com/search?q=%E6%97%A5%E6%9C%AC"))
        #expect(SearchEngine.google.searchURL(for: "1+1=2?/") == "https://www.google.com/search?q=1%2B1%3D2%3F%2F")
    }
}
