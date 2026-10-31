import SwiftUI
import StaveCore

/// The archive, newest first, with a search field. Return or the Restore button restores a row.
struct ArchivePopover: View {
    let load: () -> [ArchivedTab]
    let restore: (UUID) -> Void

    @State private var items: [ArchivedTab] = []
    @State private var query = ""
    @State private var selection: UUID?
    @FocusState private var searchFocused: Bool

    private var results: [ArchivedTab] { ArchiveFilter.results(items, query: query) }

    var body: some View {
        VStack(spacing: 0) {
            TextField(SidebarText.searchArchive, text: $query)
                .textFieldStyle(.roundedBorder)
                .focused($searchFocused)
                .accessibilityLabel(SidebarText.searchArchive)
                .onSubmit { restoreTarget() }
                .padding(10)
            Divider()
            if results.isEmpty {
                Text(ArchiveFilter.emptyMessage(archiveCount: items.count))
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, minHeight: 80)
            } else {
                List(results, selection: $selection) { tab in row(tab).tag(tab.id) }
                    .listStyle(.plain)
                    .accessibilityLabel(SidebarText.archivedTabs)
                    .onKeyPress(.return) { restoreTarget(); return .handled }
            }
        }
        .frame(width: 320, height: 360)
        .onAppear {
            items = load()
            Task { searchFocused = true } // after the popover's window has become key
        }
    }

    private func row(_ tab: ArchivedTab) -> some View {
        let title = DisplayText.title(title: tab.title, url: tab.url)
        return HStack(spacing: 8) {
            VStack(alignment: .leading, spacing: 1) {
                Text(title).lineLimit(1)
                if !tab.url.isEmpty { Text(tab.url).font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle) }
            }
            Spacer(minLength: 0)
            Button(SidebarText.restoreButton) { restore(tab.id) }
                .buttonStyle(.borderless)
                .accessibilityLabel(SidebarText.restoreLabel(title: title))
        }
    }

    private func restoreTarget() {
        if let id = ArchiveFilter.restoreTarget(in: results, selected: selection) { restore(id) }
    }
}
