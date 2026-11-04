import CoreGraphics
import Foundation

/// Keeps a page that loops `alert()` from locking its window. From the third dialog within `window` seconds, the sheet offers to stop the
/// page's dialogs; once stopped, every later dialog of the same document resolves at once (alert returns, confirm false, prompt nil) until
/// the page navigates to a new document (`navigation`, the page's main-frame commit count, changes).
public struct PageDialogGate: Equatable, Sendable {
    public enum Verdict: Equatable, Sendable {
        case ask(offerToStop: Bool)
        case resolveAtOnce
    }

    public static let window: TimeInterval = 10
    public static let threshold = 3

    private var navigation: Int?
    private var recent: [Date] = []
    private var stopped = false

    public init() {}

    public mutating func next(at now: Date, navigation current: Int) -> Verdict {
        if navigation != current {
            navigation = current
            recent = []
            stopped = false
        }
        if stopped { return .resolveAtOnce }
        recent = recent.filter { now.timeIntervalSince($0) < Self.window } + [now]
        return .ask(offerToStop: recent.count >= Self.threshold)
    }

    /// The user chose "Don't show more dialogs from this page" for the document `navigation`.
    public mutating func stop(navigation current: Int) {
        guard navigation == current else { return }
        stopped = true
    }
}

extension PageText {
    /// Page-supplied dialog text is cut to this many characters, then an ellipsis.
    public static let dialogMessageLimit = 1_000

    public static func dialogMessage(_ message: String) -> String {
        guard message.count > dialogMessageLimit else { return message }
        return String(message.prefix(dialogMessageLimit)) + "…"
    }

    /// The dialog's heading names the site of the frame that asked (a host or URL), so neither a page nor a frame inside it can pass its
    /// text off as Stave's or the top site's. A frame with no web origin gets the neutral heading.
    public static func dialogHeading(origin: String?) -> String {
        guard let origin, let host = SiteHost.normalized(origin) else { return "This page says" }
        return "\(host) says"
    }

    public static let stopDialogsOption = "Don’t show more dialogs from this page"
    public static let allowButton = "Allow"
    public static let dontAllowButton = "Don’t Allow"
    public static let rememberForSite = "Remember for this site"
    /// A download's row when macOS refuses Stave the downloads folder (the row reads "Failed: " then this, on two lines at most).
    public static let downloadsFolderRefused = "Allow Downloads for Stave in Privacy & Security ▸ Files and Folders."
    /// A download's row when the downloads folder is missing or can't be opened for another reason.
    public static let downloadsFolderUnavailable = "Stave can’t open your Downloads folder."
}

/// Keeps a page from saving file after file with no click (plan 3 final review). The first download of a document proceeds; the next one
/// asks ("‹host› wants to download several files"). Allowed: the rest of that document's downloads proceed. Refused (or not askable): the
/// rest are refused without asking again. A new document (`navigation`, the page's main-frame commit count, changes) starts over.
public struct PageDownloadGate: Equatable, Sendable {
    public enum Verdict: Equatable, Sendable {
        case proceed
        case ask
        case refuse
    }

    private enum Answer: Equatable, Sendable { case allowed, refused }

    private var navigation: Int?
    private var started = 0
    private var answer: Answer?

    public init() {}

    /// `current` nil: the page has no document to compare (it closed), so the one counted so far still applies.
    public mutating func next(navigation current: Int?) -> Verdict {
        if let current, current != navigation {
            navigation = current
            started = 0
            answer = nil
        }
        started += 1
        if started == 1 { return .proceed }
        switch answer {
        case .allowed: return .proceed
        case .refused: return .refuse
        case nil: return .ask
        }
    }

    /// The question's answer for the document `navigation`; an answer for a document the page already left is ignored.
    public mutating func answer(allow: Bool, navigation current: Int?) {
        guard current == nil || current == navigation else { return }
        answer = allow ? .allowed : .refused
    }
}

extension PageText {
    /// `host`: the asking page's site (a host or URL); nil, or a page with no web origin, gets the neutral wording.
    public static func severalDownloadsQuestion(host: String?) -> String {
        guard let host, let site = SiteHost.normalized(host) else { return "This page wants to download several files" }
        return "\(site) wants to download several files"
    }

    public static let severalDownloadsDetail = "Allow it to keep saving files to your Downloads folder?"

    /// "Open this link in ‹App›?", naming the page that asks when there is one (a typed address has none).
    public static func externalAppQuestion(appName: String, host: String?) -> String {
        guard let host, let site = SiteHost.normalized(host) else { return externalAppQuestion(appName: appName) }
        return "Allow \(site) to open this link in \(appName)?"
    }
}

/// Least-recently-used order for a small in-memory cache (the page host's snapshots).
public enum RecentlyUsed {
    /// The order after `key` is used: oldest first, `key` moved (or added) to the newest end, and the oldest beyond `limit` dropped.
    public static func use<Key: Equatable>(_ key: Key, in order: [Key], limit: Int) -> (order: [Key], evicted: [Key]) {
        let used = order.filter { $0 != key } + [key]
        let overflow = max(used.count - max(limit, 1), 0)
        return (Array(used.dropFirst(overflow)), Array(used.prefix(overflow)))
    }
}

/// A pop-up window's size and title.
public enum PopupFrame {
    public static let defaultSize = CGSize(width: 480, height: 640)
    public static let minimum = CGSize(width: 200, height: 150)

    /// The page's asked-for size (each side defaulting separately), never smaller than `minimum` and never larger than the screen.
    public static func size(width: Double?, height: Double?, visibleFrame: CGRect) -> CGSize {
        func side(_ asked: Double?, fallback: CGFloat, minimum: CGFloat, maximum: CGFloat) -> CGFloat {
            let wanted = asked.map { CGFloat($0) } ?? fallback
            return min(max(wanted, minimum), max(maximum, minimum))
        }
        return CGSize(
            width: side(width, fallback: defaultSize.width, minimum: minimum.width, maximum: visibleFrame.width),
            height: side(height, fallback: defaultSize.height, minimum: minimum.height, maximum: visibleFrame.height)
        )
    }

    /// The page's own title is cut to this many characters, then an ellipsis.
    public static let titleLimit = 80
    /// What leads the title when the pop-up shows no web site (nothing loaded yet, `about:blank`, `data:`).
    public static let neutralTitle = "Pop-up"

    /// The site the pop-up shows now, then its page's title: "accounts.example.com — Sign in". The host always leads, so a page can't
    /// pass its window off as another site's by its title.
    public static func title(pageTitle: String, url: String) -> String {
        let site = SiteHost.normalized(url) ?? neutralTitle
        let words = pageTitle.split(whereSeparator: { $0.isWhitespace || $0.isNewline }).joined(separator: " ")
        guard !words.isEmpty else { return site }
        let capped = words.count > titleLimit ? String(words.prefix(titleLimit)) + "…" : words
        return "\(site) — \(capped)"
    }
}

/// What the downloads popover says about each row, and which of its controls apply.
public enum DownloadRowText {
    public static let buttonLabel = "Downloads"
    public static let title = "Downloads"
    public static let clearButton = "Clear"
    public static let clearLabel = "Clear finished downloads"
    public static let cancelButton = "Cancel"
    public static let showInFinderButton = "Show in Finder"

    public static func status(_ item: DownloadItem) -> String {
        switch item.state {
        case .running(let fraction?): "\(Int((fraction * 100).rounded())) percent"
        case .running(nil): "Downloading…"
        case .finished: "Done"
        case .failed(let message): "Failed: \(message)"
        case .cancelled: "Cancelled"
        }
    }

    public static func canCancel(_ item: DownloadItem) -> Bool {
        if case .running = item.state { return true }
        return false
    }

    public static func finishedFile(_ item: DownloadItem) -> URL? {
        if case .finished(let url) = item.state { return url }
        return nil
    }

    public static func cancelLabel(_ item: DownloadItem) -> String { "Cancel downloading \(item.filename)" }
    public static func showInFinderLabel(_ item: DownloadItem) -> String { "Show \(item.filename) in Finder" }

    public static func canClear(_ items: [DownloadItem]) -> Bool { items.contains { $0.state.hasEnded } }
}
