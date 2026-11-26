import Foundation
import Testing
@testable import StaveCore

/// A source that keeps its answers in memory, as a private window's does, and counts resets.
@MainActor
final class FakeSiteSource: SitePanelSource {
    var choices: [SitePanelKey: SiteChoice] = [:]
    var values: [SiteValueKey: Data] = [:]
    var resets = 0
    /// Every `set` and `setValue` call in order, so a test sees what the panel wrote.
    var writes: [String] = []

    func choice(_ key: SitePanelKey) -> SiteChoice { choices[key] ?? .ask }

    func set(_ key: SitePanelKey, _ choice: SiteChoice) {
        writes.append("\(key.rawValue)=\(choice.rawValue)")
        choices[key] = choice == .ask ? nil : choice
    }

    func value<V: Codable>(_ key: SiteValueKey, as type: V.Type) -> V? {
        values[key].flatMap { try? JSONDecoder().decode(V.self, from: $0) }
    }

    func setValue<V: Codable>(_ key: SiteValueKey, _ value: V?) {
        writes.append("\(key.rawValue)=\(value == nil ? "nil" : "value")")
        values[key] = value.flatMap { try? JSONEncoder().encode($0) }
    }

    func resetSite() {
        resets += 1
        choices = [:]
        values = [:]
    }
}

/// The per-site panel's rules (plan 5, decision 20 and question 11): rows, choices and reset.
@MainActor
struct SitePanelModelTests {
    private func selected(_ model: SitePanelModel, _ kind: SitePanelRow.Kind) -> String? {
        model.rows.first { $0.kind == kind }?.selectedID
    }

    @Test func panelShowsStoredAnswers() {
        let source = FakeSiteSource()
        source.choices = [.camera: .allow, .microphone: .block, .contentBlocking: .block]
        source.values = [.zoom: Data("1.5".utf8)]
        let model = SitePanelModel(source: source, host: "example.com")
        #expect(model.rows.map(\.kind) == [.permission(.camera), .permission(.microphone), .permission(.contentBlocking), .zoom, .userAgent])
        #expect(selected(model, .permission(.camera)) == "allow")
        #expect(selected(model, .permission(.microphone)) == "block")
        // Content blocking's own values: a stored deny is "Off", no row is "On".
        let blocking = model.rows.first { $0.kind == .permission(.contentBlocking) }
        #expect(blocking?.options.map(\.title) == ["On", "Off"])
        #expect(blocking?.selectedTitle == "Off")
        #expect(selected(model, .zoom) == WebsiteEntryText.zoomPercent(1.5))
        #expect(model.rows.first { $0.kind == .zoom }?.selectedTitle == "150%")
        #expect(model.title == "Settings for example.com")
    }

    @Test func rowsStartAtTheDefaults() {
        let model = SitePanelModel(source: FakeSiteSource(), host: "example.org")
        #expect(selected(model, .permission(.camera)) == "ask")
        #expect(model.rows.first { $0.kind == .permission(.camera) }?.options.map(\.title) == ["Ask", "Allow", "Block"])
        #expect(selected(model, .permission(.contentBlocking)) == "ask")
        #expect(model.rows.first { $0.kind == .permission(.contentBlocking) }?.selectedTitle == "On")
        #expect(selected(model, .zoom) == WebsiteEntryText.zoomPercent(1))
    }

    @Test func askRemovesTheRow() {
        let source = FakeSiteSource()
        let model = SitePanelModel(source: source, host: "example.com")
        model.set(.camera, .allow)
        #expect(source.choices[.camera] == .allow)
        #expect(selected(model, .permission(.camera)) == "allow")
        model.set(.camera, .ask)
        #expect(source.choices[.camera] == nil)
        #expect(selected(model, .permission(.camera)) == "ask")
        // Zoom back to 100 % stores nothing.
        model.setZoom(1.25)
        #expect(source.value(.zoom, as: Double.self) == 1.25)
        model.setZoom(1.0)
        #expect(source.values[.zoom] == nil)
    }

    @Test func panelSetsBlock() {
        let source = FakeSiteSource()
        let model = SitePanelModel(source: source, host: "example.com")
        model.set(.microphone, .block)
        #expect(source.choices[.microphone] == .block)
        #expect(selected(model, .permission(.microphone)) == "block")
        // A fresh panel for the same source shows it again.
        #expect(selected(SitePanelModel(source: source, host: "example.com"), .permission(.microphone)) == "block")
    }

    @Test func choosingByOptionIDWritesThroughTheSameSetters() {
        let source = FakeSiteSource()
        let model = SitePanelModel(source: source, host: "example.com")
        model.choose(.permission(.camera), optionID: "block")
        model.choose(.permission(.contentBlocking), optionID: "block")
        model.choose(.zoom, optionID: WebsiteEntryText.zoomPercent(1.75))
        model.choose(.zoom, optionID: "not a level") // hostile or stale: ignored
        model.choose(.permission(.camera), optionID: "maybe")
        #expect(source.writes == ["camera=block", "contentBlocking=block", "zoom=value"])
        #expect(source.value(.zoom, as: Double.self) == 1.75)
    }

    @Test func userAgentRowSetsAndResets() {
        let source = FakeSiteSource()
        let model = SitePanelModel(source: source, host: "example.com")
        let row = model.rows.first { $0.kind == .userAgent }
        #expect(row?.label == "User agent")
        #expect(row?.label == WebsiteEntryText.label(.value(.userAgent)))
        #expect(row?.options.map(\.title) == ["Default", "Safari", "Chrome on Mac"])
        #expect(row?.options.map(\.id) == ["standard", "safari", "chrome"])
        #expect(row?.selectedTitle == "Default")
        #expect(!model.hasStoredValues)

        model.choose(.userAgent, optionID: "chrome")
        #expect(source.value(.userAgent, as: String.self) == "chrome")
        #expect(selected(model, .userAgent) == "chrome")
        #expect(model.rows.first { $0.kind == .userAgent }?.selectedTitle == "Chrome on Mac")
        #expect(model.hasStoredValues)
        model.choose(.userAgent, optionID: "safari")
        #expect(source.value(.userAgent, as: String.self) == "safari")
        // Default stores nothing, and an ID the row doesn't offer is ignored.
        model.choose(.userAgent, optionID: "netscape")
        #expect(selected(model, .userAgent) == "safari")
        model.choose(.userAgent, optionID: "standard")
        #expect(source.values[.userAgent] == nil)
        #expect(!model.hasStoredValues)
        #expect(source.writes == ["userAgent=value", "userAgent=value", "userAgent=nil"])

        // A stored value nobody offers reads as Default (hostile or stale rows never crash the panel).
        source.values[.userAgent] = Data("\"netscape\"".utf8)
        model.refresh()
        #expect(selected(model, .userAgent) == "standard")

        model.choose(.userAgent, optionID: "chrome")
        model.resetSite()
        #expect(source.resets == 1)
        #expect(selected(model, .userAgent) == "standard")
        #expect(!model.hasStoredValues)
    }

    /// The panel's "Open in …" buttons: only the apps it was given, and opening an app it wasn't given does nothing.
    @Test func panelOpensOnlyOfferedApps() {
        var opened: [OpenElsewhereApp] = []
        let model = SitePanelModel(source: FakeSiteSource(), host: "example.com", openElsewhere: [.chrome], openIn: { opened.append($0) })
        #expect(model.openElsewhere == [.chrome])
        model.open(in: .safari)
        #expect(opened.isEmpty)
        model.open(in: .chrome)
        #expect(opened == [.chrome])
        #expect(SitePanelModel(source: FakeSiteSource(), host: "example.com").openElsewhere.isEmpty)
        // A private window's panel offers none, and opens none.
        var privateOpened: [OpenElsewhereApp] = []
        let priv = SitePanelModel(source: FakeSiteSource(), host: "example.com", isPrivate: true, openElsewhere: [.chrome, .safari], openIn: { privateOpened.append($0) })
        #expect(priv.openElsewhere.isEmpty)
        priv.open(in: .chrome)
        #expect(privateOpened.isEmpty)
    }

    @Test func resetSiteClearsEveryKey() {
        let source = FakeSiteSource()
        source.choices = [.camera: .allow, .microphone: .block, .contentBlocking: .block]
        source.values = [.zoom: Data("2.0".utf8), .userAgent: Data("\"chrome\"".utf8)]
        let model = SitePanelModel(source: source, host: "example.com")
        #expect(model.hasStoredValues)
        #expect(selected(model, .userAgent) == "chrome")
        model.resetSite()
        #expect(source.resets == 1)
        #expect(source.choices.isEmpty && source.values.isEmpty)
        for row in model.rows {
            let expected = switch row.kind {
            case .zoom: WebsiteEntryText.zoomPercent(1)
            case .userAgent: "standard"
            case .permission: "ask"
            }
            #expect(row.selectedID == expected)
        }
        #expect(!model.hasStoredValues)
    }

    /// R1-M4: the panel is stale once the page shows another site, or no web site at all.
    @Test func panelIsStaleWhenThePageLeavesTheSite() {
        let model = SitePanelModel(source: FakeSiteSource(), host: "example.com")
        #expect(!model.isStale(shownHost: "example.com"))
        #expect(model.isStale(shownHost: "example.org"))
        #expect(model.isStale(shownHost: nil))
    }

    @Test func nonWebPageHasNoPanel() {
        for url in ["", "about:blank", "file:///private/tmp/a.html", "data:text/html,x", "javascript:alert(1)", "mailto:a@example.com", "blob:https://example.com/0b1c", "blob:null/0b1c"] {
            #expect(SitePanelSite.host(forPageURL: url) == nil, "\(url)")
        }
        #expect(SitePanelSite.host(forPageURL: "https://www.Example.com:8080/x?y=1") == "example.com")
        #expect(SitePanelSite.host(forPageURL: "http://127.0.0.1:8765/cam.html") == "127.0.0.1")
        // An IDN host (in its address form) and an IPv6 literal with a port still name a site.
        #expect(SitePanelSite.host(forPageURL: "https://xn--bcher-kva.example/x") == "xn--bcher-kva.example")
        #expect(SitePanelSite.host(forPageURL: "http://[::1]:8765/cam.html") != nil)
        #expect(SitePanelSite.host(forPageURL: "http://[::1]:8765/cam.html") == SitePanelSite.host(forPageURL: "http://[::1]/"))
    }

    /// One source for each word: the panel's picker titles are the Websites list's own, and a zoom reads the same in both.
    @Test func panelWordsComeFromTheWebsitesList() {
        let source = FakeSiteSource()
        source.choices = [.camera: .allow]
        source.values = [.zoom: Data("1.5".utf8)]
        let model = SitePanelModel(source: source, host: "example.com")
        func titles(_ kind: SitePanelRow.Kind) -> [String] { model.rows.first { $0.kind == kind }?.options.map(\.title) ?? [] }
        #expect(titles(.permission(.camera)) == [SitePanelText.ask, WebsiteEntryText.allow, WebsiteEntryText.block])
        #expect(titles(.permission(.contentBlocking)) == [WebsiteEntryText.on, WebsiteEntryText.off])
        #expect(titles(.zoom).contains(WebsiteEntryText.zoomPercent(1.5)))
        #expect(model.rows.first { $0.kind == .zoom }?.selectedTitle == "150%")
        let entry = SiteEntry(id: UUID(), profileID: UUID(), host: "example.com", kind: .value(.zoom), stored: "1.5")
        #expect(WebsiteEntryText.value(entry) == model.rows.first { $0.kind == .zoom }?.selectedTitle)
    }

    @Test func menuItemFollowsTheSite() {
        let web = PageStatusSummary(hasPage: true, hasSite: true)
        #expect(PageMenuState.from(status: web, sheetOpen: false).canShowSitePanel)
        // A failure panel still has a site: Block is how a user undoes a bad answer.
        #expect(PageMenuState.from(status: PageStatusSummary(hasPage: true, hasFailure: true, hasSite: true), sheetOpen: false).canShowSitePanel)
        #expect(!PageMenuState.from(status: PageStatusSummary(hasPage: true, hasSite: false), sheetOpen: false).canShowSitePanel)
        #expect(!PageMenuState.from(status: web, sheetOpen: true).canShowSitePanel)
        #expect(!PageMenuState.from(status: web, sheetOpen: false, historyShown: true).canShowSitePanel)
        #expect(!PageMenuState.from(status: nil, sheetOpen: false).canShowSitePanel)
    }
}
