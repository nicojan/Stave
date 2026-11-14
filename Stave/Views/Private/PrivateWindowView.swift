import SwiftUI
import StaveCore
import StaveWeb

/// A private window's content: a dark-tinted sidebar with "Private" at the top and a plain tab list (no Essentials, pinned tabs, workspaces
/// or archive), beside the same page area as a browser window. Holds layout and focus only; strings and rules come from StaveCore.
struct PrivateWindowView: View {
    @Bindable var model: PrivateWindowModel
    let presenter: SidebarPresenter
    let pageHost: PageHost
    let downloads: DownloadList
    let sidebarWidth: Double
    let actions: PageAreaActions

    @FocusState private var listFocused: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private static let fadeDuration = 0.12

    var body: some View {
        HStack(spacing: 0) {
            sidebar
                .frame(width: sidebarWidth)
            Rectangle().fill(Color(nsColor: .separatorColor)).frame(width: 1)
            content
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .fileDrop(actions.openDroppedFile)
        .overlay { commandBarLayer }
    }

    // MARK: - Sidebar

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 0) {
            Label(PrivateWindowText.sidebarTitle, systemImage: "eyeglasses")
                .font(.headline)
                .padding(.horizontal, 14).padding(.bottom, 8)
                .accessibilityAddTraits(.isHeader)
            Button { presenter.openCommandBar(.newTab, for: model) } label: {
                Label(PrivateWindowText.newTabButton, systemImage: "plus").frame(maxWidth: .infinity, alignment: .leading)
            }
            .buttonStyle(.borderless)
            .padding(.horizontal, 14).padding(.bottom, 6)
            .accessibilityLabel(PrivateWindowText.newTabButton)
            list
            HStack {
                Spacer()
                DownloadsButton(downloads: downloads, owner: .privateWindow(model.windowID))
            }
            .padding(10)
        }
        .padding(.top, 28) // clears the traffic lights
        .background(Color(red: 0.13, green: 0.11, blue: 0.20))
        .environment(\.colorScheme, .dark)
        .ignoresSafeArea()
        .onChange(of: presenter.commandBar == nil) { _, closed in
            guard closed, presenter.returnsFocusToList else { return }
            listFocused = false
            Task { @MainActor in listFocused = true }
        }
    }

    private var list: some View {
        List(selection: Binding(get: { model.selectedTabID }, set: { model.select($0) })) {
            ForEach(model.tabs) { tab in
                row(tab).tag(tab.id)
            }
        }
        .listStyle(.sidebar)
        .scrollContentBackground(.hidden)
        .focused($listFocused)
        .accessibilityLabel(PrivateWindowText.tabListLabel)
        .onDeleteCommand { if let id = model.selectedTabID { model.close(id) } }
        .onAppear { Task { listFocused = true } }
    }

    private func row(_ tab: PrivateTab) -> some View {
        let title = PrivateWindowText.title(for: tab)
        return HStack(spacing: 6) {
            Text(title).lineLimit(1).truncationMode(.tail)
            Spacer(minLength: 4)
            Button { model.close(tab.id) } label: { Image(systemName: "xmark") }
                .buttonStyle(.borderless)
                .accessibilityLabel(PrivateWindowText.closeTabLabel)
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(title)
        .contextMenu {
            Button(PrivateWindowText.closeTabLabel) { model.close(tab.id) }
        }
    }

    // MARK: - Content

    @ViewBuilder
    private var content: some View {
        if let tab = model.selectedTab {
            if let page = pageHost.existingPage(tab.id) {
                PageContentView(page: page, actions: actions)
            } else if tab.url.isEmpty {
                TabPlaceholderView(kind: .blank, newTab: {})
            } else {
                Color(nsColor: .windowBackgroundColor) // the page is being made
            }
        } else {
            VStack(spacing: 12) {
                Text(PrivateWindowText.sidebarTitle).font(.title2.bold())
                Text(PrivateWindowText.emptyHint).foregroundStyle(.secondary).multilineTextAlignment(.center)
                Button(PrivateWindowText.newTabButton) { presenter.openCommandBar(.newTab, for: model) }
                    .accessibilityLabel(PrivateWindowText.newTabButton)
            }
            .padding(32)
            .frame(maxWidth: 420)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Color(nsColor: .windowBackgroundColor))
        }
    }

    private var commandBarLayer: some View {
        ZStack {
            if let bar = presenter.commandBar {
                CommandBarView(bar: bar, activate: { presenter.activate(in: model) }, close: { presenter.closeCommandBar() })
                    .transition(.opacity)
            }
        }
        .animation(reduceMotion ? nil : .easeInOut(duration: Self.fadeDuration), value: presenter.commandBar != nil)
    }
}
