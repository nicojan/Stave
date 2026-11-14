import SwiftUI
import StaveCore

/// The native panel over a page that failed, was refused or crashed (decision 13): plain words from `PageText`, Reload (Open Again for a
/// stored file tab, nothing for a refused address in a tab with nothing loaded), and Back when the page has somewhere to go back to. It
/// never reloads by itself.
struct PageFailureView: View {
    let failure: PageFailure
    let canGoBack: Bool
    /// The page has a document loaded (`webView.url` isn't nil), so Reload has something to reload.
    let hasDocument: Bool
    let reload: () -> Void
    let back: () -> Void
    let openAgain: () -> Void

    var body: some View {
        let detail = PageText.detail(failure)
        ZStack {
            Rectangle().fill(.background)
            VStack(spacing: 12) {
                Image(systemName: "exclamationmark.triangle")
                    .font(.system(size: 34))
                    .foregroundStyle(.secondary)
                    .accessibilityHidden(true)
                Text(PageText.title(failure)).font(.title2.bold()).multilineTextAlignment(.center)
                Text(detail)
                    .foregroundStyle(.secondary).multilineTextAlignment(.center).lineLimit(6).textSelection(.enabled)
                    // A selectable Text exposes two AXStaticText elements (seen on macOS 27), so VoiceOver reads it twice. One plain Text
                    // stands in for VoiceOver, which can't select it; on screen it stays selectable.
                    .accessibilityRepresentation { Text(detail) }
                HStack(spacing: 10) {
                    if canGoBack { Button(PageText.backButton, action: back) }
                    if PageText.offersOpenAgain(failure) {
                        Button(PageText.openAgainButton, action: openAgain).keyboardShortcut(.defaultAction)
                    } else if PageText.offersReload(failure, hasDocument: hasDocument) {
                        Button(PageText.reloadButton, action: reload).keyboardShortcut(.defaultAction)
                    }
                }
                .padding(.top, 4)
            }
            .frame(maxWidth: 440)
            .padding(32)
        }
        .accessibilityElement(children: .contain)
    }
}
