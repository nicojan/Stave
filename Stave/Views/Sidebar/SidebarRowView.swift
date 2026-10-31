import SwiftUI
import StaveCore

/// One row of the pinned tree or the regular tabs. Layout only: the label text, the actions and the enablement come from StaveCore.
struct SidebarRowView: View {
    let row: SidebarRow
    let setFolderOpen: (UUID, Bool) -> Void
    let perform: (SidebarAction, SidebarItemID) -> Void

    var body: some View {
        HStack(spacing: 6) {
            disclosure
            HStack(spacing: 6) {
                icon
                Text(row.title).lineLimit(1).truncationMode(.tail)
                Spacer(minLength: 0)
                if let hex = row.containerColorHex {
                    Circle().fill(Color(hex: hex)).frame(width: 7, height: 7).accessibilityHidden(true)
                }
            }
            .accessibilityElement(children: .combine)
            .accessibilityLabel(row.accessibilityLabel)
            .sidebarActions(SidebarMenus.actions(for: row)) { perform($0, row.id) }
            if case .pinnedTab(drifted: true) = row.kind {
                Button { perform(.backToPinnedPage, row.id) } label: {
                    Image(systemName: "arrow.uturn.backward").font(.caption)
                }
                .buttonStyle(.borderless)
                .help(SidebarAction.backToPinnedPage.title)
                .accessibilityLabel(SidebarText.driftedButton)
            }
        }
        .padding(.leading, CGFloat(row.depth) * 14)
        .accessibilityElement(children: .contain)
    }

    @ViewBuilder
    private var disclosure: some View {
        if case .folder(let isOpen, _) = row.kind, case .folder(let id) = row.id {
            Button { setFolderOpen(id, !isOpen) } label: {
                Image(systemName: isOpen ? "chevron.down" : "chevron.right").font(.caption2.weight(.bold)).frame(width: 12)
            }
            .buttonStyle(.borderless)
            .accessibilityLabel(isOpen ? "Close folder" : "Open folder")
        }
    }

    @ViewBuilder
    private var icon: some View {
        switch row.kind {
        case .folder(let isOpen, _):
            Image(systemName: isOpen ? "folder.fill" : "folder").foregroundStyle(.secondary).frame(width: 16)
        case .pinnedTab:
            Image(systemName: "pin.fill").font(.caption).foregroundStyle(.secondary).frame(width: 16)
        case .regularTab:
            Image(systemName: "globe").foregroundStyle(.secondary).frame(width: 16)
        }
    }
}
