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

    /// Where the selected tab's live page is shown; nil with no selection. Read from the registry, which owns the answer.
    public var placement: LivePlacement? { selectedTabID.map { livePages.placement(of: $0, in: windowID) } }

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
        if let selectedTabID { livePages.show(selectedTabID, in: windowID) }
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
        snapshot.essentials + pinnedTabs(snapshot.pinned) + snapshot.regular
    }

    private static func pinnedTabs(_ items: [PinnedItem]) -> [Tab] {
        items.flatMap { item -> [Tab] in
            switch item {
            case .tab(let tab): [tab]
            case .folder(_, let children): pinnedTabs(children)
            }
        }
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
            let message = StoreErrorText.message(for: error)
            reload()
            lastError = message // a failed re-read must not hide the write's message
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
        if tabID == selectedTabID { return }
        selectedTabID = tabID
        livePages.show(tabID, in: windowID)
        perform { try store.markActive(tabID: tabID) }
    }

    /// Takes the selected tab's live page from the window that shows it.
    public func bringSelectedHere() {
        guard let id = selectedTabID else { return }
        livePages.bringHere(id, to: windowID)
    }

    private func clearSelection() {
        guard selectedTabID != nil else { return }
        selectedTabID = nil
        livePages.release(windowID: windowID)
    }

    // MARK: - Workspaces and profiles

    public func switchWorkspace(to id: UUID) {
        if id == snapshot.workspace.id { return }
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
        if id == snapshot.profile.id { return }
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

    /// Closing the selected tab selects the tab row below it, else the one above, else nothing. An Essential follows grid order instead.
    public func close(_ tabID: UUID) {
        let wasSelected = tabID == selectedTabID
        let next = wasSelected ? neighbour(of: tabID) : nil
        guard let result = perform({ try store.closeTab(tabID) }) else { return }
        if case .archived = result { livePages.tabRemoved(tabID) }
        if wasSelected { select(next) }
    }

    private func neighbour(of tabID: UUID) -> UUID? {
        let essentialIDs = snapshot.essentials.map(\.id)
        let ids = essentialIDs.contains(tabID) ? essentialIDs : rows.compactMap { row -> UUID? in
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

    // MARK: - Command bar

    /// The profile's candidates plus the actions that apply now: pin, unpin, reset, close and copy only for what is selected.
    public func commandCandidates() -> CommandCandidates {
        var found: CommandCandidates
        do {
            found = try store.commandCandidates(profileID: snapshot.profile.id)
        } catch {
            lastError = StoreErrorText.message(for: error)
            found = CommandCandidates(workspaces: workspaces)
        }
        var actions: [CommandAction] = [.newWorkspace, .newProfile, .newWindow, .toggleCompactMode, .importFromArc, .showArchive]
        if let tab = selectedTab {
            let pinned = Self.pinnedTabs(snapshot.pinned).contains { $0.id == tab.id }
            let essential = snapshot.essentials.contains { $0.id == tab.id }
            if !pinned && !essential { actions.append(.pinTab) }
            if pinned { actions.append(.unpinTab) }
            if tab.isDrifted { actions.append(.resetPinnedTab) }
            actions += [.closeTab, .copyAddress]
        }
        actions += profiles.filter { $0.id != snapshot.profile.id }.map { .switchProfile(id: $0.id, name: $0.name) }
        actions += containers.map { .newTabInContainer(id: $0.id, name: $0.name) }
        found.actions = actions
        return found
    }

    /// Runs the chosen row. Writes go through the same private door as every other method; what needs UI comes back as an outcome.
    public func perform(_ result: CommandResult, mode: CommandBarMode) -> CommandOutcome {
        switch result {
        case .open(let url): open(url: url, mode: mode)
        case .search(let query): return search(query, mode: mode)
        case .tab(let found):
            if let target = found.workspaceID { switchWorkspace(to: target) }
            select(found.tab.id)
        case .archived(let archived): restoreArchived(archived.id)
        case .workspace(let workspace): switchWorkspace(to: workspace.id)
        case .action(let action): return run(action)
        }
        return .done
    }

    private func open(url: String, mode: CommandBarMode) {
        if mode == .currentTab, selectedTabID != nil { navigateSelected(to: url) } else { openTab(url: url) }
    }

    private func search(_ query: String, mode: CommandBarMode) -> CommandOutcome {
        let engine: SearchEngine?
        do { engine = try store.setting(SettingKeys.searchEngine) } catch {
            lastError = StoreErrorText.message(for: error)
            return .done
        }
        guard let engine else { return .chooseSearchEngine }
        open(url: engine.searchURL(for: query), mode: mode)
        return .done
    }

    private func run(_ action: CommandAction) -> CommandOutcome {
        switch action {
        case .newWorkspace: return .newWorkspace
        case .newProfile: return .newProfile
        case .newWindow: return .newWindow
        case .importFromArc: return .showArcImport
        case .showArchive: return .showArchive
        case .toggleCompactMode: perform { try store.setSetting(SettingKeys.compactMode, !(try store.setting(SettingKeys.compactMode))) }
        case .closeTab: if let id = selectedTabID { close(id) }
        case .pinTab: if let id = selectedTabID { pin(id, folderID: nil) }
        case .unpinTab: if let id = selectedTabID { unpin(id) }
        case .resetPinnedTab: if let id = selectedTabID { resetPinned(id) }
        case .copyAddress: if let tab = selectedTab { return .copy(tab.url) }
        case .switchProfile(let id, _): switchProfile(to: id)
        case .newTabInContainer(let id, _): openTab(url: "", containerID: id)
        }
        return .done
    }

    public func windowWillClose() { livePages.windowClosed(windowID) }
}
