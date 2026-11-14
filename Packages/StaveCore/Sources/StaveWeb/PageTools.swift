import Foundation
import StaveCore
import WebKit

/// What the app's page commands ask of a page's web view (find now; print and zoom in Task 9).
@MainActor
public enum PageTools {
    /// Finds `query` in the page from the current match, wrapping at the end, ignoring case (as Safari does), with WebKit's public find.
    /// An empty query finds nothing.
    public static func find(_ query: String, backwards: Bool, in webView: WKWebView) async -> FindOutcome {
        guard !query.isEmpty else { return .notFound }
        let configuration = WKFindConfiguration()
        configuration.backwards = backwards
        configuration.caseSensitive = false
        configuration.wraps = true
        return await withCheckedContinuation { continuation in
            webView.find(query, configuration: configuration) { result in
                continuation.resume(returning: result.matchFound ? .found : .notFound)
            }
        }
    }

    /// The page's selected text for Use Selection for Find (⌘E); nil with nothing selected or when the page can't answer. Read in Stave's
    /// own script world, so the page's scripts can't replace `getSelection`. The text is page content: `FindState` caps it.
    public static func selectedText(in webView: WKWebView) async -> String? {
        let value = try? await webView.evaluateJavaScript("String(getSelection())", in: nil, contentWorld: .defaultClient)
        guard let text = value as? String, !text.isEmpty else { return nil }
        return text
    }
}
