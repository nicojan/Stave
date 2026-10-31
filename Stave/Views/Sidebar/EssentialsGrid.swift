import SwiftUI
import StaveCore

/// The profile's Essentials as monogram tiles, at least 52 x 44 pt, as many across as fit. A tile can be dragged, and the gaps between tiles
/// (and the empty grid) take drops; the planner decides what a drop does.
struct EssentialsGrid: View {
    let model: BrowserWindowModel
    let drag: SidebarDragState
    let select: (UUID) -> Void
    let perform: (SidebarAction, UUID) -> Void

    private var essentials: [StaveCore.Tab] { model.snapshot.essentials }

    var body: some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 52), spacing: 6)], spacing: 6) {
            ForEach(Array(essentials.enumerated()), id: \.element.id) { index, tab in
                tile(tab, index: index)
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(SidebarText.essentials)
    }

    private func tile(_ tab: StaveCore.Tab, index: Int) -> some View {
        let title = DisplayText.title(for: tab)
        let isSelected = tab.id == model.selectedTabID
        return Button { select(tab.id) } label: {
            Text(DisplayText.monogram(for: tab))
                .font(.system(size: 17, weight: .semibold))
                .frame(maxWidth: .infinity, minHeight: 44)
                .background(isSelected ? AnyShapeStyle(Color.accentColor.opacity(0.25)) : AnyShapeStyle(.quaternary), in: RoundedRectangle(cornerRadius: 10))
                .overlay { if isSelected { RoundedRectangle(cornerRadius: 10).stroke(Color.accentColor, lineWidth: 1.5) } }
                .contentShape(RoundedRectangle(cornerRadius: 10))
        }
        .buttonStyle(.plain)
        .help(title)
        .accessibilityLabel(SidebarLabels.essential(title: title))
        .accessibilityAddTraits(isSelected ? .isSelected : [])
        .sidebarActions(SidebarMenus.actions(forEssential: tab, in: model.snapshot)) { perform($0, tab.id) }
        .modifier(EssentialTileDrop(model: model, drag: drag, tab: tab, index: index, count: essentials.count))
    }
}

/// Drag source and drop target for one Essentials tile: the left half of a tile is the gap before it, the right half the gap after.
private struct EssentialTileDrop: ViewModifier {
    let model: BrowserWindowModel
    let drag: SidebarDragState
    let tab: StaveCore.Tab
    let index: Int
    let count: Int

    @State private var size = CGSize(width: 52, height: 44)

    func body(content: Content) -> some View {
        content
            .background(SizeReader(size: $size))
            .overlay { indicator }
            .onDrag {
                drag.begin(.item(.tab(tab.id)))
                return SidebarDragState.provider(for: SidebarDropPlanner.dragPayload(for: .tab(tab.id), snapshot: model.snapshot))
            }
            .onDrop(of: SidebarDragState.acceptedTypes, delegate: EssentialDropDelegate(model: model, drag: drag, tabID: tab.id, index: index, width: size.width))
    }

    @ViewBuilder
    private var indicator: some View {
        if case .essentials(let gap)? = drag.target {
            if gap == index {
                InsertionLine().frame(width: 2, height: 44).frame(maxWidth: .infinity, alignment: .leading).offset(x: -3)
            } else if gap == index + 1, index == count - 1 {
                InsertionLine().frame(width: 2, height: 44).frame(maxWidth: .infinity, alignment: .trailing).offset(x: 3)
            }
        }
    }
}

@MainActor
private struct EssentialDropDelegate: DropDelegate {
    let model: BrowserWindowModel
    let drag: SidebarDragState
    let tabID: UUID
    let index: Int
    let width: CGFloat

    private func accepted(_ info: DropInfo) -> (item: SidebarItemID, target: SidebarDropTarget)? {
        guard case .item(let item)? = drag.payload else { return nil }
        let target = SidebarDropTarget.essentials(index: info.location.x < width / 2 ? index : index + 1)
        return model.plannedMove(dragging: item, onto: target) == nil ? nil : (item, target)
    }

    func validateDrop(info: DropInfo) -> Bool {
        if case .item? = drag.payload { true } else { false }
    }

    func dropUpdated(info: DropInfo) -> DropProposal? {
        let found = accepted(info)
        drag.hover(found?.target, owner: AnyHashable(tabID))
        return DropProposal(operation: found == nil ? .forbidden : .move)
    }

    func dropExited(info: DropInfo) { drag.leave(owner: AnyHashable(tabID)) }

    func performDrop(info: DropInfo) -> Bool {
        defer { drag.end() }
        guard let found = accepted(info) else { return false }
        return model.drop(found.item, onto: found.target)
    }
}

/// Shown in place of the grid while a tab is dragged and the profile has no Essentials yet, so the first one can be dropped.
struct EssentialsEmptyDrop: View {
    let model: BrowserWindowModel
    let drag: SidebarDragState

    private var target: SidebarDropTarget { .essentials(index: 0) }

    var body: some View {
        let hovered = drag.target == target
        Text(SidebarText.essentialsDropHint)
            .font(.caption)
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, minHeight: 44)
            .background {
                RoundedRectangle(cornerRadius: 10)
                    .strokeBorder(hovered ? Color.accentColor : Color.secondary.opacity(0.5), style: StrokeStyle(lineWidth: 1.5, dash: [4, 3]))
            }
            .onDrop(of: SidebarDragState.acceptedTypes, delegate: FixedDropDelegate(model: model, drag: drag, target: target))
            .accessibilityLabel(SidebarText.essentialsDropHint)
    }
}
