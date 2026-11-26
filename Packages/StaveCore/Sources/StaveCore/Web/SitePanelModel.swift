import Foundation
import Observation

/// What the per-site panel can answer with Ask / Allow / Block (decision 20). Content blocking uses the same keys with its own words:
/// `.ask` (no stored row) is "On" and `.block` (a stored deny) is "Off".
public enum SitePanelKey: String, CaseIterable, Sendable {
    case camera, microphone, contentBlocking

    /// The `siteSetting` key the answer is stored under.
    public var settingKey: SiteSettingKey {
        switch self {
        case .camera: .camera
        case .microphone: .microphone
        case .contentBlocking: .contentBlocking
        }
    }
}

/// A permission's state for a site. Block is stored as `SiteDecision.deny` (decision 32).
public enum SiteChoice: String, CaseIterable, Sendable {
    case ask, allow, block

    /// The stored decision: nil (no row) for Ask.
    public var decision: SiteDecision? {
        switch self {
        case .ask: nil
        case .allow: .allow
        case .block: .deny
        }
    }

    public init(decision: SiteDecision?) {
        switch decision {
        case nil: self = .ask
        case .allow: self = .allow
        case .deny: self = .block
        }
    }
}

/// One profile's (or one private session's) answers and values for one host. A profile's source wraps the store and writes through the
/// path that bumps the Settings revision; a private session's keeps memory only. Both apply a change to the host's live pages at once.
@MainActor
public protocol SitePanelSource: AnyObject {
    func choice(_ key: SitePanelKey) -> SiteChoice
    func set(_ key: SitePanelKey, _ choice: SiteChoice)
    func value<V: Codable>(_ key: SiteValueKey, as: V.Type) -> V?
    func setValue<V: Codable>(_ key: SiteValueKey, _ value: V?)
    /// Removes every stored answer and value for the host (Reset This Site) and puts its live pages back to the defaults.
    func resetSite()
}

/// One row of the panel: a label and the options to pick from.
public struct SitePanelRow: Identifiable, Equatable, Sendable {
    public enum Kind: Hashable, Sendable {
        case permission(SitePanelKey)
        case zoom
        case userAgent
    }

    public struct Option: Identifiable, Equatable, Sendable {
        public var id: String
        public var title: String
    }

    public var kind: Kind
    public var label: String
    public var options: [Option]
    public var selectedID: String
    public var id: Kind { kind }

    public var selectedTitle: String { options.first { $0.id == selectedID }?.title ?? "" }
}

/// The per-site panel (decision 20): camera, microphone, content blocking, zoom and user agent, each with its own choices, and Reset This Site.
/// Holds no state of its own: every change goes to the source and the rows are read back.
@MainActor
@Observable
public final class SitePanelModel {
    public private(set) var rows: [SitePanelRow] = []
    public let host: String
    /// The panel is for a private window's session: its changes are kept in memory only.
    public let isPrivate: Bool
    @ObservationIgnored private let source: any SitePanelSource
    /// The other browsers the panel offers "Open in …" for (only installed ones), and what opening one does with the page's address.
    public let openElsewhere: [OpenElsewhereApp]
    @ObservationIgnored private let openIn: @MainActor (OpenElsewhereApp) -> Void

    public init(
        source: any SitePanelSource, host: String, isPrivate: Bool = false,
        openElsewhere: [OpenElsewhereApp] = [], openIn: @escaping @MainActor (OpenElsewhereApp) -> Void = { _ in }
    ) {
        self.source = source
        self.host = host
        self.isPrivate = isPrivate
        // A private window's address never goes to another browser's history (decision 25).
        self.openElsewhere = isPrivate ? [] : openElsewhere
        self.openIn = openIn
        refresh()
    }

    public var title: String { SitePanelText.title(host: host) }
    /// A line under the rows, only for a private window's panel.
    public var note: String? { isPrivate ? SitePanelText.privateNote : nil }

    /// True once the page shows another site (or none): the panel's edits would land on a site the page has left, so the view closes it.
    public func isStale(shownHost: String?) -> Bool { shownHost != host }

    /// Something is stored for the host, so Reset This Site has something to do.
    public private(set) var hasStoredValues = false

    public func set(_ key: SitePanelKey, _ choice: SiteChoice) {
        source.set(key, choice)
        refresh()
    }

    /// A zoom level (a factor, 1.5 for 150 %); 100 % stores nothing.
    public func setZoom(_ level: Double) {
        source.setValue(.zoom, ZoomLevels.storedValue(ZoomLevels.sanitized(level)))
        refresh()
    }

    /// A user agent; the default stores nothing.
    public func setUserAgent(_ agent: SiteUserAgent) {
        source.setValue(.userAgent, agent.storedValue)
        refresh()
    }

    /// What a picker reports: the row and the option's ID. An ID the row doesn't offer is ignored.
    public func choose(_ kind: SitePanelRow.Kind, optionID: String) {
        guard let row = rows.first(where: { $0.kind == kind }), row.options.contains(where: { $0.id == optionID }) else { return }
        switch kind {
        case .permission(let key):
            if let choice = SiteChoice(rawValue: optionID) { set(key, choice) }
        case .zoom:
            if let level = ZoomLevels.levels.first(where: { Self.zoomID($0) == optionID }) { setZoom(level) }
        case .userAgent:
            if let agent = SiteUserAgent(rawValue: optionID) { setUserAgent(agent) }
        }
    }

    /// "Open in Safari" / "Open in Chrome": only for an app the panel was given.
    public func open(in app: OpenElsewhereApp) {
        guard openElsewhere.contains(app) else { return }
        openIn(app)
    }

    public func resetSite() {
        source.resetSite()
        refresh()
    }

    /// Re-reads every row from the source (after a change, and when Settings changed the same rows).
    public func refresh() {
        rows = SitePanelKey.allCases.map(permissionRow) + [zoomRow, userAgentRow]
        let anyAnswer = SitePanelKey.allCases.contains { source.choice($0) != .ask }
        let anyValue = source.value(.zoom, as: Double.self) != nil || source.value(.userAgent, as: String.self) != nil
        hasStoredValues = anyAnswer || anyValue
    }

    private func permissionRow(_ key: SitePanelKey) -> SitePanelRow {
        let kind = SitePanelRow.Kind.permission(key)
        let label = WebsiteEntryText.label(.setting(key.settingKey))
        let choice = source.choice(key)
        if key == .contentBlocking {
            // On is the default (no row); anything but a stored deny reads as On.
            return SitePanelRow(
                kind: kind, label: label,
                options: [.init(id: SiteChoice.ask.rawValue, title: SitePanelText.on), .init(id: SiteChoice.block.rawValue, title: SitePanelText.off)],
                selectedID: choice == .block ? SiteChoice.block.rawValue : SiteChoice.ask.rawValue
            )
        }
        return SitePanelRow(
            kind: kind, label: label,
            options: [
                .init(id: SiteChoice.ask.rawValue, title: SitePanelText.ask),
                .init(id: SiteChoice.allow.rawValue, title: SitePanelText.allow),
                .init(id: SiteChoice.block.rawValue, title: SitePanelText.block),
            ],
            selectedID: choice.rawValue
        )
    }

    private var zoomRow: SitePanelRow {
        let level = nearestLevel(ZoomLevels.sanitized(source.value(.zoom, as: Double.self)))
        return SitePanelRow(
            kind: .zoom, label: WebsiteEntryText.label(.value(.zoom)),
            options: ZoomLevels.levels.map { .init(id: Self.zoomID($0), title: Self.zoomTitle($0)) },
            selectedID: Self.zoomID(level)
        )
    }

    private var userAgentRow: SitePanelRow {
        SitePanelRow(
            kind: .userAgent, label: WebsiteEntryText.label(.value(.userAgent)),
            options: SiteUserAgent.allCases.map { .init(id: $0.rawValue, title: $0.title) },
            selectedID: SiteUserAgent(stored: source.value(.userAgent, as: String.self)).rawValue
        )
    }

    private func nearestLevel(_ level: Double) -> Double {
        ZoomLevels.levels.min { abs($0 - level) < abs($1 - level) } ?? ZoomLevels.defaultLevel
    }

    /// The option's id is its title, so there is one zoom-percent formula (`WebsiteEntryText.zoomPercent`).
    private static func zoomID(_ level: Double) -> String { WebsiteEntryText.zoomPercent(level) }
    private static func zoomTitle(_ level: Double) -> String { WebsiteEntryText.zoomPercent(level) }
}

/// Which site a page's panel is for. Pure and nonisolated, so the menu, the address field and the page host all ask the same function.
public enum SitePanelSite {
    /// The host the panel is for: nil unless the page is a web page with a host (http or https), so a blank tab, a file, `data:`, `blob:`
    /// and other schemes have no panel.
    public static func host(forPageURL url: String) -> String? {
        guard URLScheme.hasWebAuthority(url) else { return nil }
        return SiteHost.normalized(url)
    }
}

/// The panel's words.
public enum SitePanelText {
    public static let ask = "Ask"
    public static let allow = WebsiteEntryText.allow
    public static let block = WebsiteEntryText.block
    public static let on = WebsiteEntryText.on
    public static let off = WebsiteEntryText.off
    public static let resetButton = "Reset This Site"
    public static let doneButton = "Done"
    /// View ▸ Settings for This Website.
    public static let menuItem = "Settings for This Website"
    /// The address field's site button: its help text and VoiceOver label.
    public static let buttonLabel = "Settings for This Website"
    /// Shown in place of the rows when the page is gone or has no web site.
    public static let unavailable = "This page has no website settings."
    /// Said under a private window's panel: its answers go with the session.
    public static let privateNote = "In a private window these are kept only until its last window closes."

    public static func title(host: String) -> String { "Settings for \(host)" }
    /// VoiceOver for one row's picker: "Camera for example.com".
    public static func pickerLabel(row: String, host: String) -> String { "\(row) for \(host)" }
}
