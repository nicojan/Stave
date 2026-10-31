import SwiftUI
import StaveCore

/// The content area until the web engine is connected: a card for the selected tab, the "elsewhere" state, or the empty state.
struct TabPlaceholderView: View {
    let model: BrowserWindowModel

    var body: some View {
        ZStack {
            Color(nsColor: .windowBackgroundColor).ignoresSafeArea()
            content
                .padding(32)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    @ViewBuilder
    private var content: some View {
        if let tab = model.selectedTab {
            if case .elsewhere = model.placement {
                elsewhere(tab)
            } else {
                card(tab)
            }
        } else {
            empty
        }
    }

    private var empty: some View {
        VStack(spacing: 12) {
            Text("No tab selected").font(.title2).foregroundStyle(.secondary)
            Button("New Tab") { model.openTab(url: "") }
                .accessibilityLabel("New Tab")
        }
    }

    private func elsewhere(_ tab: StaveCore.Tab) -> some View {
        VStack(spacing: 12) {
            Text("Showing in another window").font(.title2)
            Text(DisplayText.title(for: tab)).foregroundStyle(.secondary).lineLimit(2)
            Button("Bring It Here") { model.bringSelectedHere() }
                .accessibilityLabel("Bring It Here")
        }
    }

    private func card(_ tab: StaveCore.Tab) -> some View {
        VStack(spacing: 14) {
            Text(DisplayText.monogram(for: tab))
                .font(.system(size: 34, weight: .semibold))
                .frame(width: 72, height: 72)
                .background(.quaternary, in: RoundedRectangle(cornerRadius: 16))
                .accessibilityHidden(true)
            Text(DisplayText.title(for: tab)).font(.title2.bold()).lineLimit(3).multilineTextAlignment(.center)
            if !tab.url.isEmpty {
                Text(tab.url).font(.callout).foregroundStyle(.secondary).lineLimit(2).textSelection(.enabled)
            }
            Text("Pages load here once Stave's web engine is connected.")
                .font(.callout).foregroundStyle(.tertiary).multilineTextAlignment(.center)
            if tab.isDrifted {
                Button(SidebarAction.backToPinnedPage.title) { model.resetPinned(tab.id) }
                    .accessibilityLabel(SidebarAction.backToPinnedPage.title)
            }
        }
        .frame(maxWidth: 420)
        .padding(28)
        .background(.background.secondary, in: RoundedRectangle(cornerRadius: 20))
        .accessibilityElement(children: .contain)
    }
}
