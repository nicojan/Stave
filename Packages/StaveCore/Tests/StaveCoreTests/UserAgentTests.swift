import Foundation
import Testing
@testable import StaveCore

/// Per-site user agent and Open in Safari / Chrome (plan 5, Task 16, decisions 24 and 25).
struct UserAgentTests {
    @Test func chromeAgentNamesChrome() throws {
        let chrome = try #require(UserAgent.string(for: .chrome, safariVersion: "18.3", now: UserAgent.chromeAnchorDate))
        #expect(chrome.contains("Chrome/153.0.0.0"))
        #expect(chrome.hasPrefix("Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) "))
        #expect(chrome.hasSuffix("Safari/537.36"))
        // Chrome's string never carries Safari's version token, and the Safari version is never leaked into it.
        #expect(!chrome.contains("Version/"))
        #expect(!chrome.contains("18.3"))
    }

    /// The Chrome major follows the date from the anchor (Chrome 153, 2026-09-08), one per 14 days, and never goes below the anchor. Fixed dates only.
    @Test func chromeMajorIsDerivedFromTheDate() {
        let anchor = UserAgent.chromeAnchorDate
        func major(afterDays days: Double) -> Int { UserAgent.chromeMajorVersion(on: anchor.addingTimeInterval(days * 86_400)) }
        #expect(UserAgent.chromeAnchorVersion == 153)
        #expect(major(afterDays: 0) == 153)
        #expect(major(afterDays: 13.9) == 153)
        #expect(major(afterDays: 14) == 154)
        // Chrome 157 reached stable on 2026-11-03, 56 days after the anchor.
        #expect(major(afterDays: 56) == 157)
        #expect(major(afterDays: 14 * 13) == 166)
        #expect(major(afterDays: -1) == 153)
        #expect(major(afterDays: -400) == 153)
        let chrome = UserAgent.string(for: .chrome, applicationName: "Version/17.0 Safari/605.1.15", now: anchor.addingTimeInterval(60 * 86_400))
        #expect(chrome?.contains("Chrome/157.0.0.0") == true)
    }

    @Test func safariAndDefaultAgents() throws {
        let safari = try #require(UserAgent.string(for: .safari, safariVersion: "18.3"))
        #expect(safari == "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.3 Safari/605.1.15")
        #expect(!safari.contains("Chrome"))
        // The default sets nothing: WebKit's own string with Stave's application name stays.
        #expect(UserAgent.string(for: .standard, safariVersion: "18.3") == nil)
    }

    @Test func dotsOnlyVersionFallsBack() {
        let fallback = "Version/17.0 Safari/605.1.15"
        #expect(UserAgent.applicationName(safariVersion: "...") == fallback)
        #expect(UserAgent.applicationName(safariVersion: ".") == fallback)
        #expect(UserAgent.applicationName(safariVersion: ". .") == fallback)
        #expect(UserAgent.applicationName(safariVersion: "18.3") == "Version/18.3 Safari/605.1.15")
        #expect(UserAgent.applicationName(safariVersion: "18") == "Version/18 Safari/605.1.15")
    }

    /// Stored as the `userAgent` site value: the default removes the row, and an unreadable or unknown value reads as the default.
    @Test func perSiteAgentStoredAndCleared() throws {
        let (store, database, _) = try makeTempStore()
        let profile = try store.createProfile(name: "P")
        func stored() throws -> String? {
            try store.siteValue(profileID: profile.id, host: "example.com", key: .userAgent, as: String.self)
        }
        try store.setSiteValue(profileID: profile.id, host: "example.com", key: .userAgent, SiteUserAgent.chrome.storedValue)
        #expect(try stored() == "chrome")
        #expect(SiteUserAgent(stored: try stored()) == .chrome)
        try store.setSiteValue(profileID: profile.id, host: "example.com", key: .userAgent, SiteUserAgent.safari.storedValue)
        #expect(SiteUserAgent(stored: try stored()) == .safari)
        // Another host is untouched.
        #expect(try store.siteValue(profileID: profile.id, host: "example.org", key: .userAgent, as: String.self) == nil)
        try store.setSiteValue(profileID: profile.id, host: "example.com", key: .userAgent, SiteUserAgent.standard.storedValue)
        #expect(try stored() == nil)
        #expect(try database.writer.read { db in try SiteValue.fetchCount(db) } == 0)
        #expect(SiteUserAgent(stored: nil) == .standard)
        #expect(SiteUserAgent(stored: "Netscape") == .standard)
        #expect(SiteUserAgent(stored: "") == .standard)
    }

    @Test func settingsListNamesTheAgent() {
        func entry(_ stored: String) -> SiteEntry {
            SiteEntry(id: UUID(), profileID: UUID(), host: "example.com", kind: .value(.userAgent), stored: stored)
        }
        #expect(WebsiteEntryText.value(entry("\"chrome\"")) == SiteUserAgent.chrome.title)
        #expect(WebsiteEntryText.value(entry("\"safari\"")) == SiteUserAgent.safari.title)
        #expect(SiteUserAgent.allCases.map(\.title) == ["Default", "Safari", "Chrome on Mac"])
    }

    @Test func openElsewhereListsOnlyInstalled() {
        #expect(OpenElsewhere.available(installed: []).isEmpty)
        #expect(OpenElsewhere.available(installed: ["com.apple.Safari"]) == [.safari])
        #expect(OpenElsewhere.available(installed: ["com.google.Chrome"]) == [.chrome])
        #expect(OpenElsewhere.available(installed: ["com.google.Chrome", "com.apple.Safari", "org.mozilla.firefox"]) == [.safari, .chrome])
        #expect(OpenElsewhereApp.safari.bundleID == "com.apple.Safari")
        #expect(OpenElsewhereApp.chrome.bundleID == "com.google.Chrome")
        #expect(OpenElsewhereApp.safari.menuTitle == "Open in Safari")
        #expect(OpenElsewhereApp.chrome.menuTitle == "Open in Chrome")
    }

    /// Only the page's own web address is handed over: nothing for a blank tab, a file, `data:` or a script.
    @Test func openElsewhereUrlIsWebOnly() {
        #expect(OpenElsewhere.url(forPageURL: "https://example.com/a?b=1")?.absoluteString == "https://example.com/a?b=1")
        #expect(OpenElsewhere.url(forPageURL: "http://example.org/")?.absoluteString == "http://example.org/")
        for url in ["", "about:blank", "file:///private/tmp/a.html", "data:text/html,x", "javascript:alert(1)", "mailto:a@example.com"] {
            #expect(OpenElsewhere.url(forPageURL: url) == nil, "\(url)")
        }
    }

    @Test func menuRuleFollowsTheSite() {
        let web = PageStatusSummary(hasPage: true, hasSite: true)
        #expect(PageMenuState.from(status: web, sheetOpen: false).canOpenElsewhere)
        #expect(PageMenuState.from(status: PageStatusSummary(hasPage: true, hasFailure: true, hasSite: true), sheetOpen: false).canOpenElsewhere)
        #expect(!PageMenuState.from(status: PageStatusSummary(hasPage: true, hasSite: false), sheetOpen: false).canOpenElsewhere)
        #expect(!PageMenuState.from(status: web, sheetOpen: true).canOpenElsewhere)
        #expect(!PageMenuState.from(status: web, sheetOpen: false, historyShown: true).canOpenElsewhere)
        #expect(!PageMenuState.from(status: nil, sheetOpen: false).canOpenElsewhere)
        // A private window's address never goes to another browser's history.
        #expect(!PageMenuState.from(status: PageStatusSummary(hasPage: true, isPrivate: true, hasSite: true), sheetOpen: false).canOpenElsewhere)
    }
}
