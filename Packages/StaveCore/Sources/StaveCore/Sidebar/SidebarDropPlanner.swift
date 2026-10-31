import Foundation

/// Where over a row the pointer is, relative to the row it hovers.
public enum DropPosition: Sendable, Equatable { case before, after, into }

/// A place something can be dropped in the sidebar.
public enum SidebarDropTarget: Sendable, Equatable {
    case row(SidebarItemID, DropPosition)
    /// The gap before the Essential at `index` in the grid (`count` = after the last).
    case essentials(index: Int)
    case pinnedEnd
    case regularTop
    case workspace(UUID)
}

/// One store write a drop or a keyboard move amounts to. `workspaceID` is nil exactly for `.essential` (the store's rule).
public enum SidebarMove: Sendable, Equatable {
    case tab(UUID, workspaceID: UUID?, section: SlotSection, folderID: UUID?, after: MoveAnchor?)
    case folder(UUID, parentID: UUID?, after: MoveAnchor?)
}

/// What a dragged row puts on the pasteboard: a tab's link (so another app gets the address), else a harmless label.
public enum SidebarDragPayload: Sendable, Equatable {
    case link(String)
    case label(String)
}

/// The rules of drag and drop and of the keyboard moves. Pure: the views ask it what a drop would do, and nil means "refuse, show no indicator".
public enum SidebarDropPlanner {
    // MARK: - Drops

    /// What dropping `item` on `target` does, or nil when that drop is not allowed (or would change nothing).
    /// `pinnedTail` names the last item of another workspace's pinned root, for a pinned tab dropped on that workspace's button (decision 39);
    /// without it the tab goes to the top of that root.
    public static func move(
        dragging item: SidebarItemID, onto target: SidebarDropTarget, snapshot: SidebarSnapshot,
        pinnedTail: (UUID) -> MoveAnchor? = { _ in nil }
    ) -> SidebarMove? {
        let layout = Layout(snapshot)
        guard let origin = layout.place(of: item) else { return nil }
        switch target {
        case .row(let rowID, let position):
            guard rowID != item, let row = layout.place(of: rowID) else { return nil }
            if position == .into {
                guard case .folder(let folderID) = rowID, let list = layout.folderLists[folderID] else { return nil }
                return finish(item, origin, Dest(section: .pinned, folderID: folderID, list: list), insertAt: list.count, layout)
            }
            let dest = Dest(section: row.section, folderID: row.folderID, list: row.list)
            return finish(item, origin, dest, insertAt: position == .before ? row.index : row.index + 1, layout)
        case .essentials(let index):
            let dest = Dest(section: .essential, folderID: nil, list: layout.essentials)
            return finish(item, origin, dest, insertAt: min(max(index, 0), dest.list.count), layout)
        case .pinnedEnd:
            let dest = Dest(section: .pinned, folderID: nil, list: layout.pinnedRoot)
            return finish(item, origin, dest, insertAt: dest.list.count, layout)
        case .regularTop:
            return finish(item, origin, Dest(section: .regular, folderID: nil, list: layout.regular), insertAt: 0, layout)
        case .workspace(let workspaceID):
            return moveToWorkspace(item, origin, workspaceID, snapshot: snapshot, pinnedTail: pinnedTail)
        }
    }

    /// One step within the item's own sibling list; nil at either end (or for `delta` 0).
    public static func keyboardMove(_ item: SidebarItemID, by delta: Int, snapshot: SidebarSnapshot) -> SidebarMove? {
        let layout = Layout(snapshot)
        guard delta != 0, let origin = layout.place(of: item) else { return nil }
        let step = delta > 0 ? 1 : -1
        guard origin.list.indices.contains(origin.index + step) else { return nil }
        let dest = Dest(section: origin.section, folderID: origin.folderID, list: origin.list)
        return finish(item, origin, dest, insertAt: step > 0 ? origin.index + 2 : origin.index - 1, layout)
    }

    /// The last item of the workspace's pinned root, which a tab dropped on that workspace's button goes after.
    public static func pinnedRootTail(of snapshot: SidebarSnapshot) -> MoveAnchor? {
        Layout(snapshot).pinnedRoot.last.map(anchor)
    }

    /// The target for a pointer `fraction` (0 top, 1 bottom) of the way down `row`. Tabs split in half; a folder has an "into" middle,
    /// and the bottom quarter of an open folder with children goes before its first child (the line is drawn where the tab would land).
    public static func target(overRow row: SidebarRow, fraction: Double, rows: [SidebarRow]) -> SidebarDropTarget {
        let f = min(max(fraction, 0), 1)
        guard case .folder(let isOpen, let childCount) = row.kind else { return .row(row.id, f < 0.5 ? .before : .after) }
        if f < 0.25 { return .row(row.id, .before) }
        if f < 0.75 { return .row(row.id, .into) }
        if isOpen, childCount > 0, case .folder(let id) = row.id,
           let first = rows.first(where: { $0.parentFolderID == id }) { return .row(first.id, .before) }
        return .row(row.id, .after)
    }

    /// The pasteboard content for a dragged row: a tab with a web address gives its link, anything else its title.
    public static func dragPayload(for item: SidebarItemID, snapshot: SidebarSnapshot) -> SidebarDragPayload? {
        switch item {
        case .folder(let id):
            guard let folder = folders(in: snapshot.pinned).first(where: { $0.id == id }) else { return nil }
            return .label(folder.title)
        case .tab(let id):
            let all = snapshot.essentials + tabs(in: snapshot.pinned) + snapshot.regular
            guard let tab = all.first(where: { $0.id == id }) else { return nil }
            if let url = URL(string: tab.url), let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https" { return .link(tab.url) }
            return .label(DisplayText.title(for: tab))
        }
    }

    /// Whether what a drop carries is what the sidebar put on the pasteboard for the remembered item: a link equals the tab's address, a label
    /// the title (or workspace name). A foreign drag that slipped past the session check still fails here, and then nothing is applied.
    public static func payloadMatches(expected: SidebarDragPayload?, droppedURL: String?, droppedText: String?) -> Bool {
        switch expected {
        case nil: false
        case .link(let link)?:
            droppedURL == (URL(string: link)?.absoluteString ?? link) || (droppedURL == nil && droppedText == link)
        case .label(let label)?: droppedURL == nil && droppedText == label
        }
    }

    // MARK: - Workspace buttons

    /// Reorders a workspace button: `.before`/`.after` the target. Onto itself, a position it already holds, another profile's workspace
    /// or `.into` gives nil. `workspaces` is the profile's list in order.
    public static func workspaceMove(
        dragging id: UUID, onto target: UUID, side: DropPosition, workspaces: [Workspace]
    ) -> (id: UUID, after: UUID?)? {
        guard side != .into, id != target,
              let from = workspaces.firstIndex(where: { $0.id == id }),
              let to = workspaces.firstIndex(where: { $0.id == target }),
              workspaces[from].profileID == workspaces[to].profileID else { return nil }
        let others = workspaces.filter { $0.id != id }
        guard let anchorIndex = others.firstIndex(where: { $0.id == target }) else { return nil }
        let slot = side == .before ? anchorIndex : anchorIndex + 1
        guard slot != from else { return nil }
        return (id, slot == 0 ? nil : others[slot - 1].id)
    }

    // MARK: - Internals

    private struct Place { var section: SlotSection; var folderID: UUID?; var list: [SidebarItemID]; var index: Int }
    private struct Dest { var section: SlotSection; var folderID: UUID?; var list: [SidebarItemID] }

    /// Every sibling list of the snapshot, and where each item sits in them.
    private struct Layout {
        let workspaceID: UUID
        let essentials: [SidebarItemID]
        let pinnedRoot: [SidebarItemID]
        let regular: [SidebarItemID]
        var folderLists: [UUID: [SidebarItemID]] = [:]
        var folderParents: [UUID: UUID?] = [:]

        init(_ snapshot: SidebarSnapshot) {
            workspaceID = snapshot.workspace.id
            essentials = snapshot.essentials.map { .tab($0.id) }
            regular = snapshot.regular.map { .tab($0.id) }
            pinnedRoot = snapshot.pinned.map(SidebarDropPlanner.id)
            collect(snapshot.pinned, parent: nil)
        }

        private mutating func collect(_ items: [PinnedItem], parent: UUID?) {
            for case .folder(let folder, let children) in items {
                folderLists[folder.id] = children.map(SidebarDropPlanner.id)
                folderParents[folder.id] = .some(parent)
                collect(children, parent: folder.id)
            }
        }

        func place(of item: SidebarItemID) -> Place? {
            let lists: [(SlotSection, UUID?, [SidebarItemID])] =
                [(.essential, nil, essentials), (.pinned, nil, pinnedRoot), (.regular, nil, regular)]
                + folderLists.map { (SlotSection.pinned, Optional($0.key), $0.value) }
            for (section, folderID, list) in lists {
                if let index = list.firstIndex(of: item) { return Place(section: section, folderID: folderID, list: list, index: index) }
            }
            return nil
        }

        func hasSubfolders(_ id: UUID) -> Bool {
            (folderLists[id] ?? []).contains { if case .folder = $0 { true } else { false } }
        }

        func isTopLevel(_ id: UUID) -> Bool { (folderParents[id] ?? nil) == nil }
    }

    private static func id(_ item: PinnedItem) -> SidebarItemID {
        switch item {
        case .tab(let tab): .tab(tab.id)
        case .folder(let folder, _): .folder(folder.id)
        }
    }

    private static func anchor(_ item: SidebarItemID) -> MoveAnchor {
        switch item {
        case .tab(let id): .tab(id)
        case .folder(let id): .folder(id)
        }
    }

    /// Builds the move for inserting `item` at `insertAt` (an index in `dest.list`, which may contain `item` itself). Applies the folder rules
    /// and drops a move that would leave the item where it is.
    private static func finish(_ item: SidebarItemID, _ origin: Place, _ dest: Dest, insertAt: Int, _ layout: Layout) -> SidebarMove? {
        if case .folder(let folderID) = item {
            guard dest.section == .pinned else { return nil } // not into the regular section or Essentials
            if let parent = dest.folderID {
                guard parent != folderID, layout.isTopLevel(parent), !layout.hasSubfolders(folderID) else { return nil }
            }
        }
        let before = dest.list.prefix(insertAt).filter { $0 == item }.count
        let slot = insertAt - before
        let others = dest.list.filter { $0 != item }
        let sameList = dest.list.contains(item)
        if sameList, slot == origin.index { return nil }
        let after = slot == 0 ? nil : others[slot - 1]
        switch item {
        case .folder(let id):
            return .folder(id, parentID: dest.folderID, after: after.map(anchor))
        case .tab(let id):
            return .tab(
                id, workspaceID: dest.section == .essential ? nil : layout.workspaceID,
                section: dest.section, folderID: dest.folderID, after: after.map(anchor)
            )
        }
    }

    /// Decision 39: a pinned tab stays pinned (end of the other workspace's pinned root), a regular one goes to the top of its regular tabs.
    /// Essentials and folders cannot go; the current workspace is not a move.
    private static func moveToWorkspace(
        _ item: SidebarItemID, _ origin: Place, _ workspaceID: UUID, snapshot: SidebarSnapshot, pinnedTail: (UUID) -> MoveAnchor?
    ) -> SidebarMove? {
        guard case .tab(let id) = item, workspaceID != snapshot.workspace.id else { return nil }
        switch origin.section {
        case .essential: return nil
        case .pinned: return .tab(id, workspaceID: workspaceID, section: .pinned, folderID: nil, after: pinnedTail(workspaceID))
        case .regular: return .tab(id, workspaceID: workspaceID, section: .regular, folderID: nil, after: nil)
        }
    }

    private static func tabs(in items: [PinnedItem]) -> [Tab] {
        items.flatMap { item -> [Tab] in
            switch item {
            case .tab(let tab): [tab]
            case .folder(_, let children): tabs(in: children)
            }
        }
    }

    private static func folders(in items: [PinnedItem]) -> [Folder] {
        items.flatMap { item -> [Folder] in
            if case .folder(let folder, let children) = item { [folder] + folders(in: children) } else { [] }
        }
    }
}
