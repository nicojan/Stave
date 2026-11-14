import ChorusEngine
import Observation
import SwiftUI
import StaveCore
import StaveWeb

/// What the content area reads besides the model and the page host. Owned by the window controller.
@MainActor @Observable
final class PageViewState {
    /// Bumped when another window's snapshot may have landed; snapshots themselves are not observable.
    var snapshotRevision = 0
}

/// What the content area asks of its window controller.
struct PageAreaActions {
    var reload: () -> Void
    var back: () -> Void
}

/// The content area: the selected tab's live page, the "showing in another window" snapshot, a blank tab, or no selection.
struct PageArea: View {
    let model: BrowserWindowModel
    let pageHost: PageHost
    let state: PageViewState
    let actions: PageAreaActions

    var body: some View {
        if let tab = model.selectedTab {
            if case .elsewhere = model.placement {
                ElsewhereView(
                    title: DisplayText.title(for: tab),
                    snapshot: snapshot(of: tab.id),
                    bringHere: { model.bringSelectedHere() }
                )
            } else if let page = pageHost.existingPage(tab.id) {
                PageContentView(page: page, actions: actions)
            } else if tab.url.isEmpty {
                TabPlaceholderView(kind: .blank, newTab: {})
            } else {
                Color(nsColor: .windowBackgroundColor) // the page is being made
            }
        } else {
            TabPlaceholderView(kind: .empty, newTab: { model.openTab(url: "") })
        }
    }

    private func snapshot(of tabID: UUID) -> NSImage? {
        _ = state.snapshotRevision
        return pageHost.snapshot(for: tabID)
    }
}

/// One live page: the web view, a 2 pt progress bar while it loads, and the failure panel over it.
struct PageContentView: View {
    let page: LivePage
    let actions: PageAreaActions

    private static let barHeight: CGFloat = 2

    var body: some View {
        ZStack(alignment: .top) {
            // No `parking:`. The engine's WebViewParking comes only from its own
            // WebViewPool, which Stave doesn't use, so a page that leaves this
            // container leaves the window and WebKit may suspend it.
            WebViewContainer(webView: page.webView)
            if page.status.isLoading {
                progressBar
            }
            if let failure = page.status.failure {
                PageFailureView(failure: failure, canGoBack: page.status.canGoBack, reload: actions.reload, back: actions.back)
            }
        }
        .ignoresSafeArea()
    }

    private var progressBar: some View {
        GeometryReader { proxy in
            Rectangle()
                .fill(Color.accentColor)
                .frame(width: proxy.size.width * min(max(page.status.progress, 0.05), 1), height: Self.barHeight)
        }
        .frame(height: Self.barHeight)
        .accessibilityElement()
        .accessibilityLabel("Loading")
        .accessibilityValue("\(Int(page.status.progress * 100)) percent")
    }
}

/// The tab's page is live in another window: its last snapshot, dimmed, under the title and the "Bring It Here" button.
struct ElsewhereView: View {
    let title: String
    let snapshot: NSImage?
    let bringHere: () -> Void

    var body: some View {
        ZStack {
            Color(nsColor: .windowBackgroundColor)
            if let snapshot {
                Image(nsImage: snapshot)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                    .clipped()
                    .opacity(0.25)
                    .accessibilityHidden(true)
            }
            VStack(spacing: 12) {
                Text(PageText.elsewhereTitle).font(.title2)
                Text(title).foregroundStyle(.secondary).lineLimit(2)
                Button(PageText.bringHereButton, action: bringHere)
                    .accessibilityLabel(PageText.bringHereButton)
            }
            .padding(28)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16))
        }
        .ignoresSafeArea()
    }
}
