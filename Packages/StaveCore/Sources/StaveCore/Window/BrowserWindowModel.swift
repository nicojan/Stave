import Foundation
import Observation

/// What one browser window shows and does. Views read it and call it; every write goes through `perform(_:)`,
/// so no method throws after `init` and a failure becomes `lastError` text.
@MainActor @Observable
public final class BrowserWindowModel {
    // MARK: - State

    public let windowID: UUID
    public private(set) var snapshot: SidebarSnapshot
    public private(set) var rows: [SidebarRow]
    public private(set) var workspaces: [Workspace]
    public private(set) var profiles: [Profile]
    public private(set) var containers: [Container]
    public private(set) var selectedTabID: UUID?
    /// Where the selected tab's live page is shown; nil with no selection. Set from the registry's `show` result, never inferred.
    public private(set) var placement: LivePlacement?
    public private(set) var lastError: String?
    /// -1, 0 or +1: the direction of the last workspace switch, for the slide animation.
    public private(set) var lastSwitchDirection = 0
    public var frame: String

    @ObservationIgnored private let store: OrganizationStore
    @ObservationIgnored private let revision: StoreRevision
    @ObservationIgnored private let livePages: LivePageRegistry
    @ObservationIgnored private let base: WindowState
    @ObservationIgnored private var profileID: UUID
    @ObservationIgnored private var workspaceID: UUID

    public var selectedTab: Tab? { selectedTabID.flatMap { id in Self.allTabs(in: snapshot).first { $0.id == id } } }

    public var windowState: WindowState {
        WindowState(
            id: windowID, profileID: snapshot.profile.id, workspaceID: snapshot.workspace.id,
            selectedTabID: selectedTabID, frame: frame, sortIndex: base.sortIndex, modifiedAt: base.modifiedAt
        )
    }

    // MARK: - Loading

    public init(store: OrganizationStore, revision: StoreRevision, livePages: LivePageRegistry, state: WindowState) throws {
        let loaded = try Self.read(store, profileID: state.profileID, workspaceID: state.workspaceID)
        self.store = store; self.revision = revision; self.livePages = livePages; self.base = state
        windowID = state.id; frame = state.frame
        snapshot = loaded.snapshot; rows = loaded.rows; workspaces = loaded.workspaces
        profiles = loaded.profiles; containers = loaded.containers
        profileID = loaded.snapshot.profile.id; workspaceID = loaded.snapshot.workspace.id
        selectedTabID = Self.allTabs(in: loaded.snapshot).contains { $0.id == state.selectedTabID } ? state.selectedTabID : nil
        syncPlacement()
    }

    /// Re-reads the store. A missing workspace falls back to the profile's first, a missing profile to the first profile.
    /// A selected tab that is gone clears the selection and releases this window's claim. A failed read keeps the old snapshot.
    public func reload() {
        do {
            let loaded = try Self.read(store, profileID: profileID, workspaceID: workspaceID)
            snapshot = loaded.snapshot; rows = loaded.rows; workspaces = loaded.workspaces
            profiles = loaded.profiles; containers = loaded.containers
            profileID = loaded.snapshot.profile.id; workspaceID = loaded.snapshot.workspace.id
        } catch {
            lastError = StoreErrorText.message(for: error)
            return
        }
        if let id = selectedTabID, !Self.allTabs(in: snapshot).contains(where: { $0.id == id }) { clearSelection() }
        syncPlacement()
    }

    private struct Loaded {
        var snapshot: SidebarSnapshot
        var rows: [SidebarRow]
        var workspaces: [Workspace]
        var profiles: [Profile]
        var containers: [Container]
    }

    private static func read(_ store: OrganizationStore, profileID: UUID, workspaceID: UUID) throws -> Loaded {
        let profiles = try store.profiles()
        guard let profile = profiles.first(where: { $0.id == profileID }) ?? profiles.first else { throw StoreError.notFound }
        let workspaces = try store.workspaces(profileID: profile.id)
        guard let workspace = workspaces.first(where: { $0.id == workspaceID }) ?? workspaces.first else { throw StoreError.notFound }
        let snapshot = try store.sidebarSnapshot(workspaceID: workspace.id)
        let containers = try store.containers(profileID: profile.id)
        return Loaded(
            snapshot: snapshot, rows: SidebarRows.build(snapshot, containers: containers),
            workspaces: workspaces, profiles: profiles, containers: containers
        )
    }

    private static func allTabs(in snapshot: SidebarSnapshot) -> [Tab] {
        func pinnedTabs(_ items: [PinnedItem]) -> [Tab] {
            items.flatMap { item -> [Tab] in
                switch item {
                case .tab(let tab): [tab]
                case .folder(_, let children): pinnedTabs(children)
                }
            }
        }
        return snapshot.essentials + pinnedTabs(snapshot.pinned) + snapshot.regular
    }

    // MARK: - Writes

    /// The one door for writes. Success: clear the error, bump the shared revision, re-read. Failure: show the message, re-read.
    @discardableResult
    private func perform<T>(_ work: () throws -> T) -> T? {
        do {
            let result = try work()
            lastError = nil
            revision.bump()
            reload()
            return result
        } catch {
            lastError = StoreErrorText.message(for: error)
            reload()
            return nil
        }
    }

    // MARK: - Selection

    /// Selects the tab, marks it active and claims its live page. `nil` clears the selection and releases the claim.
    public func select(_ tabID: UUID?) {
        guard let tabID else { clearSelection(); return }
        guard Self.allTabs(in: snapshot).contains(where: { $0.id == tabID }) else {
            lastError = StoreErrorText.message(for: StoreError.notFound)
            return
        }
        if tabID == selectedTabID, placement == .here { return }
        selectedTabID = tabID
        placement = livePages.show(tabID, in: windowID)
        perform { try store.markActive(tabID: tabID) }
    }

    /// Takes the selected tab's live page from the window that shows it.
    public func bringSelectedHere() {
        guard let id = selectedTabID else { return }
        livePages.bringHere(id, to: windowID)
        placement = .here
    }

    private func clearSelection() {
        guard selectedTabID != nil || placement != nil else { return }
        selectedTabID = nil
        placement = nil
        livePages.windowClosed(windowID) // releases this window's claim without showing anything
    }

    /// Brings `placement` in line with the registry after other windows moved or released the page. Claims only when needed.
    private func syncPlacement() {
        guard let id = selectedTabID else { placement = nil; return }
        let current = livePages.placement(of: id, in: windowID)
        switch (placement, current) {
        case (nil, _), (.elsewhere?, .here): placement = livePages.show(id, in: windowID)
        case (_, .elsewhere): placement = current
        case (.here?, .here): break
        }
    }

    // MARK: - Workspaces and profiles

    public func switchWorkspace(to id: UUID) {
        guard let target = workspaces.firstIndex(where: { $0.id == id }) else {
            lastError = StoreErrorText.message(for: StoreError.notFound)
            return
        }
        let current = workspaces.firstIndex { $0.id == snapshot.workspace.id } ?? target
        lastSwitchDirection = target > current ? 1 : (target < current ? -1 : 0)
        workspaceID = id
        dropSelectionUnlessEssential()
        reload()
    }

    /// 1-based. A number with no workspace does nothing.
    public func switchWorkspace(number: Int) {
        guard workspaces.indices.contains(number - 1) else { return }
        switchWorkspace(to: workspaces[number - 1].id)
    }

    /// Moves by `offset` workspaces without wrapping; past either end does nothing.
    public func switchWorkspace(offset: Int) {
        guard let current = workspaces.firstIndex(where: { $0.id == snapshot.workspace.id }),
              workspaces.indices.contains(current + offset) else { return }
        switchWorkspace(to: workspaces[current + offset].id)
    }

    public func switchProfile(to id: UUID) {
        guard profiles.contains(where: { $0.id == id }) else {
            lastError = StoreErrorText.message(for: StoreError.notFound)
            return
        }
        lastSwitchDirection = 0
        profileID = id // the old workspace is not in the new profile, so `reload()` lands on its first workspace
        dropSelectionUnlessEssential()
        reload()
    }

    /// Essentials are profile-wide, so only an Essential stays selected across a switch. `reload()` drops it if the profile changed.
    private func dropSelectionUnlessEssential() {
        let keepsSelection = selectedTabID.map { id in snapshot.essentials.contains { $0.id == id } } ?? false
        if !keepsSelection { clearSelection() }
    }

    public func createWorkspace(name: String, icon: String, colorHex: String) {
        guard let created = perform({ try store.createWorkspace(profileID: snapshot.profile.id, name: name, icon: icon, colorHex: colorHex) }) else { return }
        switchWorkspace(to: created.id)
    }

    public func updateWorkspace(_ id: UUID, name: String, icon: String, colorHex: String) {
        perform { try store.updateWorkspace(id, name: name, icon: icon, colorHex: colorHex) }
    }

    /// Deleting the current workspace first moves to its neighbour (next, else previous).
    public func deleteWorkspace(_ id: UUID) {
        if id == snapshot.workspace.id, let index = workspaces.firstIndex(where: { $0.id == id }) {
            let neighbour = workspaces.indices.contains(index + 1) ? workspaces[index + 1] : (index > 0 ? workspaces[index - 1] : nil)
            if let neighbour { switchWorkspace(to: neighbour.id) }
        }
        perform { try store.deleteWorkspace(id) }
    }

    public func moveWorkspace(_ id: UUID, after previousID: UUID?) {
        perform { try store.moveWorkspace(id, after: previousID) }
    }

    public func createProfile(name: String) {
        guard let created = perform({ try store.createProfile(name: name) }) else { return }
        switchProfile(to: created.id)
    }

    // MARK: - Tabs

    /// Opens a tab at the edge the `newTabEdge` setting names, in this workspace, and selects it.
    public func openTab(url: String, origin: NewTabOrigin = .commandBar, containerID: UUID? = nil) {
        let created = perform {
            try store.openTab(
                url: url, title: "", workspaceID: snapshot.workspace.id, origin: origin,
                containerID: containerID, edge: try store.setting(SettingKeys.newTabEdge)
            )
        }
        if let created { select(created.id) }
    }

    /// No web layer yet: stores the URL and clears the title so the sidebar shows the host.
    public func navigateSelected(to url: String) {
        guard let id = selectedTabID else { return }
        perform { try store.updateNavigation(tabID: id, url: url, title: "", faviconURL: nil, interactionState: nil) }
    }

    /// Closing the selected tab selects the tab row below it, else the one above, else nothing.
    public func close(_ tabID: UUID) {
        let wasSelected = tabID == selectedTabID
        let next = wasSelected ? neighbour(of: tabID) : nil
        guard let result = perform({ try store.closeTab(tabID) }) else { return }
        if case .archived = result { livePages.tabRemoved(tabID) }
        if wasSelected { select(next) }
    }

    private func neighbour(of tabID: UUID) -> UUID? {
        let ids = rows.compactMap { row -> UUID? in
            if case .tab(let id) = row.id { id } else { nil }
        }
        guard let index = ids.firstIndex(of: tabID) else { return nil }
        if ids.indices.contains(index + 1) { return ids[index + 1] }
        return index > 0 ? ids[index - 1] : nil
    }

    public func pin(_ tabID: UUID, folderID: UUID?) { perform { try store.pinTab(tabID, folderID: folderID) } }
    public func unpin(_ tabID: UUID) { perform { try store.unpinTab(tabID) } }
    public func makeEssential(_ tabID: UUID) { perform { try store.makeEssential(tabID) } }
    public func removeEssential(_ tabID: UUID) { perform { try store.removeEssential(tabID) } }
    public func removePinned(_ tabID: UUID) { perform { try store.removePinnedTab(tabID) } }
    public func resetPinned(_ tabID: UUID) { perform { try store.resetPinnedTab(tabID) } }

    // MARK: - Folders

    public func createFolder(title: String, parentID: UUID?) {
        perform { try store.createFolder(workspaceID: snapshot.workspace.id, parentFolderID: parentID, title: title) }
    }

    public func renameFolder(_ id: UUID, to title: String) { perform { try store.renameFolder(id, to: title) } }
    public func setFolderOpen(_ id: UUID, _ isOpen: Bool) { perform { try store.setFolderOpen(id, isOpen) } }
    public func deleteFolder(_ id: UUID) { perform { try store.deleteFolder(id) } }

    // MARK: - Archive and closing

    public func archivedTabs() -> [ArchivedTab] {
        do {
            return try store.archivedTabs(profileID: snapshot.profile.id)
        } catch {
            lastError = StoreErrorText.message(for: error)
            return []
        }
    }

    /// Restores into this workspace and selects the tab.
    public func restoreArchived(_ id: UUID) {
        guard let tab = perform({ try store.restoreArchivedTab(id, workspaceID: snapshot.workspace.id) }) else { return }
        select(tab.id)
    }

    public func windowWillClose() { livePages.windowClosed(windowID) }
}
