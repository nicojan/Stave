import AppKit
import SwiftUI
import StaveCore

/// The sidebar of one window: address field, Essentials, the pinned tree, a New Tab row and the regular tabs over the sidebar material,
/// tinted by the workspace colour. State here is layout and focus only; every rule lives in StaveCore.
struct SidebarView: View {
    @Bindable var model: BrowserWindowModel
    let presenter: SidebarPresenter
    let openCommandBar: (CommandBarMode) -> Void

    @FocusState private var listFocused: Bool
    @State private var dismissedErrorID: Int?
    @State private var newProfileName = ""
    @State private var prompt: FolderPrompt?
    @State private var promptText = ""
    @State private var slide: CGFloat = 0
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// How far the new workspace's list starts from its resting place, and how far it travels in 0.2 s (decision 18).
    private static let slideDistance: CGFloat = 40
    private static let slideDuration = 0.2

    private var drag: SidebarDragState { presenter.drag }

    /// A folder action waiting for a name.
    private struct FolderPrompt: Identifiable {
        let id = UUID()
        let action: SidebarAction
        let item: SidebarItemID?
        let currentTitle: String
    }

    var body: some View {
        VStack(spacing: 0) {
            // The swipe catcher covers everything above the bottom bar, so a swipe that starts on the workspace strip only scrolls the strip.
            VStack(spacing: 0) {
                AddressField(tab: model.selectedTab) { openCommandBar(.currentTab) }
                    .padding(.horizontal, 10).padding(.bottom, 8)
                if !model.snapshot.essentials.isEmpty {
                    EssentialsGrid(
                        model: model, drag: drag,
                        select: { model.select($0) }, perform: { request($0, on: .tab($1)) }
                    )
                    .padding(.horizontal, 10).padding(.bottom, 8)
                } else if drag.isDraggingTab {
                    EssentialsEmptyDrop(model: model, drag: drag)
                        .padding(.horizontal, 10).padding(.bottom, 8)
                }
                list
                    .offset(x: slide)
                    .opacity(1 - 0.6 * Double(abs(slide) / Self.slideDistance))
                    .clipped()
                errorBanner
            }
            .background { SwipeCatcher { model.switchWorkspace(offset: $0) } }
            bottomBar
        }
        .defaultFocus($listFocused, !model.isCompact)
        .onChange(of: presenter.sidebarFocusRequest) {
            // Clear, then set on the next turn, as after the command bar: a stale-true flag would give nothing the focus.
            listFocused = false
            Task { @MainActor in listFocused = true }
        }
        .onChange(of: model.isCompact) { _, compact in
            // A hidden sidebar must not keep the keyboard; showing it again gives the list the focus back.
            listFocused = !compact
        }
        .onChange(of: model.snapshot.workspace.id) { slideIn() }
        .onChange(of: presenter.commandBar == nil) { _, closed in
            guard closed, presenter.returnsFocusToList else { return }
            // Escape, a click outside or a performed row: back to the list. The flag can still read true while the text field held the real
            // focus, so it is cleared first and set on the next turn.
            listFocused = false
            Task { @MainActor in listFocused = true }
        }
        .padding(.top, 28) // clears the traffic lights, which sit over the sidebar
        .background { SidebarBackground(tintHex: model.snapshot.workspace.colorHex) }
        .ignoresSafeArea()
        .alert(prompt?.action.title ?? "", isPresented: Binding(get: { prompt != nil }, set: { if !$0 { prompt = nil } })) {
            TextField(SidebarText.folderName, text: $promptText)
            Button("Cancel", role: .cancel) {}
            Button(prompt.map { SidebarText.promptConfirm(for: $0.action) } ?? "") {
                if let prompt { model.run(prompt.action, on: prompt.item, typed: promptText) }
            }
        }
    }

    private var list: some View {
        List(selection: $model.sidebarHighlight) {
            Section {
                ForEach(model.rows.filter { !$0.isRegular }) { rowView($0) }
                if drag.isDraggingItem { pinnedEndZone }
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
        .accessibilityLabel(SidebarText.tabs)
        .onDeleteCommand { model.closeHighlightedTab() }
        .onKeyPress(.leftArrow) { arrow(.left) }
        .onKeyPress(.rightArrow) { arrow(.right) }
        .onAppear {
            Task { listFocused = !model.isCompact } // after the window has made its first view key; a compact window starts with the sidebar hidden
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
        SidebarRowView(
            row: row, actions: SidebarMenus.actions(for: row, in: model.snapshot),
            setFolderOpen: { model.setFolderOpen($0, $1) }, perform: { request($0, on: $1) }
        )
        .tag(row.id)
        .sidebarRowDrop(model: model, drag: drag, row: row)
    }

    /// A gap after the last pinned row, present only while something is dragged so the resting list has no extra space: the place to drop to put something at the end of the pinned root, also when it is empty.
    private var pinnedEndZone: some View {
        Color.clear
            .frame(height: 12)
            .overlay { if drag.target == .pinnedEnd { InsertionLine() } }
            .listRowSeparator(.hidden)
            .selectionDisabled()
            .onDrop(of: SidebarDragState.acceptedTypes, delegate: FixedDropDelegate(model: model, drag: drag, target: .pinnedEnd))
            .accessibilityHidden(true)
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
        .overlay { if drag.target == .regularTop { InsertionLine().frame(maxHeight: .infinity, alignment: .bottom) } }
        .onDrop(of: SidebarDragState.acceptedTypes, delegate: FixedDropDelegate(model: model, drag: drag, target: .regularTop))
    }

    private var bottomBar: some View {
        HStack {
            Button { presenter.showArchive.toggle() } label: { Image(systemName: "archivebox") }
                .buttonStyle(.borderless)
                .help(SidebarText.archiveButton)
                .accessibilityLabel(SidebarText.archiveButton)
                .popover(isPresented: Binding(get: { presenter.showArchive }, set: { presenter.showArchive = $0 }), arrowEdge: .trailing) {
                    ArchivePopover(load: { model.archivedTabs() }, restore: { id in
                        presenter.showArchive = false
                        model.restoreArchived(id)
                    })
                }
            if WorkspaceMenus.showsProfileMenu(profileCount: model.profiles.count) {
                ProfileMenu(model: model, presenter: presenter)
            }
            WorkspaceSwitcher(model: model, presenter: presenter, drag: drag)
        }
        .padding(.horizontal, 12).padding(.vertical, 8)
        .alert(WorkspaceMenus.newProfilePrompt, isPresented: Binding(get: { presenter.showNewProfile }, set: { presenter.showNewProfile = $0 })) {
            TextField(WorkspaceMenus.profileName, text: $newProfileName)
            Button(WorkspaceEditorRules.cancelButton, role: .cancel) {}
            Button(WorkspaceMenus.createProfileButton) {
                if let name = WorkspaceMenus.profileName(typed: newProfileName) { model.createProfile(name: name) }
            }
        }
        .onChange(of: presenter.showNewProfile) { _, shown in if shown { newProfileName = "" } }
    }

    /// Slides the new workspace's list in from the direction of travel; nothing under Reduce Motion, and nothing for a profile switch (direction 0).
    private func slideIn() {
        let direction = model.lastSwitchDirection
        guard !reduceMotion, direction != 0 else { return }
        var instant = Transaction()
        instant.disablesAnimations = true
        withTransaction(instant) { slide = CGFloat(direction) * Self.slideDistance }
        Task { @MainActor in // next turn, so the start offset is drawn before the animation to rest
            withAnimation(.easeOut(duration: Self.slideDuration)) { slide = 0 }
        }
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
                    .accessibilityLabel(SidebarText.dismissMessage)
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
