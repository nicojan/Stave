import AppKit
import SwiftUI
import StaveCore

/// One button per workspace of the window's profile, tinted with its colour and highlighted when current, plus a "+" button. The context
/// menu and the VoiceOver actions come from one `WorkspaceMenus` list. Rules live in StaveCore; this view holds only the dialogs' state.
struct WorkspaceSwitcher: View {
    @Bindable var model: BrowserWindowModel
    @Bindable var presenter: SidebarPresenter
    let drag: SidebarDragState

    @State private var pendingDelete: Workspace?

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 4) {
                ForEach(Array(model.workspaces.enumerated()), id: \.element.id) { index, workspace in
                    button(for: workspace, index: index)
                }
                Button { presenter.workspaceEditor = .create } label: {
                    Image(systemName: "plus").frame(width: 28, height: 28).contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help(WorkspaceMenus.newWorkspaceButton)
                .accessibilityLabel(WorkspaceMenus.newWorkspaceButton)
            }
            .padding(.horizontal, 2)
        }
        .sheet(item: $presenter.workspaceEditor) { mode in
            WorkspaceEditor(mode: mode, save: { draft in
                apply(draft, for: mode)
                presenter.workspaceEditor = nil
            }, cancel: { presenter.workspaceEditor = nil })
        }
        .alert(
            pendingDelete.map { WorkspaceMenus.deleteConfirmation(name: $0.name) } ?? "",
            isPresented: Binding(get: { pendingDelete != nil }, set: { if !$0 { pendingDelete = nil } })
        ) {
            Button(WorkspaceMenus.deleteButton, role: .destructive) {
                if let pendingDelete { model.deleteWorkspace(pendingDelete.id) }
                pendingDelete = nil
            }
            Button(WorkspaceEditorRules.cancelButton, role: .cancel) { pendingDelete = nil }
        }
    }

    private func button(for workspace: Workspace, index: Int) -> some View {
        let isCurrent = workspace.id == model.snapshot.workspace.id
        let items = WorkspaceMenus.items(index: index, count: model.workspaces.count)
        let tint = Color(hex: workspace.colorHex)
        return Button { model.switchWorkspace(to: workspace.id) } label: {
            WorkspaceIconView(icon: WorkspaceIcon(stored: workspace.icon), tint: tint)
                .frame(width: 28, height: 28)
                .background(isCurrent ? tint.opacity(0.28) : .clear, in: RoundedRectangle(cornerRadius: 7))
                .contentShape(RoundedRectangle(cornerRadius: 7))
        }
        .buttonStyle(.plain)
        .help(workspace.name)
        .modifier(WorkspaceButtonDrop(model: model, drag: drag, workspace: workspace))
        .accessibilityLabel(SidebarLabels.workspace(name: workspace.name, position: index + 1, count: model.workspaces.count, isCurrent: isCurrent))
        .accessibilityAddTraits(isCurrent ? .isSelected : [])
        .contextMenu {
            ForEach(items, id: \.action) { item in
                Button(role: item.action == .delete ? .destructive : nil) { run(item.action, on: workspace, index: index) } label: {
                    Label(item.action.title, systemImage: item.action.symbol)
                }
                .disabled(!item.isEnabled)
            }
        }
        .accessibilityActions {
            ForEach(items.filter(\.isEnabled), id: \.action) { item in
                Button(item.action.title) { run(item.action, on: workspace, index: index) }
            }
        }
    }

    private func run(_ action: WorkspaceAction, on workspace: Workspace, index: Int) {
        switch action {
        case .edit: presenter.workspaceEditor = .edit(workspace)
        case .delete: pendingDelete = workspace
        case .moveLeft, .moveRight:
            if let target = WorkspaceMenus.moveTarget(action, index: index, ids: model.workspaces.map(\.id)) {
                model.moveWorkspace(workspace.id, after: target.afterID)
            }
        }
    }

    private func apply(_ draft: WorkspaceDraft, for mode: WorkspaceEditorMode) {
        switch mode {
        case .create: model.createWorkspace(name: draft.name, icon: draft.icon, colorHex: draft.colorHex)
        case .edit(let workspace): model.updateWorkspace(workspace.id, name: draft.name, icon: draft.icon, colorHex: draft.colorHex)
        }
    }
}

/// Drag source and drop target for one workspace button. A dragged workspace button reorders (the left half of a button is the gap before it,
/// the right half the gap after); a dragged tab dropped on the button moves the tab there (decision 39). The two are told apart by the app's
/// current-drag state, never by the pasteboard, and a workspace drag is never accepted as a tab drop.
private struct WorkspaceButtonDrop: ViewModifier {
    let model: BrowserWindowModel
    let drag: SidebarDragState
    let workspace: Workspace

    private static let width: CGFloat = 28

    func body(content: Content) -> some View {
        content
            .overlay { indicator }
            .onDrag {
                drag.begin(.workspace(workspace.id))
                return NSItemProvider(object: workspace.name as NSString)
            }
            .onDrop(of: SidebarDragState.acceptedTypes, delegate: WorkspaceDropDelegate(model: model, drag: drag, workspace: workspace, width: Self.width))
    }

    @ViewBuilder
    private var indicator: some View {
        if let slot = drag.workspaceSlot, slot.workspaceID == workspace.id {
            InsertionLine()
                .frame(width: 2, height: 28)
                .frame(maxWidth: .infinity, alignment: slot.side == .before ? .leading : .trailing)
                .offset(x: slot.side == .before ? -3 : 3)
        } else if case .workspace(let id)? = drag.target, id == workspace.id {
            DropHighlight(cornerRadius: 7)
        }
    }
}

@MainActor
private struct WorkspaceDropDelegate: DropDelegate {
    let model: BrowserWindowModel
    let drag: SidebarDragState
    let workspace: Workspace
    let width: CGFloat

    func validateDrop(info: DropInfo) -> Bool { drag.payload != nil }

    func dropUpdated(info: DropInfo) -> DropProposal? {
        let owner = AnyHashable(workspace.id)
        switch drag.payload {
        case .workspace(let dragged)?:
            let side: DropPosition = info.location.x < width / 2 ? .before : .after
            let planned = model.plannedWorkspaceMove(dragging: dragged, onto: workspace.id, side: side) != nil
            drag.hoverWorkspace(planned ? WorkspaceSlot(workspaceID: workspace.id, side: side) : nil, owner: owner)
            return DropProposal(operation: planned ? .move : .forbidden)
        case .item(let item)?:
            let planned = model.plannedMove(dragging: item, onto: .workspace(workspace.id)) != nil
            drag.hover(planned ? .workspace(workspace.id) : nil, owner: owner)
            return DropProposal(operation: planned ? .move : .forbidden)
        case nil:
            return DropProposal(operation: .forbidden)
        }
    }

    func dropExited(info: DropInfo) { drag.leave(owner: AnyHashable(workspace.id)) }

    func performDrop(info: DropInfo) -> Bool {
        defer { drag.end() }
        switch drag.payload {
        case .workspace(let dragged)?:
            return model.dropWorkspace(dragged, onto: workspace.id, side: info.location.x < width / 2 ? .before : .after)
        case .item(let item)?:
            return model.drop(item, onto: .workspace(workspace.id))
        case nil:
            return false
        }
    }
}

/// An emoji, or an SF Symbol in the workspace colour; an unknown symbol name shows the fallback grid.
struct WorkspaceIconView: View {
    let icon: WorkspaceIcon
    let tint: Color

    var body: some View {
        switch icon {
        case .emoji(let text):
            Text(text).font(.system(size: 15))
        case .symbol(let name):
            let known = NSImage(systemSymbolName: name, accessibilityDescription: nil) != nil
            Image(systemName: known ? name : WorkspaceIcon.fallbackSymbol)
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(tint)
        }
    }
}

/// The profile menu (decision 3): the profiles, a checkmark on the current one, and New Profile…. Shown by the sidebar with two or more profiles.
struct ProfileMenu: View {
    @Bindable var model: BrowserWindowModel
    /// New Profile… asks the presenter, which owns the one name prompt (shared with the command bar's New Profile row).
    let presenter: SidebarPresenter

    var body: some View {
        Menu {
            ForEach(model.profiles) { profile in
                Toggle(profile.name, isOn: Binding(
                    get: { profile.id == model.snapshot.profile.id },
                    set: { _ in model.switchProfile(to: profile.id) }
                ))
            }
            Divider()
            Button(WorkspaceMenus.newProfileItem) { presenter.showNewProfile = true }
        } label: {
            Image(systemName: "person.crop.circle")
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("\(WorkspaceMenus.profileMenu): \(model.snapshot.profile.name)")
        .accessibilityLabel("\(WorkspaceMenus.profileMenu), \(model.snapshot.profile.name)")
    }
}
