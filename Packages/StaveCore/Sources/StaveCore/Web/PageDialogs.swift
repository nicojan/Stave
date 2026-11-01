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

    public static func title(pageTitle: String, url: String) -> String {
        let trimmed = pageTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty { return trimmed }
        return SiteHost.normalized(url) ?? "Pop-up"
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
