import SwiftUI
import StaveCore

/// The content area without a page: a blank tab's "New Tab" state with the ⌘L hint, or no tab selected with a New Tab button.
struct TabPlaceholderView: View {
    enum Kind { case blank, empty }

    let kind: Kind
    let newTab: () -> Void

    var body: some View {
        ZStack {
            Color(nsColor: .windowBackgroundColor).ignoresSafeArea()
            content.padding(32)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    @ViewBuilder
    private var content: some View {
        switch kind {
        case .blank:
            VStack(spacing: 10) {
                Text(PageText.newTabTitle).font(.title2.bold())
                Text(PageText.newTabHint).foregroundStyle(.secondary)
            }
            .accessibilityElement(children: .combine)
        case .empty:
            VStack(spacing: 12) {
                Text("No tab selected").font(.title2).foregroundStyle(.secondary)
                Button(PageText.newTabTitle, action: newTab)
                    .accessibilityLabel(PageText.newTabTitle)
            }
        }
    }
}
