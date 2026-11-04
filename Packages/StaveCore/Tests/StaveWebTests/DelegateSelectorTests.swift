import Foundation
import Testing
import WebKit

@testable import StaveWeb

/// WebKit finds delegate methods by Objective-C selector. A Swift method whose name doesn't map to one is never called, and nothing
/// warns: the camera and microphone method was named after the selector instead of WebKit's async Swift name, so WebKit showed its own
/// prompt with no "Remember for this site" and nothing was stored (walkthrough fix 1).
extension PageDelegateTests {
    static let delegateSelectors = [
        // Navigation
        "webView:decidePolicyForNavigationAction:decisionHandler:",
        "webView:decidePolicyForNavigationResponse:decisionHandler:",
        "webView:navigationAction:didBecomeDownload:",
        "webView:navigationResponse:didBecomeDownload:",
        "webView:didCommitNavigation:",
        "webView:didFailProvisionalNavigation:withError:",
        "webView:didFailNavigation:withError:",
        "webViewWebContentProcessDidTerminate:",
        // UI
        "webView:createWebViewWithConfiguration:forNavigationAction:windowFeatures:",
        "webViewDidClose:",
        "webView:runJavaScriptAlertPanelWithMessage:initiatedByFrame:completionHandler:",
        "webView:runJavaScriptConfirmPanelWithMessage:initiatedByFrame:completionHandler:",
        "webView:runJavaScriptTextInputPanelWithPrompt:defaultText:initiatedByFrame:completionHandler:",
        "webView:runOpenPanelWithParameters:initiatedByFrame:completionHandler:",
        "webView:requestMediaCapturePermissionForOrigin:initiatedByFrame:type:decisionHandler:",
        // Downloads
        "download:decideDestinationUsingResponse:suggestedFilename:completionHandler:",
        "downloadDidFinish:",
        "download:didFailWithError:resumeData:",
    ]

    @Test func webKitFindsEveryDelegateMethod() throws {
        let host = makeHost()
        let page = host.page(for: request(), writer: writer)
        let navigation = try delegate(of: page)
        #expect(page.webView.uiDelegate === navigation)
        let missing = Self.delegateSelectors.filter { !navigation.responds(to: NSSelectorFromString($0)) }
        #expect(missing.isEmpty, "WebKit will never call: \(missing)")
        host.close(page.tabID)
    }
}
