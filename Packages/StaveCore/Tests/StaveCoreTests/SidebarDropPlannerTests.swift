import Foundation
import Testing
@testable import StaveCore

struct SidebarDropPlannerTests {
    /// Home: Essentials E1 E2; pinned root: folder Reading [pinned P1, folder Later [L1], P2], pinned PR1, PR2; regular R1 R2 R3.
    private struct Fixture {
        let profile = Profile(name: "P", sortIndex: 0)
        let workspace: Workspace
        let e1 = Tab(slotID: UUID(), url: "https://example.com/e1", title: "E1")
        let e2 = Tab(slotID: UUID(), url: "https://example.com/e2", title: "E2")
        let p1 = Tab(slotID: UUID(), pinnedURL: "https://example.com/p1", url: "https://example.com/p1", title: "P1")
        let p2 = Tab(slotID: UUID(), pinnedURL: "https://example.com/p2", url: "https://example.com/p2", title: "P2")
        let l1 = Tab(slotID: UUID(), pinnedURL: "https://example.com/l1", url: "https://example.com/l1", title: "L1")
        let pr1 = Tab(slotID: UUID(), pinnedURL: "https://example.com/pr1", url: "https://example.com/pr1", title: "PR1")
        let pr2 = Tab(slotID: UUID(), pinnedURL: "https://example.com/pr2", url: "https://example.com/pr2", title: "PR2")
        let r1 = Tab(slotID: UUID(), url: "https://example.com/r1", title: "R1")
        let r2 = Tab(slotID: UUID(), url: "https://example.com/r2", title: "R2")
        let r3 = Tab(slotID: UUID(), url: "", title: "R3")
        let reading: Folder
        let later: Folder
        let spare: Folder

        init() {
            workspace = Workspace(profileID: profile.id, name: "Home", icon: "", colorHex: "#FFFFFF", sortIndex: 0)
            reading = Folder(workspaceID: workspace.id, title: "Reading", sortIndex: 0)
            later = Folder(workspaceID: workspace.id, parentFolderID: reading.id, title: "Later", sortIndex: 1)
            spare = Folder(workspaceID: workspace.id, title: "Spare", sortIndex: 5)
        }

        var snapshot: SidebarSnapshot {
            SidebarSnapshot(
                profile: profile, workspace: workspace, essentials: [e1, e2],
                pinned: [
                    .folder(reading, children: [.tab(p1), .folder(later, children: [.tab(l1)]), .tab(p2)]),
                    .tab(pr1), .tab(pr2), .folder(spare, children: []),
                ],
                regular: [r1, r2, r3]
            )
        }
    }

    private let f = Fixture()

    private func move(_ item: SidebarItemID, _ target: SidebarDropTarget) -> SidebarMove? {
        SidebarDropPlanner.move(dragging: item, onto: target, snapshot: f.snapshot)
    }

    private func tabMove(_ id: UUID, _ section: SlotSection, folder: UUID? = nil, after: MoveAnchor?, workspace: UUID?? = nil) -> SidebarMove {
        .tab(id, workspaceID: workspace ?? (section == .essential ? nil : f.workspace.id), section: section, folderID: folder, after: after)
    }

    @Test func beforeFirstAnchorsNil() {
        #expect(move(.tab(f.r3.id), .row(.tab(f.r1.id), .before)) == tabMove(f.r3.id, .regular, after: nil))
        #expect(move(.tab(f.r1.id), .row(.tab(f.r3.id), .before)) == tabMove(f.r1.id, .regular, after: .tab(f.r2.id)))
    }

    @Test func afterAnchorsTheRow() {
        #expect(move(.tab(f.r3.id), .row(.tab(f.r1.id), .after)) == tabMove(f.r3.id, .regular, after: .tab(f.r1.id)))
        #expect(move(.tab(f.r1.id), .row(.folder(f.reading.id), .after)) == tabMove(f.r1.id, .pinned, after: .folder(f.reading.id)))
    }

    @Test func intoFolderAppends() {
        #expect(move(.tab(f.r1.id), .row(.folder(f.reading.id), .into)) == tabMove(f.r1.id, .pinned, folder: f.reading.id, after: .tab(f.p2.id)))
        #expect(move(.tab(f.r1.id), .row(.folder(f.spare.id), .into)) == tabMove(f.r1.id, .pinned, folder: f.spare.id, after: nil))
        // A folder without sub-folders goes into a top-level folder, after its last child.
        #expect(move(.folder(f.spare.id), .row(.folder(f.reading.id), .into)) == .folder(f.spare.id, parentID: f.reading.id, after: .tab(f.p2.id)))
        // Into a tab is not a drop.
        #expect(move(.tab(f.r1.id), .row(.tab(f.pr1.id), .into)) == nil)
    }

    @Test func folderWithSubfoldersCantGoIntoAFolder() {
        #expect(move(.folder(f.reading.id), .row(.folder(f.spare.id), .into)) == nil)
        // A folder can't go into a sub-folder (one level deep), nor beside a tab inside one.
        #expect(move(.folder(f.spare.id), .row(.folder(f.later.id), .into)) == nil)
        #expect(move(.folder(f.spare.id), .row(.tab(f.l1.id), .before)) == nil)
        // A sub-folder can come back out to the root.
        #expect(move(.folder(f.later.id), .row(.tab(f.pr1.id), .before)) == .folder(f.later.id, parentID: nil, after: .folder(f.reading.id)))
    }

    /// A top-level folder holding one tab and no sub-folders passes every other folder rule, so only the self-parent guard refuses these.
    @Test func folderCantBeDroppedBesideItsOwnChild() {
        let parent = Folder(workspaceID: f.workspace.id, title: "Solo", sortIndex: 0)
        var snapshot = f.snapshot
        snapshot.pinned = [.folder(parent, children: [.tab(f.p1)]), .tab(f.pr1)]
        func plan(_ position: DropPosition) -> SidebarMove? {
            SidebarDropPlanner.move(dragging: .folder(parent.id), onto: .row(.tab(f.p1.id), position), snapshot: snapshot)
        }
        #expect(plan(.before) == nil)
        #expect(plan(.after) == nil)
    }

    @Test func dragSessionIsBoundToThePasteboardCount() {
        #expect(DragSessionRule.verdict(recorded: nil, current: 7) == .record)
        #expect(DragSessionRule.verdict(recorded: 7, current: 7) == .live)
        #expect(DragSessionRule.verdict(recorded: 7, current: 8) == .foreign)
    }

    @Test func aDropMustCarryWhatWasPutOnThePasteboard() {
        func matches(_ expected: SidebarDragPayload?, _ dropped: SidebarDroppedContent) -> Bool {
            SidebarDropPlanner.payloadMatches(expected: expected, dropped: dropped)
        }
        #expect(matches(.link("https://example.com/a"), .url("https://example.com/a")))
        #expect(matches(.link("https://example.com/a"), .text("https://example.com/a")))
        #expect(!matches(.link("https://example.com/a"), .url("https://example.org/other")))
        #expect(!matches(.link("https://example.com/a"), .none))
        // A label with no URL type is read as text and matches.
        #expect(matches(.label("Reading"), .text("Reading")))
        #expect(!matches(.label("Reading"), .text("Other")))
        #expect(!matches(.label("Reading"), .url("https://example.com/a")))
        // Label text that looks like a URL is still a label: read as text, it matches; a real URL item does not.
        #expect(matches(.label("https://example.com/x"), .text("https://example.com/x")))
        #expect(!matches(.label("https://example.com/x"), .url("https://example.com/x")))
        #expect(!matches(nil, .url("https://example.com/a")))
        #expect(!matches(nil, .none))
    }

    @Test func ontoItselfIsNil() {
        #expect(move(.tab(f.r1.id), .row(.tab(f.r1.id), .before)) == nil)
        #expect(move(.folder(f.reading.id), .row(.folder(f.reading.id), .into)) == nil)
        // Into its own folder chain.
        #expect(move(.folder(f.reading.id), .row(.tab(f.p1.id), .after)) == nil)
        #expect(move(.folder(f.reading.id), .row(.folder(f.later.id), .after)) == nil)
        // A position it already holds changes nothing.
        #expect(move(.tab(f.r2.id), .row(.tab(f.r1.id), .after)) == nil)
        #expect(move(.tab(f.r2.id), .row(.tab(f.r3.id), .before)) == nil)
        #expect(move(.tab(f.r1.id), .regularTop) == nil)
        #expect(move(.tab(f.pr2.id), .row(.folder(f.spare.id), .before)) == nil)
    }

    @Test func regularToEssentials() {
        let move = move(.tab(f.r1.id), .essentials(index: 1))
        #expect(move == .tab(f.r1.id, workspaceID: nil, section: .essential, folderID: nil, after: .tab(f.e1.id)))
        #expect(self.move(.tab(f.r1.id), .essentials(index: 0)) == .tab(f.r1.id, workspaceID: nil, section: .essential, folderID: nil, after: nil))
        #expect(self.move(.tab(f.pr1.id), .essentials(index: 99)) == .tab(f.pr1.id, workspaceID: nil, section: .essential, folderID: nil, after: .tab(f.e2.id)))
    }

    @Test func essentialReorderSkipsItself() {
        #expect(move(.tab(f.e1.id), .essentials(index: 2)) == .tab(f.e1.id, workspaceID: nil, section: .essential, folderID: nil, after: .tab(f.e2.id)))
        #expect(move(.tab(f.e1.id), .essentials(index: 0)) == nil)
        #expect(move(.tab(f.e1.id), .essentials(index: 1)) == nil)
    }

    @Test func essentialToRegularAndPinned() {
        #expect(move(.tab(f.e1.id), .regularTop) == tabMove(f.e1.id, .regular, after: nil))
        #expect(move(.tab(f.e1.id), .pinnedEnd) == tabMove(f.e1.id, .pinned, after: .folder(f.spare.id)))
    }

    @Test func pinnedEndAndRegularTop() {
        #expect(move(.tab(f.r1.id), .pinnedEnd) == tabMove(f.r1.id, .pinned, after: .folder(f.spare.id)))
        #expect(move(.tab(f.pr1.id), .pinnedEnd) == tabMove(f.pr1.id, .pinned, after: .folder(f.spare.id)))
        #expect(move(.tab(f.pr1.id), .regularTop) == tabMove(f.pr1.id, .regular, after: nil))
        #expect(move(.folder(f.spare.id), .regularTop) == nil)
    }

    @Test func pinnedToWorkspaceKeepsPinned() {
        let other = UUID()
        #expect(move(.tab(f.pr1.id), .workspace(other)) == .tab(f.pr1.id, workspaceID: other, section: .pinned, folderID: nil, after: nil))
        let tail = SidebarDropPlanner.move(dragging: .tab(f.l1.id), onto: .workspace(other), snapshot: f.snapshot, pinnedTail: { $0 == other ? .tab(f.p2.id) : nil })
        #expect(tail == .tab(f.l1.id, workspaceID: other, section: .pinned, folderID: nil, after: .tab(f.p2.id)))
        #expect(move(.tab(f.r1.id), .workspace(other)) == .tab(f.r1.id, workspaceID: other, section: .regular, folderID: nil, after: nil))
        #expect(move(.tab(f.r1.id), .workspace(f.workspace.id)) == nil)
    }

    @Test func essentialOntoWorkspaceIsNil() {
        #expect(move(.tab(f.e1.id), .workspace(UUID())) == nil)
    }

    @Test func folderOntoWorkspaceIsNil() {
        #expect(move(.folder(f.spare.id), .workspace(UUID())) == nil)
    }

    @Test func folderIntoRegularIsNil() {
        #expect(move(.folder(f.spare.id), .row(.tab(f.r1.id), .before)) == nil)
        #expect(move(.folder(f.spare.id), .regularTop) == nil)
        #expect(move(.folder(f.spare.id), .essentials(index: 0)) == nil)
        #expect(move(.folder(f.spare.id), .pinnedEnd) == nil) // already last
        #expect(move(.folder(f.spare.id), .row(.tab(f.pr1.id), .before)) == .folder(f.spare.id, parentID: nil, after: .folder(f.reading.id)))
    }

    @Test func unknownItemsAreNil() {
        #expect(move(.tab(UUID()), .regularTop) == nil)
        #expect(move(.tab(f.r1.id), .row(.tab(UUID()), .before)) == nil)
    }

    @Test func keyboardMoveStepsWithinList() {
        let snapshot = f.snapshot
        // Up from the first is nothing; down from the last is nothing.
        #expect(SidebarDropPlanner.keyboardMove(.tab(f.r1.id), by: -1, snapshot: snapshot) == nil)
        #expect(SidebarDropPlanner.keyboardMove(.tab(f.r3.id), by: 1, snapshot: snapshot) == nil)
        // Down from the middle: after the next sibling. Up from the middle: after the one before the previous.
        #expect(SidebarDropPlanner.keyboardMove(.tab(f.r2.id), by: 1, snapshot: snapshot) == tabMove(f.r2.id, .regular, after: .tab(f.r3.id)))
        #expect(SidebarDropPlanner.keyboardMove(.tab(f.r2.id), by: -1, snapshot: snapshot) == tabMove(f.r2.id, .regular, after: nil))
        #expect(SidebarDropPlanner.keyboardMove(.tab(f.r3.id), by: -1, snapshot: snapshot) == tabMove(f.r3.id, .regular, after: .tab(f.r1.id)))
        // Pinned folder children, the pinned root (folders and tabs share it), and Essentials.
        #expect(SidebarDropPlanner.keyboardMove(.tab(f.p1.id), by: 1, snapshot: snapshot) == tabMove(f.p1.id, .pinned, folder: f.reading.id, after: .folder(f.later.id)))
        #expect(SidebarDropPlanner.keyboardMove(.folder(f.reading.id), by: 1, snapshot: snapshot) == .folder(f.reading.id, parentID: nil, after: .tab(f.pr1.id)))
        #expect(SidebarDropPlanner.keyboardMove(.tab(f.e1.id), by: 1, snapshot: snapshot) == .tab(f.e1.id, workspaceID: nil, section: .essential, folderID: nil, after: .tab(f.e2.id)))
        #expect(SidebarDropPlanner.keyboardMove(.tab(f.r2.id), by: 0, snapshot: snapshot) == nil)
        #expect(SidebarDropPlanner.keyboardMove(.tab(UUID()), by: 1, snapshot: snapshot) == nil)
    }

    @Test func moveActionsOfferOnlyWhatCanMove() {
        let snapshot = f.snapshot
        #expect(SidebarMenus.moveActions(for: .tab(f.r1.id), in: snapshot) == [.moveDown])
        #expect(SidebarMenus.moveActions(for: .tab(f.r2.id), in: snapshot) == [.moveUp, .moveDown])
        #expect(SidebarMenus.moveActions(for: .tab(f.r3.id), in: snapshot) == [.moveUp])
        #expect(SidebarMenus.moveActions(for: .folder(f.later.id), in: snapshot) == [.moveUp, .moveDown]) // between p1 and p2
        #expect(SidebarMenus.moveActions(for: .tab(f.l1.id), in: snapshot).isEmpty) // alone in its folder
        #expect(SidebarMenus.moveActions(for: .tab(f.e2.id), in: snapshot) == [.moveLeft])
        #expect(SidebarMenus.moveActions(for: .tab(f.e1.id), in: snapshot) == [.moveRight])
        #expect(SidebarAction.moveLeft.title == "Move Left" && SidebarAction.moveRight.title == "Move Right")
    }

    @Test func pointerFractionPicksTheTarget() {
        let tab = SidebarRow(id: .tab(f.r1.id), kind: .regularTab, depth: 0, parentFolderID: nil, title: "", containerColorHex: nil, accessibilityLabel: "")
        let open = SidebarRow(id: .folder(f.reading.id), kind: .folder(isOpen: true, childCount: 3), depth: 0, parentFolderID: nil, title: "", containerColorHex: nil, accessibilityLabel: "")
        let closed = SidebarRow(id: .folder(f.spare.id), kind: .folder(isOpen: false, childCount: 0), depth: 0, parentFolderID: nil, title: "", containerColorHex: nil, accessibilityLabel: "")
        let child = SidebarRow(id: .tab(f.p1.id), kind: .pinnedTab(drifted: false), depth: 1, parentFolderID: f.reading.id, title: "", containerColorHex: nil, accessibilityLabel: "")
        let rows = [open, child, closed, tab]
        #expect(SidebarDropPlanner.target(overRow: tab, fraction: 0.2, rows: rows) == .row(tab.id, .before))
        #expect(SidebarDropPlanner.target(overRow: tab, fraction: 0.8, rows: rows) == .row(tab.id, .after))
        #expect(SidebarDropPlanner.target(overRow: closed, fraction: 0.1, rows: rows) == .row(closed.id, .before))
        #expect(SidebarDropPlanner.target(overRow: closed, fraction: 0.5, rows: rows) == .row(closed.id, .into))
        #expect(SidebarDropPlanner.target(overRow: closed, fraction: 0.9, rows: rows) == .row(closed.id, .after))
        #expect(SidebarDropPlanner.target(overRow: open, fraction: 0.9, rows: rows) == .row(child.id, .before))
        #expect(SidebarDropPlanner.target(overRow: tab, fraction: -3, rows: rows) == .row(tab.id, .before))
    }

    @Test func dragPayloadIsTheLinkOrALabel() {
        let snapshot = f.snapshot
        #expect(SidebarDropPlanner.dragPayload(for: .tab(f.r1.id), snapshot: snapshot) == .link("https://example.com/r1"))
        #expect(SidebarDropPlanner.dragPayload(for: .tab(f.l1.id), snapshot: snapshot) == .link("https://example.com/l1"))
        #expect(SidebarDropPlanner.dragPayload(for: .tab(f.r3.id), snapshot: snapshot) == .label("R3"))
        #expect(SidebarDropPlanner.dragPayload(for: .folder(f.later.id), snapshot: snapshot) == .label("Later"))
        #expect(SidebarDropPlanner.dragPayload(for: .folder(UUID()), snapshot: snapshot) == nil)
        var odd = snapshot
        odd.regular = [Tab(slotID: UUID(), url: "javascript:alert(1)", title: "Odd")]
        #expect(SidebarDropPlanner.dragPayload(for: .tab(odd.regular[0].id), snapshot: odd) == .label("Odd"))
    }

    // MARK: - Workspaces

    @Test func workspaceDragReorders() {
        let profile = UUID()
        let a = Workspace(profileID: profile, name: "A", icon: "", colorHex: "#FFFFFF", sortIndex: 0)
        let b = Workspace(profileID: profile, name: "B", icon: "", colorHex: "#FFFFFF", sortIndex: 1)
        let c = Workspace(profileID: profile, name: "C", icon: "", colorHex: "#FFFFFF", sortIndex: 2)
        let list = [a, b, c]
        func plan(_ id: UUID, _ target: UUID, _ side: DropPosition, _ among: [Workspace] = list) -> (id: UUID, after: UUID?)? {
            SidebarDropPlanner.workspaceMove(dragging: id, onto: target, side: side, workspaces: among)
        }
        // C before A: C, A, B (first, so after nil).
        let first = SidebarDropPlanner.workspaceMove(dragging: c.id, onto: a.id, side: .before, workspaces: list)
        #expect(first?.id == c.id && first?.after == nil)
        // A after C: B, C, A.
        let last = SidebarDropPlanner.workspaceMove(dragging: a.id, onto: c.id, side: .after, workspaces: list)
        #expect(last?.id == a.id && last?.after == c.id)
        // C after A: C lands between A and B.
        let between = plan(c.id, a.id, .after)
        #expect(between?.id == c.id && between?.after == a.id)
        // Onto itself, its own spot, or `.into`.
        #expect(plan(b.id, b.id, .before) == nil)
        #expect(plan(b.id, c.id, .before) == nil)
        #expect(plan(b.id, a.id, .after) == nil)
        #expect(plan(a.id, b.id, .before) == nil)
        #expect(plan(c.id, b.id, .after) == nil)
        #expect(plan(a.id, c.id, .into) == nil)
        // Another profile's workspace, or one that is not in the list.
        let foreign = Workspace(profileID: UUID(), name: "X", icon: "", colorHex: "#FFFFFF", sortIndex: 0)
        #expect(plan(a.id, foreign.id, .before, list + [foreign]) == nil)
        #expect(plan(foreign.id, a.id, .before, list + [foreign]) == nil)
        #expect(plan(UUID(), a.id, .before) == nil)
    }
}
