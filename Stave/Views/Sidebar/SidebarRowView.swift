import SwiftUI
import StaveCore
import StaveWeb

/// One row of the pinned tree or the regular tabs. Layout only: the label text, the actions and the enablement come from StaveCore.
struct SidebarRowView: View {
    let row: SidebarRow
    /// From `SidebarMenus`, including Move Up and Move Down where they apply.
    let actions: [SidebarAction]
    /// Move to Workspace for a tab row (`BrowserWindowModel.moveTargets`); none for a folder.
    var moves: MoveToWorkspaceMenu = .none
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
            .sidebarAccessibilityActions(actions, moves: moves) { perform($0, row.id) }
            if case .pinnedTab(drifted: true) = row.kind {
                Button { perform(.backToPinnedPage, row.id) } label: {
                    Image(systemName: "arrow.uturn.backward").font(.caption)
                }
                .buttonStyle(.borderless)
                .help(SidebarAction.backToPinnedPage.title)
                .accessibilityLabel(SidebarText.driftedLabel(title: row.title))
            }
        }
        .padding(.leading, CGFloat(row.depth) * 14)
        .accessibilityElement(children: .contain)
        .contentShape(Rectangle())
        .sidebarContextMenu(actions, moves: moves) { perform($0, row.id) }
    }

    @ViewBuilder
    private var disclosure: some View {
        if case .folder(let isOpen, _) = row.kind, case .folder(let id) = row.id {
            Button { setFolderOpen(id, !isOpen) } label: {
                Image(systemName: isOpen ? "chevron.down" : "chevron.right").font(.caption2.weight(.bold)).frame(width: 12)
            }
            .buttonStyle(.borderless)
            .accessibilityLabel(SidebarText.disclosureLabel(isOpen: isOpen, title: row.title))
        }
    }

    @ViewBuilder
    private var icon: some View {
        switch row.kind {
        case .folder(let isOpen, _):
            Image(systemName: isOpen ? "folder.fill" : "folder").foregroundStyle(.secondary).frame(width: 16)
        case .pinnedTab:
            // The pin stays as the row's badge; the favicon, else the monogram, sits beside it.
            HStack(spacing: 4) {
                Image(systemName: "pin.fill").font(.caption).foregroundStyle(.secondary).frame(width: 16)
                Favicon(url: row.faviconURL) { Monogram(letter: row.monogram) }
            }
        case .regularTab:
            Favicon(url: row.faviconURL) { Monogram(letter: row.monogram) }
        }
    }
}

extension EnvironmentValues {
    /// The window's favicon loader: the app's disk-cached one in a browser window, a memory-only one in a private window (decision 10).
    /// Nil shows every fallback and fetches nothing.
    @Entry var favicons: FaviconLoader? = nil
}

/// A tab's favicon when the loader has it cached (in memory or on disk), else `fallback`; it asks the loader to load the address once per
/// address and keeps what arrives. The image has no accessibility label of its own: the row's label already names the tab.
struct Favicon<Fallback: View>: View {
    let url: String?
    var side: CGFloat = 16
    @ViewBuilder let fallback: () -> Fallback

    @Environment(\.favicons) private var loader
    @State private var loaded: Loaded?

    private struct Loaded {
        let url: String
        let image: NSImage
    }

    var body: some View {
        Group {
            if let image = loaded.flatMap({ $0.url == url ? $0.image : nil }) ?? loader?.image(for: url) {
                Image(nsImage: image)
                    .resizable()
                    .interpolation(.high)
                    .frame(width: side, height: side)
                    .accessibilityHidden(true)
            } else {
                fallback()
            }
        }
        .task(id: url) {
            guard let url, let loader, let image = await loader.load(url) else { return }
            loaded = Loaded(url: url, image: image)
        }
    }
}

/// The favicon's fallback in a row: the tab's one-letter monogram (`DisplayText.monogram`) in a 16 pt tile, the small form of an
/// Essential tile. Hidden from VoiceOver, like the favicon.
struct Monogram: View {
    let letter: String?

    var body: some View {
        Text(letter ?? "?")
            .font(.system(size: 10, weight: .semibold))
            .foregroundStyle(.secondary)
            .frame(width: 16, height: 16)
            .background(.quaternary, in: RoundedRectangle(cornerRadius: 4))
            .accessibilityHidden(true)
    }
}
