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
    /// Exactly what `onDrag` wrote to the pasteboard for this drag. Drops compare the dropped content to this, never to a fresh read of the
    /// snapshot, which can change mid-drag (a title or address updating).
    private(set) var written: SidebarDragPayload?
    private(set) var target: SidebarDropTarget?
    private(set) var workspaceSlot: WorkspaceSlot?
    /// Who set the indicator, so a view that is left after the next one was entered does not clear the newer indicator.
    @ObservationIgnored private var owner: AnyHashable?

    /// True while a tab or folder row is dragged (not a workspace button).
    var isDraggingTab: Bool {
        if case .item(.tab)? = payload { true } else { false }
    }

    /// The drag pasteboard's change count at the first look after the drag began (the drag has written it by then). Nil until then.
    @ObservationIgnored private var recordedCount: Int?
    @ObservationIgnored private var watcher: Task<Void, Never>?

    /// How often, and after how many consecutive polls with the button up, an abandoned drag is forgotten.
    private static let pollInterval: Duration = .milliseconds(200)
    private static let releasedPolls = 3

    /// A new drag starting anywhere in the sidebar replaces whatever was remembered.
    func begin(_ payload: Payload, written: SidebarDragPayload?) {
        end()
        self.payload = payload
        self.written = written
        watchForAbandonment()
    }

    func end() {
        watcher?.cancel()
        watcher = nil
        payload = nil
        written = nil
        recordedCount = nil
        clearIndicator()
    }

    /// The remembered drag, only while it is still the drag on the pasteboard. A different change count means another drag (another app, another
    /// window) started since: the memory is dropped and nothing is returned, so a foreign drop can never be read as a move of a sidebar item.
    var livePayload: Payload? {
        guard payload != nil else { return nil }
        let current = NSPasteboard(name: .drag).changeCount
        switch DragSessionRule.verdict(recorded: recordedCount, current: current) {
        case .record:
            recordedCount = current
            return payload
        case .live:
            return payload
        case .foreign:
            end()
            return nil
        }
    }

    /// A drag that ends without a Stave drop (Escape, dropped on itself, dropped in another app) gives no callback. The mouse button being up
    /// for a few polls in a row means the drag session is over, so the memory goes and the drag-only drop areas disappear.
    private func watchForAbandonment() {
        watcher = Task { @MainActor [weak self] in
            var released = 0
            while !Task.isCancelled {
                try? await Task.sleep(for: Self.pollInterval)
                released = NSEvent.pressedMouseButtons & 1 == 0 ? released + 1 : 0
                if released >= Self.releasedPolls {
                    self?.end()
                    return
                }
            }
        }
    }

    /// True while any sidebar item (tab or folder, not a workspace button) is being dragged.
    var isDraggingItem: Bool {
        if case .item? = payload { true } else { false }
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

/// Checks that what a drop carries is what the sidebar put on the pasteboard for the remembered item, then applies the drop. The providers load
/// asynchronously, so the answer to the system is "accepted" once a provider is there; nothing is applied when the content differs.
@MainActor
enum DropVerifier {
    static func verifiedApply(info: DropInfo, expected: SidebarDragPayload?, apply: @escaping @MainActor () -> Void) -> Bool {
        guard let expected, let provider = info.itemProviders(for: SidebarDragState.acceptedTypes).first else { return false }
        let box = ProviderBox(provider: provider)
        Task { @MainActor in
            let content = await load(box)
            if SidebarDropPlanner.payloadMatches(expected: expected, dropped: content) { apply() }
        }
        return true
    }

    /// The provider is only read, by the system's own loading calls.
    private struct ProviderBox: @unchecked Sendable { let provider: NSItemProvider }

    /// A URL only when the item has a registered type conforming to `public.url`; otherwise its string. Plain text must never be read as a URL.
    private static func load(_ box: ProviderBox) async -> SidebarDroppedContent {
        if box.provider.hasItemConformingToTypeIdentifier(UTType.url.identifier) {
            let url: String? = await withCheckedContinuation { continuation in
                _ = box.provider.loadObject(ofClass: URL.self) { url, _ in continuation.resume(returning: url?.absoluteString) }
            }
            return url.map(SidebarDroppedContent.url) ?? .none
        }
        guard box.provider.canLoadObject(ofClass: NSString.self) else { return .none }
        let text: String? = await withCheckedContinuation { continuation in
            _ = box.provider.loadObject(ofClass: NSString.self) { text, _ in continuation.resume(returning: (text as? NSString).map { $0 as String }) }
        }
        return text.map(SidebarDroppedContent.text) ?? .none
    }
}

/// A drop on a fixed place (the pinned end, the top of the regular tabs, the empty Essentials area).
@MainActor
struct FixedDropDelegate: DropDelegate {
    let model: BrowserWindowModel
    let drag: SidebarDragState
    let target: SidebarDropTarget

    private func item() -> SidebarItemID? {
        guard case .item(let item)? = drag.livePayload, model.plannedMove(dragging: item, onto: target) != nil else { return nil }
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
        guard let item = item() else { drag.end(); return false }
        let expected = drag.written
        drag.end()
        return DropVerifier.verifiedApply(info: info, expected: expected) { [model, target] in model.drop(item, onto: target) }
    }
}
