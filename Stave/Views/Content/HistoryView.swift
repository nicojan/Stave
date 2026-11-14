import SwiftUI
import StaveCore

/// History ▸ Show All History (⌘Y): the profile's visits in place of the page (decision 9, question 16). A focused search field, visits
/// newest first grouped by local day, Return or double-click to open, Delete to remove the selected visits, and Clear History….
/// The state is `HistoryBrowser`'s; this view holds only focus.
struct HistoryView: View {
    let browser: HistoryBrowser
    /// Changes each time the window asks for the search field (⌘Y), after it took the keyboard from the sidebar or the page.
    let focusSerial: Int
    let open: (HistoryVisit) -> Void
    let clear: () -> Void

    @FocusState private var searchFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            if browser.visits.isEmpty {
                emptyState
            } else {
                list
            }
        }
        .background(Color(nsColor: .windowBackgroundColor))
        .onAppear { Task { @MainActor in searchFocused = true } } // after the view is in the window
        .onChange(of: focusSerial) {
            // Clear, then set on the next turn, as the sidebar does: a stale-true flag would give nothing the focus.
            searchFocused = false
            Task { @MainActor in searchFocused = true }
        }
    }

    private var header: some View {
        HStack(spacing: 12) {
            Text(HistoryText.title).font(.title2.weight(.semibold))
                .accessibilityAddTraits(.isHeader)
            Spacer()
            TextField(HistoryText.searchPlaceholder, text: Binding(get: { browser.query }, set: { browser.query = $0 }))
                .textFieldStyle(.roundedBorder)
                .frame(maxWidth: 280)
                .focused($searchFocused)
                .accessibilityLabel(HistoryText.searchLabel)
                .onSubmit { openSelection(clicked: nil) }
            Button(HistoryText.delete) { browser.deleteSelected() }
                .disabled(browser.selection.isEmpty)
                .accessibilityLabel(HistoryText.delete)
            Button(HistoryText.clearButton, action: clear)
                .accessibilityLabel(HistoryText.clearButton)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 12)
    }

    private var emptyState: some View {
        Text(HistoryText.emptyState(searching: !browser.query.trimmingCharacters(in: .whitespaces).isEmpty))
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var list: some View {
        List(selection: Binding(get: { browser.selection }, set: { browser.selection = $0 })) {
            ForEach(browser.sections) { section in
                Section(section.heading) {
                    ForEach(section.visits) { visit in
                        row(visit)
                            .tag(visit.id)
                            .onAppear { if visit.id == browser.visits.last?.id { browser.loadMore() } }
                    }
                }
            }
        }
        .accessibilityLabel(HistoryText.listLabel)
        // Double-click and Return open; on macOS the primary action covers both.
        .contextMenu(forSelectionType: UUID.self, menu: { _ in EmptyView() }, primaryAction: { ids in
            openSelection(clicked: ids.count == 1 ? ids.first : nil)
        })
        .onDeleteCommand { browser.deleteSelected() }
    }

    private func row(_ visit: HistoryVisit) -> some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(HistoryText.rowTitle(visit)).lineLimit(1)
                Text(HistoryText.rowAddress(visit)).font(.callout).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer()
            Text(HistoryText.rowTime(visit, calendar: browser.calendar, locale: browser.locale))
                .font(.callout).foregroundStyle(.secondary).monospacedDigit()
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(HistoryText.rowLabel(visit, calendar: browser.calendar, locale: browser.locale))
    }

    private func openSelection(clicked: UUID?) {
        guard let visit = browser.visitToOpen(clicked: clicked) else { return }
        open(visit)
    }
}
