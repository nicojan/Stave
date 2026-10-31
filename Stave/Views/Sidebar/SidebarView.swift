import AppKit
import SwiftUI
import StaveCore

/// The sidebar of one window: address field, Essentials, the pinned tree, a New Tab row and the regular tabs over the sidebar material,
/// tinted by the workspace colour. State here is layout and focus only; every rule lives in StaveCore.
struct SidebarView: View {
    @Bindable var model: BrowserWindowModel
    let openCommandBar: (CommandBarMode) -> Void

    @FocusState private var listFocused: Bool
    @State private var dismissedErrorID: Int?
    @State private var showArchive = false
    @State private var prompt: FolderPrompt?
    @State private var promptText = ""

    /// A folder action waiting for a name.
    private struct FolderPrompt: Identifiable {
        let id = UUID()
        let action: SidebarAction
        let item: SidebarItemID?
        let currentTitle: String
    }

    var body: some View {
        VStack(spacing: 0) {
            AddressField(tab: model.selectedTab) { openCommandBar(.currentTab) }
                .padding(.horizontal, 10).padding(.bottom, 8)
            if !model.snapshot.essentials.isEmpty {
                EssentialsGrid(
                    essentials: model.snapshot.essentials, selectedID: model.selectedTabID,
                    select: { model.select($0) }, perform: { request($0, on: .tab($1)) }
                )
                .padding(.horizontal, 10).padding(.bottom, 8)
            }
            list
            errorBanner
            bottomBar
        }
        .defaultFocus($listFocused, true)
        .padding(.top, 28) // clears the traffic lights, which sit over the sidebar
        .background { SidebarBackground(tintHex: model.snapshot.workspace.colorHex) }
        .ignoresSafeArea()
        .alert(prompt?.action.title ?? "", isPresented: Binding(get: { prompt != nil }, set: { if !$0 { prompt = nil } })) {
            TextField("Folder name", text: $promptText)
            Button("Cancel", role: .cancel) {}
            Button(prompt?.action == .renameFolder ? "Rename" : "Create") {
                if let prompt { model.run(prompt.action, on: prompt.item, typed: promptText) }
            }
        }
    }

    private var list: some View {
        List(selection: $model.sidebarHighlight) {
            Section {
                ForEach(model.rows.filter { !$0.isRegular }) { rowView($0) }
            } header: {
                Text(SidebarText.pinnedHeader)
                    .sidebarActions(SidebarMenus.pinnedHeaderActions) { request($0, on: nil) }
            }
            newTabRow
            ForEach(model.rows.filter(\.isRegular)) { rowView($0) }
        }
        .listStyle(.sidebar)
        .scrollContentBackground(.hidden)
        .focused($listFocused)
        .accessibilityLabel("Tabs")
        .onDeleteCommand { model.closeSelectedTab() }
        .onKeyPress(.leftArrow) { arrow(.left) }
        .onKeyPress(.rightArrow) { arrow(.right) }
        .onAppear {
            Task { listFocused = true } // after the window has made its first view key
            model.sidebarHighlight = model.selectedTabID.map { .tab($0) }
        }
        .onChange(of: model.sidebarHighlight) { _, new in
            if case .tab(let id)? = new { model.select(id) }
        }
        .onChange(of: model.selectedTabID) { _, new in
            if let new { model.sidebarHighlight = .tab(new) } else if case .tab? = model.sidebarHighlight { model.sidebarHighlight = nil }
        }
    }

    private func rowView(_ row: SidebarRow) -> some View {
        SidebarRowView(row: row, setFolderOpen: { model.setFolderOpen($0, $1) }, perform: { request($0, on: $1) })
            .tag(row.id)
    }

    private var newTabRow: some View {
        Button { openCommandBar(.newTab) } label: {
            HStack(spacing: 6) {
                Image(systemName: "plus").foregroundStyle(.secondary).frame(width: 16).accessibilityHidden(true)
                Text(SidebarText.newTabRow)
                Spacer(minLength: 0)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(SidebarText.newTabRow)
    }

    private var bottomBar: some View {
        HStack {
            Button { showArchive.toggle() } label: { Image(systemName: "archivebox") }
                .buttonStyle(.borderless)
                .help(SidebarText.archiveButton)
                .accessibilityLabel(SidebarText.archiveButton)
                .popover(isPresented: $showArchive, arrowEdge: .top) {
                    ArchivePopover(load: { model.archivedTabs() }, restore: { id in
                        showArchive = false
                        model.restoreArchived(id)
                    })
                }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 12).padding(.vertical, 8)
    }

    private func arrow(_ key: SidebarArrow) -> KeyPress.Result {
        guard let change = SidebarKeys.folderChange(highlight: model.sidebarHighlight, key: key, rows: model.rows) else { return .ignored }
        model.setFolderOpen(change.folderID, change.isOpen)
        return .handled
    }

    /// Runs the action, or asks for a name first when it needs one.
    private func request(_ action: SidebarAction, on item: SidebarItemID?) {
        guard action.needsTitle else {
            if let item { model.run(action, on: item) }
            return
        }
        let current = model.rows.first { $0.id == item }?.title ?? ""
        promptText = SidebarMenus.promptPrefill(action: action, currentTitle: current)
        prompt = FolderPrompt(action: action, item: item, currentTitle: current)
    }

    @ViewBuilder
    private var errorBanner: some View {
        if let message = model.lastError, model.lastErrorID != dismissedErrorID {
            HStack(alignment: .top, spacing: 8) {
                Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange).accessibilityHidden(true)
                Text(message).font(.callout).fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
                Button { dismissedErrorID = model.lastErrorID } label: { Image(systemName: "xmark") }
                    .buttonStyle(.borderless)
                    .accessibilityLabel("Dismiss message")
            }
            .padding(10)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8))
            .padding(8)
            .accessibilityElement(children: .contain)
        }
    }
}

/// The sidebar material with the workspace colour at 12% over it.
private struct SidebarBackground: View {
    let tintHex: String

    var body: some View {
        ZStack {
            VisualEffect(material: .sidebar)
            Color(hex: tintHex).opacity(0.12)
        }
    }
}

private struct VisualEffect: NSViewRepresentable {
    let material: NSVisualEffectView.Material

    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = material
        view.blendingMode = .behindWindow
        view.state = .followsWindowActiveState
        return view
    }

    func updateNSView(_ view: NSVisualEffectView, context: Context) { view.material = material }
}
