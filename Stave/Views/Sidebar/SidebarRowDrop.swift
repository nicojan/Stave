import SwiftUI
import StaveCore

/// Makes a sidebar row draggable and a drop target. The target under the pointer is `SidebarDropPlanner.target(overRow:)`, whether that drop is
/// allowed is `BrowserWindowModel.plannedMove`; this only reports the pointer and draws the indicator.
struct SidebarRowDrop: ViewModifier {
    let model: BrowserWindowModel
    let drag: SidebarDragState
    let row: SidebarRow

    @State private var size = CGSize(width: 0, height: 28)

    func body(content: Content) -> some View {
        content
            .background(SizeReader(size: $size))
            .overlay { indicator }
            .onDrag {
                let written = SidebarDropPlanner.dragPayload(for: row.id, snapshot: model.snapshot)
                drag.begin(.item(row.id), written: written)
                return SidebarDragState.provider(for: written)
            }
            .onDrop(of: SidebarDragState.acceptedTypes, delegate: RowDropDelegate(model: model, drag: drag, row: row, height: size.height))
    }

    @ViewBuilder
    private var indicator: some View {
        if case .row(let id, let position)? = drag.target, id == row.id {
            switch position {
            case .into: DropHighlight()
            case .before: InsertionLine().frame(maxHeight: .infinity, alignment: .top)
            case .after: InsertionLine().frame(maxHeight: .infinity, alignment: .bottom)
            }
        }
    }
}

@MainActor
struct RowDropDelegate: DropDelegate {
    let model: BrowserWindowModel
    let drag: SidebarDragState
    let row: SidebarRow
    let height: CGFloat

    private func accepted(_ info: DropInfo) -> (item: SidebarItemID, target: SidebarDropTarget)? {
        guard case .item(let item)? = drag.livePayload else { return nil }
        let fraction = Double(info.location.y / max(height, 1))
        let target = SidebarDropPlanner.target(overRow: row, fraction: fraction, rows: model.rows)
        return model.plannedMove(dragging: item, onto: target) == nil ? nil : (item, target)
    }

    func validateDrop(info: DropInfo) -> Bool {
        if case .item? = drag.livePayload { true } else { false }
    }

    func dropUpdated(info: DropInfo) -> DropProposal? {
        let found = accepted(info)
        drag.hover(found?.target, owner: AnyHashable(row.id))
        return DropProposal(operation: found == nil ? .forbidden : .move)
    }

    func dropExited(info: DropInfo) { drag.leave(owner: AnyHashable(row.id)) }

    func performDrop(info: DropInfo) -> Bool {
        guard let found = accepted(info) else { drag.end(); return false }
        let expected = drag.written
        drag.end()
        return DropVerifier.verifiedApply(info: info, expected: expected) { [model] in model.drop(found.item, onto: found.target) }
    }
}

extension View {
    func sidebarRowDrop(model: BrowserWindowModel, drag: SidebarDragState, row: SidebarRow) -> some View {
        modifier(SidebarRowDrop(model: model, drag: drag, row: row))
    }
}
