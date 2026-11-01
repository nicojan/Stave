import SwiftUI
import StaveCore

/// The native panel over a page that failed, was refused or crashed (decision 13): plain words from `PageText`, Reload, and Back when the
/// page has somewhere to go back to. It never reloads by itself.
struct PageFailureView: View {
    let failure: PageFailure
    let canGoBack: Bool
    let reload: () -> Void
    let back: () -> Void

    var body: some View {
        ZStack {
            Rectangle().fill(.background)
            VStack(spacing: 12) {
                Image(systemName: "exclamationmark.triangle")
                    .font(.system(size: 34))
                    .foregroundStyle(.secondary)
                    .accessibilityHidden(true)
                Text(PageText.title(failure)).font(.title2.bold()).multilineTextAlignment(.center)
                Text(PageText.detail(failure))
                    .foregroundStyle(.secondary).multilineTextAlignment(.center).lineLimit(6).textSelection(.enabled)
                HStack(spacing: 10) {
                    if canGoBack { Button(PageText.backButton, action: back) }
                    Button(PageText.reloadButton, action: reload).keyboardShortcut(.defaultAction)
                }
                .padding(.top, 4)
            }
            .frame(maxWidth: 440)
            .padding(32)
        }
        .accessibilityElement(children: .contain)
    }
}
