import Foundation

/// The tab shortcuts of decision 16: ⌘1–9 and ⌃Tab (question 17), ⇧⌘T, and ⌘D (question 18).
extension BrowserWindowModel {
    /// Sidebar order: Essentials, then the tab rows (pinned tabs not inside a collapsed folder, then regular tabs).
    public var tabsInSidebarOrder: [UUID] {
        snapshot.essentials.map(\.id) + rows.compactMap { row -> UUID? in
            if case .tab(let id) = row.id { id } else { nil }
        }
    }

    /// ⌘1–⌘8 select the nth tab in sidebar order, ⌘9 the last; past the end nothing happens. An unloaded pinned tab loads, as a click does.
    /// Returns whether there was a tab to select, so the key monitor consumes ⌘n only when it did something.
    @discardableResult
    public func selectTab(number: Int) -> Bool {
        guard let id = TabOrder.tab(number: number, in: tabsInSidebarOrder) else { return false }
        select(id)
        return true
    }

    /// ⌃Tab (+1) and ⌃⇧Tab (-1), also ⇧⌘] and ⇧⌘[: the next or previous tab in sidebar order, wrapping as Safari does.
    public func selectAdjacentTab(_ delta: Int) {
        guard let id = TabOrder.adjacent(to: selectedTabID, by: delta, in: tabsInSidebarOrder) else { return }
        select(id)
    }

    /// ⇧⌘T: restores the newest archived tab of this workspace (by `closedAt`, then `rowid`, as the archive lists them; a pinned page the
    /// archive kept when a drifted tab was unpinned counts, since it is in the archive) and selects it, as a page the user opened. Nothing
    /// when this workspace has nothing archived.
    public func reopenLastClosed() {
        guard let newest = archivedTabs().first(where: { $0.workspaceID == snapshot.workspace.id }) else { return }
        restoreArchived(newest.id, openedByUser: true)
    }

    /// ⌘D: pins the selected regular tab at the end of its workspace's pinned tabs. A pinned tab or an Essential is left alone, so ⌘D never
    /// unpins or re-files one.
    public func pinSelectedTab() {
        guard let id = selectedTabID, snapshot.regular.contains(where: { $0.id == id }) else { return }
        pin(id, folderID: nil)
    }

    /// Where the selected tab sits, for ⌘D's rule (`PageMenuState`); nil with none selected.
    public var selectedSection: SlotSection? {
        guard let id = selectedTabID else { return nil }
        if snapshot.essentials.contains(where: { $0.id == id }) { return .essential }
        if snapshot.regular.contains(where: { $0.id == id }) { return .regular }
        return selectedTab == nil ? nil : .pinned
    }
}
