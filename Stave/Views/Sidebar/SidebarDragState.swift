import AppKit
import Observation
import SwiftUI
import UniformTypeIdentifiers
import StaveCore

/// A workspace button's insertion slot while another button is dragged over it.
struct WorkspaceSlot: Equatable {
    let workspaceID: UUID
    let side: DropPosition
}

/// The app's current drag (decision 38) and the indicator it is showing. View state only: what a drop does, and whether it is allowed at all, is
/// `SidebarDropPlanner`; a target the planner refuses is never stored here, so it shows no indicator.
///
/// The pasteboard carries a link or a label for other apps; this state, not the pasteboard, says which sidebar item or workspace is being dragged.
@MainActor @Observable
final class SidebarDragState {
    enum Payload: Equatable {
        case item(SidebarItemID)
        case workspace(UUID)
    }

    private(set) var payload: Payload?
    private(set) var target: SidebarDropTarget?
    private(set) var workspaceSlot: WorkspaceSlot?
    /// Who set the indicator, so a view that is left after the next one was entered does not clear the newer indicator.
    @ObservationIgnored private var owner: AnyHashable?

    /// True while a tab or folder row is dragged (not a workspace button).
    var isDraggingTab: Bool {
        if case .item(.tab)? = payload { true } else { false }
    }

    func begin(_ payload: Payload) {
        self.payload = payload
        clearIndicator()
    }

    func end() {
        payload = nil
        clearIndicator()
    }

    func hover(_ target: SidebarDropTarget?, owner: AnyHashable) {
        self.owner = owner
        self.target = target
        workspaceSlot = nil
    }

    func hoverWorkspace(_ slot: WorkspaceSlot?, owner: AnyHashable) {
        self.owner = owner
        workspaceSlot = slot
        target = nil
    }

    func leave(owner: AnyHashable) {
        guard self.owner == owner else { return }
        clearIndicator()
    }

    private func clearIndicator() {
        owner = nil
        target = nil
        workspaceSlot = nil
    }

    /// What other apps get when the drag leaves Stave: a tab's link, else a harmless label.
    static func provider(for payload: SidebarDragPayload?) -> NSItemProvider {
        switch payload {
        case .link(let text)?:
            if let url = URL(string: text) { return NSItemProvider(object: url as NSURL) }
            return NSItemProvider(object: text as NSString)
        case .label(let text)?: return NSItemProvider(object: text as NSString)
        case nil: return NSItemProvider(object: "" as NSString)
        }
    }

    static let acceptedTypes: [UTType] = [.url, .plainText]
}

/// The accent line that shows where a drop will land.
struct InsertionLine: View {
    var body: some View {
        Capsule().fill(Color.accentColor).frame(height: 2).padding(.horizontal, 2).allowsHitTesting(false)
    }
}

/// The highlight on a folder or workspace button that a drop goes into.
struct DropHighlight: View {
    var cornerRadius: CGFloat = 6

    var body: some View {
        RoundedRectangle(cornerRadius: cornerRadius)
            .fill(Color.accentColor.opacity(0.18))
            .overlay { RoundedRectangle(cornerRadius: cornerRadius).stroke(Color.accentColor, lineWidth: 1.5) }
            .allowsHitTesting(false)
    }
}

/// Measures the size of the view it is the background of, for turning a drop location into a fraction.
struct SizeReader: View {
    @Binding var size: CGSize

    var body: some View {
        GeometryReader { proxy in
            Color.clear
                .onAppear { size = proxy.size }
                .onChange(of: proxy.size) { _, new in size = new }
        }
    }
}

/// A drop on a fixed place (the pinned end, the top of the regular tabs, the empty Essentials area).
@MainActor
struct FixedDropDelegate: DropDelegate {
    let model: BrowserWindowModel
    let drag: SidebarDragState
    let target: SidebarDropTarget

    private func item() -> SidebarItemID? {
        guard case .item(let item)? = drag.payload, model.plannedMove(dragging: item, onto: target) != nil else { return nil }
        return item
    }

    func validateDrop(info: DropInfo) -> Bool { item() != nil }

    func dropUpdated(info: DropInfo) -> DropProposal? {
        let allowed = item() != nil
        drag.hover(allowed ? target : nil, owner: AnyHashable(String(describing: target)))
        return DropProposal(operation: allowed ? .move : .forbidden)
    }

    func dropExited(info: DropInfo) { drag.leave(owner: AnyHashable(String(describing: target))) }

    func performDrop(info: DropInfo) -> Bool {
        defer { drag.end() }
        guard let item = item() else { return false }
        return model.drop(item, onto: target)
    }
}
