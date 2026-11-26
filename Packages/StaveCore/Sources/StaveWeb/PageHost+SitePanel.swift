import Foundation
import StaveCore

/// Whose per-site answers and values a page reads: a profile's (stored), or a private session's (memory only).
enum SiteScope: Hashable {
    case profile(UUID)
    case privateSession(DataStoreKey)

    init(profileID: UUID?, store: DataStoreKey) {
        self = profileID.map(SiteScope.profile) ?? .privateSession(store)
    }
}

extension LivePage {
    var siteScope: SiteScope { SiteScope(profileID: siteSettingsProfileID, store: store) }
}

/// The per-site panel's sources (plan 5, decision 20). A source is bound to one scope and one site, so it keeps working while its page
/// navigates; every change goes to the same rows Settings ▸ Websites shows (through the settings source, which bumps the Settings
/// revision), or to the private session's memory, and then reaches the site's open pages at once.
extension PageHost {
    /// The panel's source for the tab's page, for its profile or its private session; nil with no page or a page with no web site.
    public func siteSource(for tabID: UUID) -> (any SitePanelSource)? {
        guard let page = pages[tabID], !page.isClosed, let site = page.panelSiteKey else { return nil }
        return PageSiteSource(host: self, scope: page.siteScope, site: site, tabID: tabID)
    }

    /// The panel itself for the tab's page, on the site the page shows now; nil as `siteSource(for:)` is.
    public func sitePanelModel(for tabID: UUID) -> SitePanelModel? {
        guard let page = pages[tabID], let site = page.panelSiteKey, let source = siteSource(for: tabID) else { return nil }
        return SitePanelModel(source: source, host: site, isPrivate: page.siteSettingsProfileID == nil)
    }

    /// The same for a private page only: its answers and zoom live in memory for the session, and nothing is written to the store.
    public func privateSiteSource(for tabID: UUID) -> (any SitePanelSource)? {
        guard let page = pages[tabID], page.siteSettingsProfileID == nil else { return nil }
        return siteSource(for: tabID)
    }

    /// Sets every open page of the site and scope to the site's stored zoom (100 % with none), as a commit does.
    func applyZoom(in scope: SiteScope, site: String) {
        let level = ZoomLevels.sanitized(siteValue(in: scope, host: site, key: .zoom, as: Double.self))
        for page in sitePages(in: scope, site: site) where page.zoom != level || page.webView.pageZoom != level {
            page.setZoom(level)
        }
    }

    /// Switches content blocking on every open page of the site and scope to what is remembered for it, and reloads the ones that changed
    /// (as the View menu's switch does). The panel's own page (`ownTab`) always switches, as the menu switches it; any OTHER page that shares
    /// a content controller keeps the lists it has, as `updateBlocking` leaves it (rulings R10, R1-H1): switching it would switch the
    /// other too, which may be on another site.
    func applyBlocking(in scope: SiteScope, site: String, ownTab: UUID? = nil) {
        let wanted = rememberedDecision(in: scope, host: site, key: .contentBlocking) != .deny
        for page in sitePages(in: scope, site: site) where page.isContentBlockingOn != wanted && (page.tabID == ownTab || !sharesContentController(page)) {
            page.isContentBlockingOn = wanted
            page.blockingHost = site
            attachRuleLists(to: page)
            page.webView.reload()
        }
    }

    /// Reset This Site: one removal of everything stored for the site (a private session's memory, or the profile's rows), then the open
    /// pages go back to the defaults.
    func resetSite(in scope: SiteScope, site: String, ownTab: UUID? = nil) {
        switch scope {
        case .profile(let profileID):
            siteSettings.removeSite(profileID: profileID, host: site)
        case .privateSession(let store):
            privateMediaAnswers = privateMediaAnswers.filter { !($0.key.store == store && $0.key.host == site) }
            privateSiteValues = privateSiteValues.filter { !($0.key.store == store && $0.key.host == site) }
        }
        applyZoom(in: scope, site: site)
        applyBlocking(in: scope, site: site, ownTab: ownTab)
    }

    /// The open pages of the site, by the address each shows (`panelSiteKey`), the same field the panel's host comes from (R1-H2).
    private func sitePages(in scope: SiteScope, site: String) -> [LivePage] {
        pages.values.filter { !$0.isClosed && $0.siteScope == scope && $0.panelSiteKey == site }
    }
}

@MainActor
final class PageSiteSource: SitePanelSource {
    private weak var host: PageHost?
    private let scope: SiteScope
    private let site: String
    /// The page the panel was opened from: it switches content blocking even when it shares a controller.
    private let tabID: UUID

    init(host: PageHost, scope: SiteScope, site: String, tabID: UUID) {
        self.tabID = tabID
        self.host = host
        self.scope = scope
        self.site = site
    }

    func choice(_ key: SitePanelKey) -> SiteChoice {
        SiteChoice(decision: host?.rememberedDecision(in: scope, host: site, key: key.settingKey))
    }

    func set(_ key: SitePanelKey, _ choice: SiteChoice) {
        guard let host else { return }
        host.setRemembered(choice.decision, in: scope, host: site, key: key.settingKey)
        if key == .contentBlocking { host.applyBlocking(in: scope, site: site, ownTab: tabID) }
    }

    func value<V: Codable>(_ key: SiteValueKey, as type: V.Type) -> V? {
        host?.siteValue(in: scope, host: site, key: key, as: type)
    }

    func setValue<V: Codable>(_ key: SiteValueKey, _ value: V?) {
        guard let host else { return }
        host.setSiteValue(value, in: scope, host: site, key: key)
        if key == .zoom { host.applyZoom(in: scope, site: site) }
    }

    func resetSite() {
        host?.resetSite(in: scope, site: site, ownTab: tabID)
    }
}
