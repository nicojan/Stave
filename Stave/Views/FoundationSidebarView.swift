import SwiftUI
import StaveCore

/// Read-only snapshot of one workspace: Essentials, pinned tree, regular tabs. Plan 4 replaces this.
struct FoundationSidebarView: View {
    @ObservedObject var environment: AppEnvironment
    let workspaceID: UUID

    @State private var snapshot: SidebarSnapshot?
    @State private var loadError: String?

    var body: some View {
        List {
            if let snapshot {
                Text(snapshot.workspace.name).font(.title2.bold())
                Section("Essentials") { tabRows(snapshot.essentials) }
                Section("Pinned") { pinnedRows(snapshot.pinned) }
                Section("Tabs") { tabRows(snapshot.regular) }
            } else if let loadError {
                Text(loadError).foregroundStyle(.secondary)
            }
        }
        .frame(minWidth: 240, minHeight: 320)
        .onAppear(perform: reload)
        .onChange(of: environment.refreshToken) { reload() }
    }

    @ViewBuilder
    private func tabRows(_ tabs: [StaveCore.Tab]) -> some View {
        if tabs.isEmpty {
            Text("Empty").foregroundStyle(.secondary)
        } else {
            ForEach(tabs) { Text(environment.store.displayTitle(for: $0)) }
        }
    }

    @ViewBuilder
    private func pinnedRows(_ items: [PinnedItem]) -> some View {
        if items.isEmpty {
            Text("Empty").foregroundStyle(.secondary)
        } else {
            PinnedTree(items: items, store: environment.store)
        }
    }

    private func reload() {
        do {
            snapshot = try environment.store.sidebarSnapshot(workspaceID: workspaceID)
            loadError = nil
        } catch {
            loadError = "Could not read this workspace: \(error)"
        }
    }
}

/// Pinned items, with one level of folders (the store allows no deeper nesting).
private struct PinnedTree: View {
    let items: [PinnedItem]
    let store: OrganizationStore

    var body: some View {
        ForEach(Array(items.enumerated()), id: \.offset) { _, item in
            switch item {
            case .tab(let tab):
                Text(store.displayTitle(for: tab))
            case .folder(let folder, let children):
                DisclosureGroup(folder.title) {
                    PinnedTree(items: children, store: store)
                }
            }
        }
    }
}
