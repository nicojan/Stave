import Foundation
import Testing
@testable import StaveCore

/// Decision 16 and questions 16–18: one table of shortcuts with Safari's meanings, ⌘1–9, ⌃Tab, ⇧⌘T and ⌘D.
struct StandardShortcutsTable {
    private func key(_ entry: ShortcutEntry) -> String { "\(entry.key)|\(entry.modifiers.rawValue)" }

    /// No two menu items share a key, over the whole table (the keys Stave had before Task 10 included, and ⌘Q and ⌘,). "=" and "+" are
    /// different keys.
    @Test func noTwoCommandsShareAKey() {
        let keys = StandardShortcuts.all.map(key)
        #expect(Set(keys).count == keys.count, "duplicates: \(Dictionary(grouping: keys) { $0 }.filter { $0.value.count > 1 }.keys.sorted())")
        let existing: [(String, ShortcutModifiers, ShortcutCommand)] = [
            ("t", .command, .newTab), ("n", .command, .newWindow), ("l", .command, .openLocation), ("w", .command, .closeTab),
            ("w", [.command, .shift], .closeWindow), ("s", [.control, .command], .toggleCompactMode), ("[", .command, .back),
            ("]", .command, .forward), ("r", .command, .reload), (".", .command, .stop), ("n", [.command, .shift], .newPrivateWindow),
            (ShortcutKey.upArrow, [.option, .command], .moveRowUp), (ShortcutKey.downArrow, [.option, .command], .moveRowDown),
            ("q", .command, .quit), (",", .command, .settings),
        ]
        for (key, modifiers, command) in existing {
            #expect(StandardShortcuts.command(key: key, modifiers: modifiers) == command, "\(key) \(modifiers.rawValue)")
        }
        for digit in 1...9 {
            #expect(StandardShortcuts.command(key: String(digit), modifiers: .control) == .switchWorkspace(digit))
        }
        #expect(StandardShortcuts.command(key: "=", modifiers: .command) != nil)
        #expect(StandardShortcuts.command(key: "+", modifiers: .command) != nil)
    }

    /// Each key decision 16 adds keeps its Safari meaning. ⌘D is the one deliberate change: Safari's Add Bookmark becomes Pin Tab.
    @Test func safariMeaningsKept() {
        let expected: [(String, ShortcutModifiers, ShortcutCommand)] = [
            ("f", .command, .find), ("g", .command, .findNext), ("g", [.command, .shift], .findPrevious), ("e", .command, .useSelectionForFind),
            ("+", .command, .zoomIn), ("=", .command, .zoomIn), ("-", .command, .zoomOut), ("0", .command, .actualSize),
            ("p", .command, .print), ("i", [.option, .command], .showWebInspector), ("u", [.option, .command], .showPageSource),
            ("y", .command, .showAllHistory), ("o", .command, .openFile), ("l", [.option, .command], .showDownloads),
            ("t", [.shift, .command], .reopenClosedTab),
            (ShortcutKey.tab, .control, .nextTab), (ShortcutKey.tab, [.control, .shift], .previousTab),
            ("]", [.shift, .command], .nextTab), ("[", [.shift, .command], .previousTab),
            ("d", .command, .pinTab),
        ]
        for (key, modifiers, command) in expected {
            #expect(StandardShortcuts.command(key: key, modifiers: modifiers) == command, "\(key) \(modifiers.rawValue)")
        }
        for digit in 1...9 {
            #expect(StandardShortcuts.command(key: String(digit), modifiers: .command) == .selectTab(digit))
        }
        #expect(StandardShortcuts.deliberateMappings == [.pinTab: "Add Bookmark"])
        // ⌘+ is shown, as in Safari's menu; ⌘= is its hidden alternate (the + needs Shift on most layouts).
        #expect(StandardShortcuts.shown(.zoomIn)?.key == "+")
        #expect(StandardShortcuts.hiddenEntry(key: "=", modifiers: .command)?.command == .zoomIn)
        #expect(StandardShortcuts.hiddenEntry(key: "]", modifiers: [.shift, .command])?.command == .nextTab)
        #expect(StandardShortcuts.hiddenEntry(key: "[", modifiers: [.shift, .command])?.command == .previousTab)
        #expect(StandardShortcuts.hiddenEntry(key: "=", modifiers: [.command, .shift]) == nil)
        #expect(StandardShortcuts.hiddenEntry(key: "f", modifiers: .command) == nil, "a shown key is the menu's, not a hidden entry")
        // Every command with a menu item has exactly one shown entry; ⌘1–9 have none (Safari lists them in no menu, ruling 6).
        let shownCounts = Dictionary(grouping: StandardShortcuts.all.filter { !$0.isHidden }, by: \.command).mapValues(\.count)
        #expect(shownCounts.values.allSatisfy { $0 == 1 })
        for entry in StandardShortcuts.all where entry.isHidden {
            if case .selectTab = entry.command { #expect(shownCounts[entry.command] == nil) } else { #expect(shownCounts[entry.command] == 1) }
        }
    }

    /// Review fix 1: the key monitor reads a key with the ⌘ map only (`characters(byApplyingModifiers: .command)`), so on "Dvorak – QWERTY ⌘"
    /// ⌘] reads "]" like AppKit's menus do and is Forward's, never Zoom In. Shift is ignored by that read, so ⇧⌘] reads "]" too.
    @Test func hiddenEntryMatchesTheCommandMapKey() {
        #expect(StandardShortcuts.hiddenEntry(key: "]", modifiers: .command) == nil, "⌘] is Forward's shown key")
        #expect(StandardShortcuts.hiddenEntry(key: "]", modifiers: [.shift, .command])?.command == .nextTab)
        #expect(StandardShortcuts.hiddenEntry(key: "=", modifiers: .command)?.command == .zoomIn)
        #expect(StandardShortcuts.hiddenEntry(key: "1", modifiers: .command)?.command == .selectTab(1))
        #expect(StandardShortcuts.hiddenEntry(key: "9", modifiers: .command)?.command == .selectTab(9))
        #expect(StandardShortcuts.hiddenEntry(key: "1", modifiers: [.command, .option]) == nil)
        #expect(StandardShortcuts.hiddenEntry(key: "1", modifiers: .control) == nil, "⌃1 is a workspace switch, a menu item")
        #expect(StandardShortcuts.hiddenEntry(key: "0", modifiers: .command) == nil)
    }

    /// Ruling 6: ⌘1–9 are hidden entries (no menu item), and no digit command has a title any more.
    @Test func tabNumbersAreHiddenEntries() {
        let entries = StandardShortcuts.all.filter { if case .selectTab = $0.command { true } else { false } }
        #expect(entries.count == 9)
        #expect(entries.allSatisfy { $0.isHidden && $0.modifiers == .command })
        for digit in 1...9 { #expect(StandardShortcuts.shown(.selectTab(digit)) == nil) }
    }

    /// The system's own keys (Hide, Minimise, Full Screen, the clipboard and Undo) are never taken.
    @Test func noEntryTakesASystemKey() {
        let reserved = Set(StandardShortcuts.systemReserved.map { "\($0.key)|\($0.modifiers.rawValue)" })
        for entry in StandardShortcuts.all { #expect(!reserved.contains(key(entry)), "\(entry.command)") }
    }

    /// Pre-flight T10-gate: every window command waits for a sheet, as ⌘N does since Task 4. Only the compact toggle (a setting) runs over a
    /// sheet; Quit and Settings are the app's, not a window's.
    @Test func everyEntryIsGatedWhileSheetUp() {
        for entry in StandardShortcuts.all {
            switch entry.command {
            case .quit, .settings:
                #expect(entry.gate == nil)
                #expect(entry.isEnabled(busy: true) && entry.isEnabled(busy: false), "the app's own commands are never gated")
            case .toggleCompactMode:
                #expect(entry.gate == .toggleCompactMode)
                #expect(entry.isEnabled(busy: true), "a setting runs over a sheet")
            default:
                guard let gate = entry.gate else {
                    Issue.record("\(entry.command) has no gate")
                    continue
                }
                #expect(!MenuCommandGate.isEnabled(gate, busy: true), "\(entry.command)")
                #expect(MenuCommandGate.isEnabled(gate, busy: false), "\(entry.command)")
                // Review fix 5: the menus and the key monitor both ask the entry itself, so the declared gate is the real guard.
                #expect(!entry.isEnabled(busy: true), "\(entry.command)")
                #expect(entry.isEnabled(busy: false), "\(entry.command)")
            }
        }
    }

    @Test func keysAreSingleCharactersAndTitlesExist() {
        for entry in StandardShortcuts.all { #expect(entry.key.count == 1, "\(entry.command)") }
        #expect(ShortcutText.title(.pinTab) == "Pin Tab")
        #expect(SidebarAction.pin.menuTitle == ShortcutText.pinTabTitle, "Pin Tab has one definition")
        #expect(ShortcutText.title(.pinTab) == ShortcutText.pinTabTitle)
        #expect(ShortcutText.title(.reopenClosedTab) == "Reopen Last Closed Tab")
        #expect(ShortcutText.title(.nextTab) == "Show Next Tab")
        #expect(ShortcutText.title(.previousTab) == "Show Previous Tab")
        #expect(ShortcutText.title(.showDownloads) == "Show Downloads")
    }
}

/// ⌘D's enablement (question 18): only on a regular tab's web page in a normal window, never as an unpin.
struct PinShortcutRule {
    private func page(_ section: SlotSection?, isPrivate: Bool = false) -> PageStatusSummary {
        PageStatusSummary(hasPage: true, selectedSection: section, isPrivate: isPrivate)
    }

    @Test func commandDNeverUnpins() {
        #expect(PageMenuState.from(status: page(.regular), sheetOpen: false).canPinSelected)
        #expect(!PageMenuState.from(status: page(.pinned), sheetOpen: false).canPinSelected)
        #expect(!PageMenuState.from(status: page(.essential), sheetOpen: false).canPinSelected)
        #expect(!PageMenuState.from(status: page(nil), sheetOpen: false).canPinSelected, "no tab selected")
        #expect(!PageMenuState.from(status: page(.regular, isPrivate: true), sheetOpen: false).canPinSelected)
        #expect(!PageMenuState.from(status: nil, sheetOpen: false).canPinSelected, "a tab with no web page")
        var blank = page(.regular)
        blank.isBlank = true
        #expect(!PageMenuState.from(status: blank, sheetOpen: false).canPinSelected)
        var failed = page(.regular)
        failed.hasFailure = true
        #expect(!PageMenuState.from(status: failed, sheetOpen: false).canPinSelected)
        #expect(!PageMenuState.from(status: page(.regular), sheetOpen: true).canPinSelected)
        #expect(!PageMenuState.from(status: page(.regular), sheetOpen: false, historyShown: true).canPinSelected)
    }
}

/// Records the page-lifecycle calls, in order.
@MainActor
private final class LifecycleSpy: PageLifecycle {
    private(set) var calls: [String] = []
    func tabClosed(_ id: UUID) { calls = calls + ["closed \(id)"] }
    func tabUnloaded(_ id: UUID) { calls = calls + ["unloaded \(id)"] }
    func tabDeselected(_ id: UUID) { calls = calls + ["deselected \(id)"] }
    func tabNavigated(_ id: UUID) { calls = calls + ["navigated \(id)"] }
    func tabOpenedByUser(_ id: UUID) { calls = calls + ["opened \(id)"] }
}

@MainActor
struct TabShortcutModelTests {
    @MainActor private struct World {
        let store: OrganizationStore
        let revision = StoreRevision()
        let livePages = LivePageRegistry()
        let clock: TestClock
        let profile: Profile
        let home: Workspace

        func window(workspace: Workspace? = nil) throws -> BrowserWindowModel {
            let state = WindowState(profileID: profile.id, workspaceID: (workspace ?? home).id, selectedTabID: nil, frame: "", sortIndex: 0)
            return try BrowserWindowModel(store: store, revision: revision, livePages: livePages, state: state)
        }

        func tab(_ name: String, in workspace: Workspace? = nil) throws -> Tab {
            try store.openTab(
                url: "https://example.com/\(name)", title: name, workspaceID: (workspace ?? home).id,
                origin: .commandBar, containerID: nil, edge: .bottom
            )
        }

        func pinned(_ name: String, folder: Folder? = nil) throws -> Tab {
            let tab = try tab(name)
            try store.pinTab(tab.id, folderID: folder?.id)
            return tab
        }

        func essential(_ name: String) throws -> Tab {
            let tab = try tab(name)
            try store.makeEssential(tab.id)
            return tab
        }

        func collapsedFolder() throws -> Folder {
            let folder = try store.createFolder(workspaceID: home.id, parentFolderID: nil, title: "Invented Folder")
            try store.setFolderOpen(folder.id, false)
            return folder
        }
    }

    private func makeWorld() throws -> World {
        let clock = TestClock()
        let (store, _, _) = try makeTempStore(now: clock.now)
        let profile = try store.ensureDefaultProfile()
        let home = try #require(try store.workspaces(profileID: profile.id).first)
        return World(store: store, clock: clock, profile: profile, home: home)
    }

    // MARK: - ⌘1–9 (question 17)

    @Test func selectByNumber() throws {
        let world = try makeWorld()
        let essential = try world.essential("e1")
        let pinned = try world.pinned("p1")
        let folder = try world.collapsedFolder()
        let hidden = try world.pinned("p2", folder: folder)
        let first = try world.tab("r1")
        let last = try world.tab("r2")
        let model = try world.window()

        model.selectTab(number: 1)
        #expect(model.selectedTabID == essential.id)
        model.selectTab(number: 2)
        #expect(model.selectedTabID == pinned.id)
        model.selectTab(number: 3)
        #expect(model.selectedTabID == first.id, "the pinned tab in the collapsed folder is skipped")
        model.selectTab(number: 9)
        #expect(model.selectedTabID == last.id)
        for number in [5, 8, 0, -1, 10, Int.min, Int.max] {
            model.selectTab(number: number)
            #expect(model.selectedTabID == last.id, "⌘\(number) past the end does nothing")
        }
        for number in 1...9 {
            model.selectTab(number: number)
            #expect(model.selectedTabID != hidden.id)
        }
    }

    /// Ruling 6: the key monitor consumes ⌘n only when the tab exists, so a key that does nothing goes on to whoever wants it.
    @Test func selectTabReportsWhetherItActed() throws {
        let world = try makeWorld()
        let first = try world.tab("a")
        _ = try world.tab("b")
        let model = try world.window()
        #expect(model.selectTab(number: 1))
        #expect(model.selectedTabID == first.id)
        #expect(model.selectTab(number: 9))
        #expect(!model.selectTab(number: 5))
        #expect(!model.selectTab(number: 0))
        #expect(!model.selectTab(number: 10))
        let empty = try makeWorld().window()
        #expect(!empty.selectTab(number: 9), "no tabs: nothing to select")
        let privateModel = PrivateWindowModel(newTabEdge: .bottom)
        #expect(!privateModel.selectTab(number: 1))
        _ = privateModel.open(url: "https://example.com/a", below: nil, select: false)
        #expect(privateModel.selectTab(number: 1))
        #expect(!privateModel.selectTab(number: 2))
    }

    @Test func commandNineSelectsTheLastOfFewTabs() throws {
        let world = try makeWorld()
        _ = try world.tab("a")
        _ = try world.tab("b")
        let third = try world.tab("c")
        let model = try world.window()
        model.selectTab(number: 9)
        #expect(model.selectedTabID == third.id)
    }

    @Test func commandNineWithNoRegularTabsSelectsTheLastPinnedTab() throws {
        let world = try makeWorld()
        _ = try world.pinned("p1")
        let lastPinned = try world.pinned("p2")
        let model = try world.window()
        model.selectTab(number: 9)
        #expect(model.selectedTabID == lastPinned.id)
    }

    // MARK: - ⌃Tab and ⌃⇧Tab

    @Test func adjacentWraps() throws {
        let world = try makeWorld()
        let a = try world.tab("a")
        _ = try world.tab("b")
        let c = try world.tab("c")
        let model = try world.window()
        model.selectAdjacentTab(1)
        #expect(model.selectedTabID == a.id, "with no selection ⌃Tab selects the first")
        model.selectAdjacentTab(-1)
        #expect(model.selectedTabID == c.id, "wraps backwards")
        model.selectAdjacentTab(1)
        #expect(model.selectedTabID == a.id, "wraps forwards")
        model.select(nil)
        model.selectAdjacentTab(-1)
        #expect(model.selectedTabID == c.id, "with no selection ⌃⇧Tab selects the last")
    }

    @Test func adjacentSkipsCollapsedFolder() throws {
        let world = try makeWorld()
        let pinned = try world.pinned("p1")
        let folder = try world.collapsedFolder()
        _ = try world.pinned("p2", folder: folder)
        let regular = try world.tab("r1")
        let model = try world.window()
        model.select(pinned.id)
        model.selectAdjacentTab(1)
        #expect(model.selectedTabID == regular.id)
        model.selectAdjacentTab(-1)
        #expect(model.selectedTabID == pinned.id)
    }

    // MARK: - ⇧⌘T

    @Test func reopenLastClosedRestoresNewest() throws {
        let world = try makeWorld()
        let other = try world.store.createWorkspace(profileID: world.profile.id, name: "Two", icon: "", colorHex: "#FFFFFF")
        let a = try world.tab("a")
        let b = try world.tab("b")
        let elsewhere = try world.tab("c", in: other)
        let spy = LifecycleSpy()
        let model = try world.window()
        model.pages = spy

        model.reopenLastClosed()
        #expect(model.selectedTabID == nil, "nothing when the archive is empty")
        #expect(spy.calls.isEmpty)

        model.close(a.id)
        world.clock.advance(by: 60)
        model.close(b.id)
        world.clock.advance(by: 60)
        _ = try world.store.closeTab(elsewhere.id) // newer, but another workspace's

        model.reopenLastClosed()
        let reopened = try #require(model.selectedTab)
        #expect(reopened.url == b.url)
        #expect(spy.calls.contains("opened \(reopened.id)"))

        model.reopenLastClosed()
        #expect(model.selectedTab?.url == a.url)
        let afterBoth = spy.calls
        model.reopenLastClosed()
        #expect(model.selectedTab?.url == a.url, "the other workspace's archived tab stays archived")
        #expect(spy.calls == afterBoth)
        #expect(try world.store.archivedTabs(profileID: world.profile.id).map(\.url) == [elsewhere.url])
    }

    /// The lifecycle hears about the reopened tab before it is selected, so the page the window makes for it is user-opened.
    @Test func reopenedTabOpenedByUserBeforeSelection() throws {
        let world = try makeWorld()
        let a = try world.tab("a")
        let keep = try world.tab("keep")
        let spy = LifecycleSpy()
        let model = try world.window()
        model.pages = spy
        model.select(keep.id)
        model.close(a.id)
        model.reopenLastClosed()
        let reopened = try #require(model.selectedTabID)
        let opened = try #require(spy.calls.firstIndex(of: "opened \(reopened)"))
        let deselected = try #require(spy.calls.firstIndex(of: "deselected \(keep.id)"))
        #expect(opened < deselected)
    }

    // MARK: - ⌘D (question 18)

    @Test func commandDPinsRegularTab() throws {
        let world = try makeWorld()
        let existing = try world.pinned("p1")
        let regular = try world.tab("r1")
        let model = try world.window()
        model.select(regular.id)
        model.pinSelectedTab()
        #expect(model.selectedTabID == regular.id)
        #expect(model.snapshot.regular.isEmpty)
        let ids = model.snapshot.pinned.compactMap { item -> UUID? in if case .tab(let tab) = item { tab.id } else { nil } }
        #expect(ids == [existing.id, regular.id], "at the end of the workspace's pinned tabs")
    }

    @Test func commandDOnPinnedOrEssentialChangesNothing() throws {
        let world = try makeWorld()
        let essential = try world.essential("e1")
        _ = try world.pinned("p1")
        let folder = try world.store.createFolder(workspaceID: world.home.id, parentFolderID: nil, title: "Invented Folder")
        let inFolder = try world.pinned("p2", folder: folder)
        _ = try world.tab("r1")
        let model = try world.window()
        let before = model.snapshot

        model.pinSelectedTab()
        #expect(model.snapshot == before, "no selection")
        model.select(inFolder.id)
        model.pinSelectedTab()
        #expect(model.snapshot.pinned == before.pinned, "a pinned tab in a folder keeps its folder and place")
        model.select(essential.id)
        model.pinSelectedTab()
        #expect(model.snapshot.essentials.map(\.id) == [essential.id])
        #expect(model.snapshot.pinned == before.pinned)
    }

    // MARK: - Private windows (pre-flight T10-order)

    @Test func privateWindowSelectsByNumberAndWraps() {
        let model = PrivateWindowModel(newTabEdge: .bottom)
        let a = model.open(url: "https://example.com/a", below: nil, select: false)
        _ = model.open(url: "https://example.org/b", below: nil, select: false)
        let c = model.open(url: "https://example.net/c", below: nil, select: false)
        model.selectTab(number: 1)
        #expect(model.selectedTabID == a)
        model.selectTab(number: 9)
        #expect(model.selectedTabID == c)
        model.selectTab(number: 4)
        #expect(model.selectedTabID == c)
        model.selectAdjacentTab(1)
        #expect(model.selectedTabID == a)
        model.selectAdjacentTab(-1)
        #expect(model.selectedTabID == c)
    }
}

/// The ordering rule shared by both kinds of window.
struct TabOrderRule {
    private let ids = (0..<3).map { _ in UUID() }

    @Test func numbersAndWrapping() {
        #expect(TabOrder.tab(number: 1, in: ids) == ids[0])
        #expect(TabOrder.tab(number: 3, in: ids) == ids[2])
        #expect(TabOrder.tab(number: 4, in: ids) == nil)
        #expect(TabOrder.tab(number: 9, in: ids) == ids[2])
        #expect(TabOrder.tab(number: 9, in: []) == nil)
        #expect(TabOrder.tab(number: 0, in: ids) == nil)
        #expect(TabOrder.tab(number: Int.min, in: ids) == nil)
        #expect(TabOrder.adjacent(to: ids[2], by: 1, in: ids) == ids[0])
        #expect(TabOrder.adjacent(to: ids[0], by: -1, in: ids) == ids[2])
        #expect(TabOrder.adjacent(to: nil, by: 1, in: ids) == ids[0])
        #expect(TabOrder.adjacent(to: nil, by: -1, in: ids) == ids[2])
        #expect(TabOrder.adjacent(to: UUID(), by: 1, in: ids) == ids[0], "a selection outside the list counts as none")
        #expect(TabOrder.adjacent(to: nil, by: 1, in: []) == nil)
        #expect(TabOrder.adjacent(to: ids[1], by: Int.min, in: ids) != nil, "a huge step can't overflow")
    }
}

/// When the tab items Task 10 adds are enabled: never with a sheet up; ⇧⌘T never in a private window (it has no archive); ⌥⌘L only while
/// the window has downloads to show.
struct TabShortcutMenuRule {
    @Test func tabShortcutItemsFollowTheGate() {
        let free = TabShortcutMenuState.from(busy: false, isPrivate: false, tabCount: 3, hasDownloads: true)
        #expect(free.canSelectTab && free.canReopenClosedTab && free.canShowDownloads)
        let busy = TabShortcutMenuState.from(busy: true, isPrivate: false, tabCount: 3, hasDownloads: true)
        #expect(!busy.canSelectTab && !busy.canReopenClosedTab && !busy.canShowDownloads)
        let privateWindow = TabShortcutMenuState.from(busy: false, isPrivate: true, tabCount: 3, hasDownloads: false)
        #expect(privateWindow.canSelectTab && !privateWindow.canReopenClosedTab && !privateWindow.canShowDownloads)
        let empty = TabShortcutMenuState.from(busy: false, isPrivate: false, tabCount: 0, hasDownloads: false)
        #expect(!empty.canSelectTab && empty.canReopenClosedTab)
        #expect(TabShortcutMenuState.disabled == TabShortcutMenuState(canSelectTab: false, canReopenClosedTab: false, canShowDownloads: false))
    }
}
