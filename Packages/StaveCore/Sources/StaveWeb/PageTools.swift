import AppKit
import Foundation
import StaveCore
import WebKit

/// What the app's page commands ask of a page's web view: find, print and the Web Inspector. Zoom is `PageHost`'s, because it is stored per site.
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

    // MARK: Print (decision 13)

    /// The print operation for the page, named after it, with the print panel; the app runs it as a sheet on the page's window. A copy of
    /// the shared print info is used, so the app's defaults are never changed. WebKit prints nothing from a view with an empty frame, so the
    /// operation's view gets the page's bounds.
    public static func print(_ webView: WKWebView, title: String) -> NSPrintOperation {
        let info = (NSPrintInfo.shared.copy() as? NSPrintInfo) ?? NSPrintInfo()
        let operation = webView.printOperation(with: info)
        operation.jobTitle = title
        operation.showsPrintPanel = true
        operation.showsProgressPanel = true
        operation.view?.frame = webView.bounds
        return operation
    }

    // MARK: Web Inspector (decision 14)

    static let developerExtrasKey = "developerExtrasEnabled"
    static let developerExtrasSetter = NSSelectorFromString("_setDeveloperExtrasEnabled:")
    private static let developerExtrasGetter = NSSelectorFromString("_developerExtrasEnabled")
    private static let inspectorGetter = NSSelectorFromString("_inspector")
    private static let showSelector = NSSelectorFromString("show")
    private static let showMainResourceSelector = NSSelectorFromString("showMainResourceForFrame:")
    private static let showResourcesSelector = NSSelectorFromString("showResources")
    private static let detachSelector = NSSelectorFromString("detach")
    private static let mainFrameGetter = NSSelectorFromString("_mainFrame")
    private static let frameHandleGetter = NSSelectorFromString("_handle")

    /// Whether the page was made with `developerExtrasEnabled` (false where WebKit lacks the private preference).
    public static func hasDeveloperExtras(_ webView: WKWebView) -> Bool {
        let preferences = webView.configuration.preferences
        guard preferences.responds(to: developerExtrasGetter) else { return false }
        return (preferences.value(forKey: developerExtrasKey) as? Bool) == true
    }

    /// Develop ▸ Show Web Inspector applies: the page has developer extras and WebKit has the private inspector with `show`.
    public static func canShowInspector(_ webView: WKWebView) -> Bool {
        hasDeveloperExtras(webView) && inspector(of: webView)?.responds(to: showSelector) == true
    }

    /// Develop ▸ Show Page Source applies: as `canShowInspector`, with a way to open the inspector on the page's resources.
    public static func canShowPageSource(_ webView: WKWebView) -> Bool {
        guard hasDeveloperExtras(webView), let inspector = inspector(of: webView) else { return false }
        return inspector.responds(to: showMainResourceSelector) || inspector.responds(to: showResourcesSelector)
    }

    /// Opens the in-app Web Inspector (⌥⌘I) in its own window; nothing when it doesn't apply.
    public static func showInspector(_ webView: WKWebView) {
        guard canShowInspector(webView), let inspector = inspector(of: webView) else { return }
        _ = inspector.perform(showSelector)
        detachInspector(inspector)
    }

    /// Opens the inspector on the page's main resource, as Safari's Show Page Source (⌥⌘U) does, or on its resources when WebKit can't
    /// name the main frame; nothing when it doesn't apply.
    public static func showPageSource(_ webView: WKWebView) {
        guard canShowPageSource(webView), let inspector = inspector(of: webView) else { return }
        if inspector.responds(to: showMainResourceSelector), let handle = mainFrameHandle(of: webView) {
            _ = inspector.perform(showMainResourceSelector, with: handle)
        } else if inspector.responds(to: showResourcesSelector) {
            _ = inspector.perform(showResourcesSelector)
        }
        detachInspector(inspector)
    }

    /// WebKit attaches the inspector beside the page's web view, inside its superview. ChorusEngine's `WebViewHostView` pins the web view to
    /// its edges and clips to its bounds, so an attached inspector doesn't show there (Task 9's check); it opens in its own window instead.
    /// Called from the menu commands (an inspector already connected) and from `PageDelegate`'s `_webView:didAttachLocalInspector:` (a new
    /// one, also from the page's Inspect Element).
    static func detachInspector(_ inspector: NSObject) {
        guard inspector.responds(to: detachSelector) else { return }
        _ = inspector.perform(detachSelector)
    }

    private static func inspector(of webView: WKWebView) -> NSObject? {
        guard webView.responds(to: inspectorGetter) else { return nil }
        return webView.perform(inspectorGetter)?.takeUnretainedValue() as? NSObject
    }

    private static func mainFrameHandle(of webView: WKWebView) -> NSObject? {
        guard webView.responds(to: mainFrameGetter),
              let frame = webView.perform(mainFrameGetter)?.takeUnretainedValue() as? NSObject,
              frame.responds(to: frameHandleGetter) else { return nil }
        return frame.perform(frameHandleGetter)?.takeUnretainedValue() as? NSObject
    }
}
