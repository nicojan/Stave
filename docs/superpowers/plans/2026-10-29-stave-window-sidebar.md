# Stave Window and Sidebar Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** A Stave window you can live in without web pages: the real sidebar (address field, Essentials grid, workspace switcher by click, ⌃1–9 and swipe, pinned folders, regular tabs, archive, drag and drop), the command bar, compact mode, the "bring it here" placeholder, VoiceOver and keyboard-only use, and the Arc import UI. A tab shows a placeholder instead of a page until plan 3.

**Architecture:** Logic lives in `StaveCore`, unit-tested with `swift test`: store additions (moves, settings, import record), pure helpers (sidebar rows and labels, address-input classification, command-bar ranking, drop planning, swipe and compact-reveal state machines, import-report text) and `@MainActor @Observable` models (`BrowserWindowModel`, `CommandBarModel`, `ArcImportFlow`, `LivePageRegistry`). The app target holds AppKit windows hosting thin SwiftUI views that read those models and call their methods. One shared `StoreRevision` counter is bumped after every write, and every window re-reads its snapshot when it changes.

**Tech Stack:** Swift 6 (language mode 6, must compile on Swift 6.0.3 / Xcode 16.2), Swift Testing, GRDB 7 (capped `<7.9`), Observation, SwiftUI hosted in AppKit `NSWindow`s, XcodeGen.

**Spec:** `docs/superpowers/specs/2026-10-28-stave-design.md`: "The organization model", "Data model rules", "First release" items 1, 2, 3, 4 (UI only) and 9. Inputs also: roadmap entry 4 in `2026-10-28-stave-foundation.md`, and the "Carried into later plans" sections at the end of that plan and of `2026-10-29-stave-arc-import.md`.

## Global Constraints

- macOS deployment target `14.0`; `SWIFT_VERSION` `6.0`; strict concurrency complete. No Swift 6.1+ features and no macOS 15-only APIs: no `Synchronization.Mutex`, no default-actor-isolation settings, no `@concurrent`. Never nest `try #require` inside `#expect`; hoist it to a `let`.
- Bundle ID `com.nicojan.Stave`, Debug `com.nicojan.Stave.debug`. The data folder is always explicit; never open a store through a framework default path.
- Logic goes in `StaveCore` with tests. A view may hold layout, focus and animation state, nothing else; anything with a rule in it (ordering, text, enablement, thresholds) is a `StaveCore` function the view calls.
- Nothing is deleted without passing through the archive, except a confirmed profile or container deletion (none in this plan).
- Test fixtures are synthetic: URLs on `example.com`, `example.org`, `example.net`; invented titles. Never read `~/Library/Application Support/Arc/` from tests, the app under check, logs or commits. By-hand checks always pass `-StaveArcHome` pointing at a folder holding a synthetic fixture.
- Every interactive element has an accessibility label (from `SidebarLabels` where one exists) and is reachable with the keyboard alone. Animations are skipped when Reduce Motion is on.
- Shortcuts that Safari or Chrome already define keep their Safari meaning (⌘T, ⌘N, ⌘L, ⌘W, ⇧⌘W).
- Licence MIT. Copy no code from Zen (MPL-2.0), Ora (GPL-2.0) or Nook (GPL-3.0); behaviour reference only.
- Commits: `<type>: <description>`; stage named paths only, never `git add -A`; never `--no-verify`, never force-push. Markdown is never hard-wrapped.
- After any change that adds or removes app files, run `xcodegen generate` and commit `Stave.xcodeproj/project.pbxproj` with the task.

### The by-hand check (every task that changes the UI ends with it)

1. Build: `xcodegen generate && xcodebuild build -project Stave.xcodeproj -scheme Stave -configuration Debug -destination 'platform=macOS' -derivedDataPath build/DD -quiet` → exits 0.
2. Make a throwaway folder (literal path, e.g. `/private/tmp/stave-check-<task>`; the guard hook refuses unresolved variables) with `data/` and, when the task needs an Arc file, `home/Library/Application Support/Arc/StorableSidebar.json` copied from `Packages/StaveCore/Tests/StaveCoreTests/Fixtures/arc/basic.json`.
3. Launch: `open -n build/DD/Build/Products/Debug/Stave.app --args -StaveDataDirectory <folder>/data -StaveArcHome <folder>/home -StaveSeedSample`.
4. Drive it with the keyboard through System Events where the task says so (`osascript -e 'tell application "System Events" to keystroke "t" using command down'`).
5. Capture: `swift scripts/capture-window.swift Stave <scratchpad>/plan4-task<N>-<what>.png`, then open the PNG and confirm each item the task lists. Screenshots stay in the session scratchpad, never in the repo.
6. Check labels where the task says so: `scripts/ax-dump.sh Stave` prints role and description of every element in the front window.
7. Quit: `osascript -e 'quit app "Stave"'`.
8. Anything that needs a pointer or trackpad (hover, drag, swipe) and can't be driven from the shell goes on the task's "Nico checks" list, which the controller collects for Nico's review instead of claiming it was seen.

If the terminal lacks Screen Recording or Accessibility permission, stop and ask Nico to grant it; never skip the screenshot.

## Decisions left to the builder (my call)

Each is the planner's call where the spec leaves it open, with a one-line reason. Nico can overturn any of them.

Look and layout:

1. **Sidebar on the left, no toolbar; the traffic lights sit over the sidebar** (full-size content view, transparent title bar). Reason: Arc and Zen's layout, and the spec puts the address field in the sidebar.
2. **Sidebar 260 pt wide by default, drag-resizable 200–400 pt, one width for the whole app.** Reason: fits four Essentials across; per-window widths add state for little gain.
3. **Sidebar order, top to bottom:** address field, Essentials grid, pinned tree, a "New Tab" row, regular tabs, then a bottom bar with the archive button, a profile menu (shown only with two or more profiles) and the workspace switcher. Reason: Arc's order, which importers already know.
4. **Workspace tint:** the workspace colour at 12% opacity over the sidebar material. Reason: visible but calm, and text contrast holds.
5. **Essentials grid:** adaptive columns, tiles at least 52 pt wide and 44 pt high, each showing a monogram (favicons come with plan 3); the title is in the tooltip and the VoiceOver label. Reason: Arc's look without the web layer.
6. **Monogram:** the first letter of the host without `www.`, uppercase; `?` when there is none. Reason: no favicons before plan 3.
7. **Address field:** shows the host without `www.`; ⌘L or a click shows the full URL in the command bar. Reason: Safari's default.
8. **Workspace icons:** a non-ASCII `icon` is an emoji, an ASCII one is an SF Symbol name, and an empty or unknown symbol shows `square.grid.2x2`. Reason: plan 2 ruling 5.
9. **Workspace editor:** a name, an emoji field or a choice of 12 SF Symbols, and 8 colours plus Home grey (`#8E8E93`). Reason: a small palette keeps tints legible.
10. **Content area:** a placeholder card with the monogram, title, full URL and "Pages load here once Stave's web engine is connected." A drifted pinned tab also gets a "Back to Pinned Page" button. With no selection: "No tab selected" and a New Tab button. Reason: plan 3 hasn't started.
11. **Window:** default 1200 × 800, minimum 800 × 500. The window title (hidden, but used by the Window menu and VoiceOver) is the selected tab's title, or the workspace name. Reason: usual browser size; the title keeps window switching accessible.

Behaviour:

12. **Selecting a sidebar row selects the tab**, so ↑/↓ switch tabs as in a Finder list. Reason: standard `List` keyboard behaviour, and cheap while tabs are placeholders.
13. **Closing the selected tab selects the row below, else the row above, else nothing.** Pinned tabs and Essentials unload (store rule) and follow the same selection rule. Reason: Safari and Chrome behaviour.
14. **A new window opens on the current window's profile and workspace, with no tab selected.** Reason: windows are views; this avoids an instant "showing in another window".
15. **⌃1–9 picks the Nth workspace of the window's profile;** ⌃9 is the ninth, not the last, and a missing N does nothing. Reason: Arc's behaviour.
16. **Swipe:** two-finger horizontal swipe over the sidebar, 60 pt of finger travel, one switch per gesture, no wrap at either end, momentum ignored, and fingers moving left go to the next workspace. Reason: avoids double switches and matches page-swipe direction.
17. **Compact mode:** shortcut ⌃⌘S (macOS's standard "Toggle Sidebar"); the sidebar shows as an overlay when the pointer is within 8 pt of the left edge, and hides 0.4 s after the pointer leaves it. It stays while a menu, a drag or the command bar is open. Reason: ⌘S means Save in Safari and Chrome.
18. **Animations:** workspace switch slides 0.2 s in the direction of travel, compact reveal slides 0.15 s, the command bar fades 0.12 s; none under Reduce Motion. Reason: quick enough never to feel slow.
19. **No "focus sidebar" shortcut yet:** nothing else takes keyboard focus until web pages exist, and focus returns to the sidebar list when the command bar closes. Reason: plan 3 revisits once pages can take focus.
20. **Keyboard move:** ⌥⌘↑ and ⌥⌘↓ move the selected row within its list, also offered as VoiceOver actions. Reason: a drag-free way to reorder; neither shortcut is taken in Safari or Chrome.
21. **Address-field navigation without the web layer** stores the typed URL on the tab and clears its title, so the sidebar shows the host. Reason: no page exists to report a title.

Command bar:

22. **Centered overlay, 600 pt wide.** Reason: Arc and Raycast style.
23. **The typed row comes first** ("Open example.com" or "Search for …"), then up to 11 matches ranked title prefix > word prefix > substring (title or URL), then by kind (open tabs, workspaces, actions, archived tabs). Reason: Return always does what you typed; ↓ reaches the matches.
24. **Only `http`/`https` text, or scheme-less text that looks like a host, opens as a URL;** `javascript:`, `file:`, `data:` and anything with a space become a search. Reason: safe by default.
25. **An empty command bar lists the profile's open tabs, most recently used first.** Reason: Arc and Chrome.
26. **History isn't a command-bar source yet;** the ranking takes it as one more candidate kind when plan 3/5 records visits. Reason: nothing records visits before the web layer.
27. **The search engine is chosen on the first-run screen, with nothing preselected, and can be changed in Settings.** Until one is chosen, the search row reads "Choose a search engine". Reason: the spec says "chosen at first run" and plan 4 owns the first-run screen. This takes one setting from plan 5's item 8.

Data and plumbing:

28. **Settings live in the database (a `setting` table), not UserDefaults.** Reason: a throwaway data folder gives a clean first run, and settings travel with the data.
29. **A repeat Arc import is detected from an `importRecord` row** written in the import's own transaction. Reason: it can't disagree with the data it describes.
30. **A picked Arc file:** Stave also looks for `User Data/Local State` beside it for profile names. Reason: that is Arc's own folder layout, so a copied folder keeps its names.
31. **Report labels:** when two or more spaces in one import share a name, each label gets " (1)", " (2)" in sidebar order; Favorites entries name their Arc profile (none for the default profile). Workspace names themselves are unchanged. Reason: plan 2's carry-forward.
32. **One shared `StoreRevision` counter, bumped after each write; every window re-reads.** Reason: synchronous and testable, unlike GRDB value observation.
33. **Window state is saved 0.5 s after the last change;** closing a window that isn't the last removes it from the saved set; closing the last keeps it for the next launch. Reason: plan 1's "save as it changes" without a write on every resize event.
34. **Restored frames** move fully onto the screen they overlap most, shrinking to fit; a frame on no screen is centred on the first screen. Reason: plan 1's carry-forward.
35. **`trimArchive` runs once at launch.** Reason: plan 1's carry-forward; cheap.
36. **Debug-only launch arguments `-StaveDataDirectory`, `-StaveArcHome` and `-StaveSeedSample` replace "Add sample tab".** Reason: by-hand checks run on throwaway synthetic data and never see the real Arc file.
37. **Menus are built with SwiftUI `.commands` that call the app delegate,** as the Debug menu does today. ⌘T New Tab, ⌘N New Window, ⌘L Open Location, ⌘W Close Tab, ⇧⌘W Close Window, File ▸ Import from Arc…, View ▸ Compact Mode (⌃⌘S), and a Workspaces menu with ⌃1–9 and New Workspace. Reason: Safari's assignments, and no `FocusedValue` plumbing through AppKit-hosted views.
38. **Drag payload is the tab's URL,** so a tab dropped on another app gives its link; in-app drops identify the item through the app's current-drag state. Reason: no custom UTType to declare.
39. **Dropping a tab on a workspace icon** moves it to that workspace and keeps it pinned (end of the pinned root) or regular (top). Essentials can't be dropped there. Reason: Essentials are profile-wide.
40. **Folders move only within their workspace.** Reason: the smallest change plan 1's carry-forward asks for.
41. **Profiles:** create and switch in plan 4; rename and delete wait for plan 5's Settings. Reason: deletion needs the confirmation UI plan 5 builds.
42. **Containers:** tabs show their container's colour as a dot, and the command bar offers "New Tab in ‹container›" for existing named containers; creating and deleting containers waits. Reason: the spec's cut line puts containers after the beta.
43. **The import sheet tells Arc users to keep a copy of `StorableSidebar.json`** before Arc shuts down on 2026-12-22. Reason: it is unknown whether Arc deletes it.
44. **Stave isn't sandboxed (spec), so it needs no user-granted file access to read Arc's folder.** This closes plan 2's sandbox carry-forward. Reason: the spec's distribution decision.

Deferred, with reasons: a late-arriving favicon as `pinnedFaviconURL` needs the web layer (plan 3). Plan 2's "test debts that can wait" stay deferred. The `.debug` data-folder mapping and `markActive`'s `modifiedAt` aren't plan 4 items.

## Review Focus

1. **Command-bar text that looks like a link but isn't a web address** (`javascript:alert(1)`, `JavaScript:void(0)`, `file:///etc/hosts`, `data:text/html,x`, `about:blank`): never opened as a URL; offered as a search. Test in Task 11 (`nonWebSchemesBecomeSearches`).
2. **A window's workspace is deleted from another window** (or by the user in the switcher while two windows show it): the other window falls back to its profile's first workspace with no selection, and nothing crashes. Test in Task 10 (`workspaceDeletedElsewhereFallsBack`).
3. **A tab selected in one window is closed in another:** the first window's selection clears and the live-page claim is released, so a later window can show it. Test in Task 10 (`selectedTabClosedElsewhereClearsSelection`).
4. **A picked "Arc file" that is huge, a folder, missing or not Arc's:** a plain-words message, nothing written, no import record. Tests in Task 5 (`oversizedFileRefusedBeforeReading`, `directoryIsUnreadable`) and Task 18 (`failedImportLeavesNoRecord`).
5. **A saved window frame on a display that is no longer connected:** the window opens on a visible screen. Test in Task 4 (`frameOnMissingScreenIsCentred`).

---

## File structure

```
Packages/StaveCore/Sources/StaveCore/
├── OrganizationStore+Ordering.swift      # T1: Child, renumber, crowding loop, essentials query, folder check (moved/merged)
├── OrganizationStore+Folders.swift       # T2: moveFolder, setFolderOpen, renameFolder (+ create/delete moved here)
├── OrganizationStore+Move.swift          # T2: MoveAnchor, moveTab(after: MoveAnchor?)
├── OrganizationStore.swift               # T2: updateWorkspace, moveWorkspace
├── Database/StaveDatabase.swift          # T3: migration v2 (setting); T5: v3 (importRecord)
├── Settings/SettingKey.swift             # T3: SettingKey, SettingKeys
├── Settings/SearchEngine.swift           # T3
├── OrganizationStore+Settings.swift      # T3
├── Session/WindowFrameClamp.swift        # T4
├── Session/WindowSession.swift           # T4
├── Debug/SampleOrganization.swift        # T4
├── OrganizationStore+Imports.swift       # T5: ImportSource, lastImport
├── ArcImport/ArcImporter.swift           # T5: file entry point, Local State beside a picked file
├── ArcImport/ArcImportReport.swift       # T6: Place
├── ArcImport/ArcImportPlanner.swift      # T6: labels
├── ArcImport/ArcSidebarParser.swift      # T6: count only non-empty unrecognised Favorites
├── ArcImport/ArcImportSummary.swift      # T7: plain-words report and copy
├── ArcImport/ArcImportFlow.swift         # T18
├── Sidebar/DisplayText.swift             # T8: title, address, monogram, WorkspaceIcon
├── Sidebar/SidebarRows.swift             # T8: SidebarItemID, SidebarRow, SidebarRows, SidebarLabels
├── Sidebar/WorkspaceSwipeTracker.swift   # T14
├── Sidebar/SidebarDropPlanner.swift      # T16
├── Window/LivePageRegistry.swift         # T9
├── Window/StoreRevision.swift            # T10
├── Window/StoreErrorText.swift           # T10
├── Window/BrowserWindowModel.swift       # T10 (+ T11 perform, T16 apply)
├── Window/CompactReveal.swift            # T17
├── CommandBar/AddressInput.swift         # T11
├── CommandBar/CommandBarSearch.swift     # T11: CommandAction, CommandResult, CommandCandidates, ranking
├── CommandBar/CommandBarModel.swift      # T11
└── OrganizationStore+CommandBar.swift    # T11: commandCandidates
Stave/
├── App/StaveApp.swift                    # menus (T12, T14, T15, T17, T18)
├── App/AppDelegate.swift                 # T12: split out of StaveApp.swift
├── App/AppEnvironment.swift              # T12: revision, live pages, window session, debug options
├── App/DebugLaunchOptions.swift          # T12
├── App/BrowserWindowController.swift     # T12
├── Views/BrowserWindowView.swift         # T12
├── Views/Content/TabPlaceholderView.swift            # T12
├── Views/Sidebar/SidebarView.swift                   # T12, T13
├── Views/Sidebar/SidebarRowView.swift                # T13
├── Views/Sidebar/EssentialsGrid.swift                # T13
├── Views/Sidebar/AddressField.swift                  # T13
├── Views/Sidebar/ArchivePopover.swift                # T13
├── Views/Sidebar/WorkspaceSwitcher.swift             # T14
├── Views/Sidebar/WorkspaceEditor.swift               # T14
├── Views/Sidebar/SwipeCatcher.swift                  # T14 (NSViewRepresentable)
├── Views/CommandBar/CommandBarView.swift             # T15
├── Views/Compact/CompactContainer.swift              # T17
├── Views/Import/FirstRunView.swift                   # T19
├── Views/Import/ArcImportSheet.swift                 # T19
└── Views/Settings/SettingsView.swift                 # T14, T17, T19
scripts/capture-window.swift, scripts/ax-dump.sh      # T12
```

Delete: `Stave/Views/FoundationSidebarView.swift` (T12).

## Shared types (defined in the task named, used by later tasks)

```swift
// T2
public enum MoveAnchor: Sendable, Equatable { case tab(UUID), folder(UUID) }
// T3
public struct SettingKey<Value: Codable & Sendable & Equatable>: Sendable { public let name: String; public let defaultValue: Value }
public enum SettingKeys {   // not "Settings": that clashes with SwiftUI's scene
    public static let workspaceShortcutsEnabled = SettingKey<Bool>(name: "workspaceShortcutsEnabled", defaultValue: true)
    public static let compactMode = SettingKey<Bool>(name: "compactMode", defaultValue: false)
    public static let firstRunCompleted = SettingKey<Bool>(name: "firstRunCompleted", defaultValue: false)
    public static let searchEngine = SettingKey<SearchEngine?>(name: "searchEngine", defaultValue: nil)
    public static let newTabEdge = SettingKey<NewTabEdge>(name: "newTabEdge", defaultValue: .top)
    public static let sidebarWidth = SettingKey<Double>(name: "sidebarWidth", defaultValue: 260)
}
public enum SearchEngine: String, Codable, Sendable, CaseIterable { case google, duckDuckGo, kagi, bing, ecosia }
// T5
public enum ImportSource: String, Codable, Sendable { case arc }
// T6
extension ArcImportReport { public enum Place: Equatable, Sendable { case space(String), favorites(profile: String?) } }
// T8
public enum SidebarItemID: Hashable, Sendable { case tab(UUID), folder(UUID) }
public struct SidebarRow: Identifiable, Equatable, Sendable {
    public enum Kind: Equatable, Sendable { case pinnedTab(drifted: Bool), folder(isOpen: Bool, childCount: Int), regularTab }
    public var id: SidebarItemID; public var kind: Kind
    public var depth: Int                   // 0 at the root, 1 inside a folder, 2 inside a sub-folder
    public var parentFolderID: UUID?
    public var title: String                // DisplayText.title
    public var containerColorHex: String?
    public var accessibilityLabel: String
}
public enum WorkspaceIcon: Equatable, Sendable { case emoji(String), symbol(String) }
// T9
public enum LivePlacement: Equatable, Sendable { case here, elsewhere(windowID: UUID) }
// T11
public enum AddressInput: Equatable, Sendable { case empty, url(String), search(String) }
public enum CommandBarMode: Equatable, Sendable { case newTab, currentTab }
public struct CommandTab: Equatable, Sendable { public var tab: Tab; public var section: SlotSection; public var workspaceID: UUID?; public var workspaceName: String? }
public struct CommandCandidates: Equatable, Sendable { public var tabs: [CommandTab]; public var archived: [ArchivedTab]; public var workspaces: [Workspace]; public var actions: [CommandAction] }
public enum CommandAction: Equatable, Sendable {
    case newWorkspace, newProfile, newWindow, toggleCompactMode, importFromArc, showArchive
    case closeTab, pinTab, unpinTab, resetPinnedTab, copyAddress
    case switchProfile(id: UUID, name: String), newTabInContainer(id: UUID, name: String)
}
public enum CommandResult: Equatable, Sendable { case open(url: String), search(query: String), tab(CommandTab), archived(ArchivedTab), workspace(Workspace), action(CommandAction) }
public enum CommandOutcome: Equatable, Sendable { case done, showArcImport, showArchive, newWindow, newWorkspace, newProfile, chooseSearchEngine, copy(String) }
// T16
public enum DropPosition: Sendable, Equatable { case before, after, into }
public enum SidebarDropTarget: Sendable, Equatable { case row(SidebarItemID, DropPosition), essentials(index: Int), pinnedEnd, regularTop, workspace(UUID) }
public enum SidebarMove: Sendable, Equatable {
    case tab(UUID, workspaceID: UUID?, section: SlotSection, folderID: UUID?, after: MoveAnchor?)
    case folder(UUID, parentID: UUID?, after: MoveAnchor?)
}
```

Every public struct gets a memberwise `public init`.

---

### Task 1: Store clean-up from plan 1's review

**Files:**
- Create: `Sources/StaveCore/OrganizationStore+Ordering.swift`
- Modify: `OrganizationStore.swift`, `OrganizationStore+Tabs.swift`, `OrganizationStore+Pinned.swift`, `OrganizationStore+Move.swift`, `OrganizationStore+Containers.swift`, `OrganizationStore+ArcImport.swift`
- Test: `Tests/StaveCoreTests/ProfileWorkspaceTests.swift`

**Interfaces:**
- Produces: no public API change. Internal helpers in `OrganizationStore+Ordering.swift` that every other file uses: `Child` (moved here), `renumber(_ children: [Child], in:)` (one implementation for folders and slots, replacing both existing ones), `uncrowdedIndex(siblings: () throws -> [Child], propose: ([Child]) throws -> Double, in:) throws -> Double` (the propose → crowded? → renumber → propose-again loop now duplicated in `regularIndex` and `moveIndex`), `essentialSlots(profileID:in:) -> [Slot]` (three copies today), `requireFolder(_ id: UUID, inWorkspace: UUID, in:) throws -> Folder` (throws `.notFound`; four copies today). `placementIndex` uses `tabsBySlot` instead of its own join.

- [ ] **Step 1: Write the failing test** `equalSortIndicesKeepInsertionOrder`: insert two workspaces of one profile with the same `sortIndex` and the same name straight through `database.writer`, then two profiles likewise; `workspaces(profileID:)` and `profiles()` return them in insertion order.
- [ ] **Step 2: Run** `swift test --package-path Packages/StaveCore --filter ProfileWorkspaceTests` → the new test fails or passes only by chance (SQLite gives no order guarantee); confirm the queries lack a `rowid` tie-break.
- [ ] **Step 3: Implement.** Every `order(...)` in the store ends with `Column("rowid")` (profiles: `sortIndex, name, rowid`; workspaces likewise). Move and merge the helpers listed above. In `deleteWorkspace`, a tab whose slot is missing throws `StoreError.notFound` instead of `continue`.
- [ ] **Step 4: Run** the whole suite `swift test --package-path Packages/StaveCore` → all pass, with no existing test edited.
- [ ] **Step 5: Commit** `refactor: share store ordering helpers and break ties on rowid`

### Task 2: Move anchors, folder moves and workspace edits

**Files:**
- Create: `Sources/StaveCore/OrganizationStore+Folders.swift` (move `createFolder` and `deleteFolder` here from `+Pinned`)
- Modify: `OrganizationStore+Move.swift`, `OrganizationStore.swift`
- Test: `Tests/StaveCoreTests/MoveTests.swift` (existing calls become `after: .tab(id)`), create `Tests/StaveCoreTests/FolderAndWorkspaceEditTests.swift`

**Interfaces:**
- Consumes: T1 helpers.
- Produces:
  - `moveTab(_ id: UUID, toWorkspace: UUID?, section: SlotSection, folderID: UUID?, after anchor: MoveAnchor?) throws` (replaces `after previousTabID: UUID?`). A `.folder` anchor is valid only in `.pinned`; an anchor not in the target sibling list throws `.notFound`.
  - `moveFolder(_ id: UUID, toParent parentFolderID: UUID?, after anchor: MoveAnchor?) throws`: same workspace only (`.notFound` otherwise). Throws `.folderTooDeep` when the target parent is itself nested, when the folder has sub-folders and the parent is non-nil, or when `parentFolderID == id`.
  - `setFolderOpen(_ id: UUID, _ isOpen: Bool) throws`, `renameFolder(_ id: UUID, to title: String) throws`
  - `updateWorkspace(_ id: UUID, name: String, icon: String, colorHex: String) throws`
  - `moveWorkspace(_ id: UUID, after previousID: UUID?) throws` (nil = first; another profile's workspace → `.crossProfileMove`)

- [ ] **Step 1: Write failing tests**
  - `tabAfterFolderAnchor`: pinned root [F, T1]; move T2 (regular) to pinned root after `.folder(F)` → root order F, T2, T1.
  - `folderAnchorRefusedOutsidePinned`: `moveTab(..., section: .regular, ..., after: .folder(F))` → `.notFound`, nothing changed.
  - `moveFolderReorders`: root [A, B, C] folders → move C after `.folder(A)` → A, C, B.
  - `moveFolderIntoFolder`: top-level folder B (no sub-folders) into A → B's `parentFolderID == A`, its tabs still inside B.
  - `moveFolderTooDeep`: A holds sub-folder A1; moving B into A1 → `.folderTooDeep`; moving A (has a sub-folder) into B → `.folderTooDeep`; moving A into A → `.folderTooDeep`.
  - `moveFolderOtherWorkspaceRefused` → `.notFound`.
  - `folderOpenAndRename`: `setFolderOpen(f, false)` then `pinnedItems` shows `isOpen == false`; rename shows the new title; both bump `modifiedAt`.
  - `updateWorkspaceAppearance`: name, icon `"💼"`, colour `"#3478F6"` read back.
  - `moveWorkspaceReorders`: A, B, C → move C after nil → C, A, B; another profile's workspace → `.crossProfileMove`.
- [ ] **Step 2: Run** `--filter MoveTests` and `--filter FolderAndWorkspaceEditTests` → FAIL.
- [ ] **Step 3: Implement** with `uncrowdedIndex`; one transaction per call; each refusal changes nothing.
- [ ] **Step 4: Run** the whole suite → PASS.
- [ ] **Step 5: Commit** `feat: move folders, anchor moves on folders, edit workspaces`

### Task 3: Settings in the store and search engines

**Files:**
- Create: `Sources/StaveCore/Settings/SettingKey.swift`, `Settings/SearchEngine.swift`, `OrganizationStore+Settings.swift`, `Tests/StaveCoreTests/SettingsTests.swift`
- Modify: `Database/StaveDatabase.swift` (migration `"v2"`, `schemaVersion = 2`), `Tests/StaveCoreTests/PathsAndDatabaseTests.swift` (table list)

**Interfaces:**
- Produces: `SettingKey`, `SettingKeys`, `SearchEngine` (shared types); `setting<V>(_ key: SettingKey<V>) throws -> V` (missing or undecodable row → `defaultValue`); `setSetting<V>(_ key: SettingKey<V>, _ value: V) throws`; `SearchEngine.displayName: String` ("Google", "DuckDuckGo", "Kagi", "Bing", "Ecosia"); `SearchEngine.searchURL(for query: String) -> String`.
- Migration `"v2"`: table `setting(key TEXT PRIMARY KEY, value TEXT NOT NULL, modifiedAt DATETIME NOT NULL)`; the value is the JSON encoding of `V`.

- [ ] **Step 1: Write failing tests**
  - `defaultsWhenUnset`: each `SettingKeys` value reads its default on a fresh store.
  - `roundTripAndReopen`: set `compactMode` true, `searchEngine` `.kagi`, `newTabEdge` `.bottom`; reopen the file → same values.
  - `searchEngineCanBeCleared`: set `.kagi`, then `nil` → reads `nil`.
  - `undecodableFallsBackToDefault`: write `"not json"` into the row for `sidebarWidth` directly → reads `260`.
  - `searchURLs`: `.google` for `"a&b c"` → `"https://www.google.com/search?q=a%26b%20c"`; `.duckDuckGo` → `"https://duckduckgo.com/?q=…"`; `.kagi` → `"https://kagi.com/search?q=…"`; `.bing` → `"https://www.bing.com/search?q=…"`; `.ecosia` → `"https://www.ecosia.org/search?q=…"`; `"日本 #1"` encodes `#` as `%23`.
  - `PathsAndDatabaseTests.openCreatesSchema` now also expects `setting`.
- [ ] **Step 2: Run** `--filter SettingsTests` → FAIL.
- [ ] **Step 3: Implement.** Query encoding: `.urlQueryAllowed` minus `&+=?#/`.
- [ ] **Step 4: Run** the whole suite → PASS (the newer-schema test still passes with v2).
- [ ] **Step 5: Commit** `feat: settings stored with the data, and search engines`

### Task 4: Window session, frame clamping, launch maintenance and sample data

**Files:**
- Create: `Sources/StaveCore/Session/WindowFrameClamp.swift`, `Session/WindowSession.swift`, `Debug/SampleOrganization.swift`, `Tests/StaveCoreTests/WindowSessionTests.swift`, `Tests/StaveCoreTests/SampleOrganizationTests.swift`
- Modify: `OrganizationStore+Tabs.swift` (`launchMaintenance`)

**Interfaces:**
- Produces:
  - `WindowFrameClamp.clamp(_ frame: CGRect, visibleFrames: [CGRect]) -> CGRect` (empty `visibleFrames` → `frame` unchanged).
  - `@MainActor public final class WindowSession { init(store: OrganizationStore); func update(_ state: WindowState); func windowClosed(_ id: UUID, isLast: Bool); var states: [WindowState] { get }; func save() throws }`. States keep the order windows first appeared in; `save()` assigns `sortIndex` 0, 1, 2… and calls `saveWindows`. `windowClosed(isLast: false)` removes the state; `isLast: true` keeps it.
  - `launchMaintenance() throws` = `trimArchive(olderThan: 30)`.
  - `SampleOrganization.seed(into store: OrganizationStore) throws -> Bool`: when the store has no tabs, writes the sample and returns true; otherwise writes nothing and returns false. The sample, in the default profile: workspaces "Home" (existing) and "Work" (icon `"💼"`, `#3478F6`); 3 Essentials; in Home a folder "Reading" holding a sub-folder "Later" (2 pinned tabs) and 2 pinned tabs, one of them drifted; 2 root pinned tabs; 4 regular tabs, one in a named container "Work Google" (`#34C759`); 2 archived tabs; in Work 1 pinned and 2 regular tabs. All URLs on `example.com`/`.org`/`.net`, invented titles, one title in Japanese and one 200 characters long.

- [ ] **Step 1: Write failing tests**
  - `frameInsideStaysPut`, `frameHalfOffIsPulledIn` (moved onto the screen it overlaps most, same size), `frameLargerThanScreenShrinks`, `frameOnMissingScreenIsCentred` (Review Focus 5: frame at x = 5000 with one screen `0,0,1440,900` → same size if it fits, centred on that screen).
  - `sessionKeepsOrderAndSaves`: update A, B, A again → `states` A, B; `save()` → `restoredWindows()` gives A, B with `sortIndex` 0, 1.
  - `closingNonLastRemoves`, `closingLastKeeps`.
  - `launchMaintenanceTrims`: rows closed 31 and 29 days ago → one left.
  - `seedFillsEmptyStore`: returns true; Home has the folder tree above, one drifted pinned tab, 4 regular tabs; `archivedTabs` has 2; every URL's host ends in `example.com`, `example.org` or `example.net`.
  - `seedLeavesUsedStoreAlone`: a store with one tab → returns false and the tab count is unchanged.
- [ ] **Step 2: Run** `--filter WindowSessionTests` and `--filter SampleOrganizationTests` → FAIL.
- [ ] **Step 3: Implement.**
- [ ] **Step 4: Run** → PASS.
- [ ] **Step 5: Commit** `feat: window session, frame clamping, launch trim and sample data`

### Task 5: Import record and reading Arc's file from disk

**Files:**
- Create: `Sources/StaveCore/OrganizationStore+Imports.swift`
- Modify: `Database/StaveDatabase.swift` (migration `"v3"`, `schemaVersion = 3`), `OrganizationStore+ArcImport.swift`, `ArcImport/ArcImporter.swift`, `ArcImport/ArcSidebar.swift` (`ArcImportError.unreadable`)
- Test: `Tests/StaveCoreTests/ArcImportStoreTests.swift`, `PathsAndDatabaseTests.swift` (table list)

**Interfaces:**
- Produces:
  - Migration `"v3"`: table `importRecord(id BLOB PRIMARY KEY, source TEXT NOT NULL, importedAt DATETIME NOT NULL, modifiedAt DATETIME NOT NULL)`.
  - `importArc(_:)` inserts a record (`source: .arc`, `importedAt: now()`) in its transaction.
  - `lastImport(source: ImportSource) throws -> Date?` (newest).
  - `ArcImporter.run(sidebarFile: URL, localStateFile: URL?, options: ArcImportOptions, into store: OrganizationStore) throws -> ArcImportReport`: reads the size from `URLResourceValues.fileSize` first and throws `.fileTooLarge` above `ArcSidebarParser.maximumFileSize` without reading; a missing file, a directory or a read failure throws `.unreadable`; an unreadable Local State is treated as absent.
  - `ArcImporter.localStateFile(nextTo sidebarFile: URL) -> URL` = sidebar's folder + `User Data/Local State`.
  - `ArcImporter.isAvailable(home: URL) -> Bool` (a regular file exists at `sidebarFile(home:)`).

- [ ] **Step 1: Write failing tests**
  - `importWritesRecord`: `lastImport(source: .arc)` is nil, then equals the test clock's date after `importArc`.
  - `failedImportWritesNoRecord`: the plan from the existing `failedImportWritesNothing` test → still nil.
  - `oversizedFileRefusedBeforeReading` (Review Focus 4): a sparse file of `maximumFileSize + 1` bytes (`FileHandle.truncate(atOffset:)`) → `.fileTooLarge`.
  - `directoryIsUnreadable`, `missingFileIsUnreadable` → `.unreadable`.
  - `localStateBesideAPickedFile`: a temp folder with `StorableSidebar.json` (the edge-cases fixture) and `User Data/Local State` (the local-state fixture) → the custom profile gets the name the existing Local State test expects; without the Local State file it gets the folder name.
  - `PathsAndDatabaseTests.openCreatesSchema` expects `importRecord`.
- [ ] **Step 2: Run** `--filter ArcImportStoreTests` → FAIL.
- [ ] **Step 3: Implement.**
- [ ] **Step 4: Run** the whole suite → PASS.
- [ ] **Step 5: Commit** `feat: record Arc imports and read Arc's file with a size check first`

### Task 6: Unambiguous report places

**Files:**
- Modify: `ArcImport/ArcImportReport.swift`, `ArcImport/ArcImportPlanner.swift`, `ArcImport/ArcSidebarParser.swift`
- Test: `Tests/StaveCoreTests/ArcImportPlannerTests.swift`, `ArcSidebarParserTests.swift` (existing expectations move to the new shape)

**Interfaces:**
- Produces: `ArcImportReport.Place`. These cases change from `space: String?` to `place: Place`: `Flattened.splitView(place:tabCount:)`, `Skipped.nonWebURL(place:title:scheme:)`, `Skipped.unsupportedItem(place:kind:title:)`. Cases that still carry `space: String` (`folderTooDeep`, `unpinnedFolder`, `unpinnedTabs`, `unrecognizedProfile`, `spaceContentsMissing`) carry the same label as `Place.space`. The label is the workspace name, plus " (n)" when two or more spaces in the import share that name (n = 1-based position among them, in sidebar order). Favorites use `.favorites(profile:)`: nil for the default profile (and for unrecognised markers merged into it), else the profile's planned name. `ArcSidebar.unrecognizedFavoritesContainers` counts only containers with at least one child item.

- [ ] **Step 1: Write failing tests**
  - `duplicateSpaceNamesAreNumbered`: two spaces titled "Work", each with a `file:` pinned tab → skipped places `.space("Work (1)")` and `.space("Work (2)")`; both planned workspaces are still named "Work".
  - `uniqueNamesStayPlain`: "Work" and "Home" → `.space("Work")`, `.space("Home")`.
  - `favoritesEntriesNameTheirProfile`: a `file:` Favorite in a custom profile named "Side" via Local State → `.favorites(profile: "Side")`; in the default profile → `.favorites(profile: nil)`.
  - `emptyUnrecognizedFavoritesNotReported`: an empty `topApps` container with an unknown marker → no `.unrecognizedFavoritesProfile`; with one tab → exactly one.
- [ ] **Step 2: Run** `--filter ArcImportPlannerTests` and `--filter ArcSidebarParserTests` → FAIL.
- [ ] **Step 3: Implement** labels once per plan, before walking the spaces.
- [ ] **Step 4: Run** the whole suite → PASS.
- [ ] **Step 5: Commit** `fix: name report places unambiguously and skip empty unknown Favorites`

### Task 7: The import report in plain words

**Files:**
- Create: `Sources/StaveCore/ArcImport/ArcImportSummary.swift`, `Tests/StaveCoreTests/ArcImportSummaryTests.swift`

**Interfaces:**
- Produces:
  - `public struct ArcImportSummary: Equatable, Sendable { headline: String; imported: [String]; changed: [String]; skipped: [String]; init(report: ArcImportReport) }`
  - `public enum ArcImportCopy { static let loginsNotice: String; static let keepACopy: String; static func repeatWarning(previous: Date, locale: Locale = .current, timeZone: TimeZone = .current) -> String; static func errorMessage(for error: Error) -> String }`
- Exact copy (`‹›` marks a value; curly quotes as shown):
  - Headline: "Imported from Arc", or "Nothing was imported" when every count is 0.
  - Imported, one line per non-zero count, in this order: "‹n› new profile(s)", "‹n› workspace(s)", "‹n› folder(s)", "‹n› pinned tab(s)", "‹n› Essential(s)", "‹n› tab(s)".
  - Place text: `.space(x)` → "in ‹x›"; `.favorites(nil)` → "in your Arc Favorites"; `.favorites(p)` → "in the Favorites of Arc's “‹p›” profile".
  - Changed: folderTooDeep → "“‹folder›” in ‹space› was inside another folder. Stave folders go one level deep, so its tabs moved up a level." splitView → "A split view with ‹n› tabs ‹place› became ‹n› separate tabs." favoritesFolder → "The folder “‹folder›” in your Arc Favorites became separate Essentials." unpinnedFolder → "The unpinned folder “‹folder›” in ‹space› became separate tabs."
  - Skipped: nonWebURL → "“‹title›” ‹place› isn't a web page (‹scheme›:), so it wasn't imported." (scheme "" → "(no address)" in place of "(‹scheme›:)"; here and in unsupportedItem, an empty or missing title gives "An item" in place of "“‹title›”"). unsupportedItem → "“‹title›” ‹place› is an Arc ‹Easel|item of kind “k”›, which Stave doesn't have." (`easel` → "Easel"; `welcomeToArc` → "welcome page"). unpinnedTabs → "‹n› unpinned tab(s) in ‹space› weren't imported. Turn on “Also import unpinned tabs” to bring them." unrecognizedProfile → "‹space› belonged to an Arc profile Stave couldn't identify, so it went into your first profile." duplicateItem → "‹n› item(s) appeared twice in Arc's file and were imported once." unrecognizedFavoritesProfile → "Some Arc Favorites belonged to a profile Stave couldn't identify, so they became Essentials in your first profile." spaceContentsMissing → "‹space› was imported, but Arc's file didn't say what was in it."
  - `loginsNotice`: "Logins, passwords and cookies can't be imported from Arc, so you'll sign in to sites again. If your passwords are in iCloud Keychain, the Passwords app can copy them for you. Passkeys will work in Stave once Apple approves it."
  - `keepACopy`: "Arc may stop opening on December 22, 2026. To import later, keep a copy of Arc's sidebar file: ~/Library/Application Support/Arc/StorableSidebar.json."
  - `repeatWarning`: "You imported from Arc on ‹long date›. Importing again adds a second copy of everything it brings in. Nothing you have now is changed."
  - `errorMessage`: `.fileTooLarge` "This file is over 64 MB, far larger than any Arc sidebar file, so Stave didn't open it."; `.notJSON` "This isn't an Arc sidebar file. Stave couldn't read it as JSON."; `.noSidebar` "This file doesn't contain an Arc sidebar."; `.tooDeep` "This file's folders are nested deeper than Arc allows, so Stave didn't import it."; `.unreadable` "Stave couldn't read this file."; any other error "Stave couldn't save the import. Nothing was changed."

- [ ] **Step 1: Write failing tests**, one per line above with its exact string; plus `pluralsAndOrder` (counts 1, 2, 0, 6, 1, 0 → "1 new profile", "2 workspaces", "6 pinned tabs", "1 Essential"), `nothingImportedHeadline`, `repeatWarningDate` (`en_US`, UTC, 2026-10-29 → "October 29, 2026").
- [ ] **Step 2: Run** `--filter ArcImportSummaryTests` → FAIL.
- [ ] **Step 3: Implement.**
- [ ] **Step 4: Run** → PASS.
- [ ] **Step 5: Commit** `feat: describe an Arc import in plain words`

### Task 8: Sidebar rows, labels and display text

**Files:**
- Create: `Sources/StaveCore/Sidebar/DisplayText.swift`, `Sidebar/SidebarRows.swift`, `Tests/StaveCoreTests/SidebarRowsTests.swift`
- Modify: `OrganizationStore+Tabs.swift` (`displayTitle` delegates to `DisplayText.title`)

**Interfaces:**
- Produces:
  - `DisplayText.title(for tab: Tab) -> String` (today's `displayTitle` rule), `DisplayText.address(for url: String) -> String` (host without a leading `www.`; the whole string when there is no host), `DisplayText.monogram(for tab: Tab) -> String` (first character of the host without `www.`, else of the title, uppercased; `"?"` when both are empty).
  - `WorkspaceIcon.init(stored: String)`: any non-ASCII scalar → `.emoji(stored)`; non-empty ASCII → `.symbol(stored)`; empty → `.symbol("square.grid.2x2")`. The view falls back to `square.grid.2x2` when `NSImage(systemSymbolName:)` returns nil.
  - `SidebarRows.build(_ snapshot: SidebarSnapshot, containers: [Container]) -> [SidebarRow]`: pinned tree rows (a folder, then its children when open, sub-folders likewise), then regular rows. Essentials are not rows (the grid shows them).
  - `SidebarLabels`: `essential(title:)` → "‹title›, Essential"; pinned tab → "‹title›, pinned tab", drifted → "‹title›, pinned tab, away from its pinned page"; folder → "‹title›, folder, open|closed, ‹n› item(s)" (direct children); regular → "‹title›, tab", with a container → "‹title›, tab, in ‹container›"; `workspace(name:position:count:isCurrent:)` → "‹name›, workspace ‹p› of ‹c›" plus ", current".

- [ ] **Step 1: Write failing tests**
  - `rowsInVisualOrder`: from `SampleOrganization`'s Home → Reading (depth 0), Later (1), Later's tabs (2), Reading's tabs (1), root pinned (0), then regular (0); `parentFolderID` set on children.
  - `closedFolderHidesChildren`: Reading closed → no Later and no Reading children; Reading's `kind` is `.folder(isOpen: false, childCount: 3)`.
  - `labelsAreExact`: every label form above, including drifted and container.
  - `addressText`: `"https://www.example.com/a"` → `"example.com"`; `"https://sub.example.org"` → `"sub.example.org"`; `"about:blank"` → `"about:blank"`; `""` → `""`.
  - `monogram`: `"https://www.example.com"` → `"E"`; empty URL with title "zeta" → `"Z"`; both empty → `"?"`.
  - `workspaceIcon`: `"💼"` → emoji; `"house"` → symbol; `""` → `square.grid.2x2`.
- [ ] **Step 2: Run** `--filter SidebarRowsTests` → FAIL.
- [ ] **Step 3: Implement.**
- [ ] **Step 4: Run** the whole suite → PASS.
- [ ] **Step 5: Commit** `feat: sidebar rows, labels and display text`

### Task 9: One live page, one place

**Files:**
- Create: `Sources/StaveCore/Window/LivePageRegistry.swift`, `Tests/StaveCoreTests/LivePageRegistryTests.swift`

**Interfaces:**
- Produces: `@MainActor @Observable public final class LivePageRegistry { init(); func show(_ tabID: UUID, in windowID: UUID) -> LivePlacement; func bringHere(_ tabID: UUID, to windowID: UUID); func windowClosed(_ windowID: UUID); func tabRemoved(_ tabID: UUID); func placement(of tabID: UUID, in windowID: UUID) -> LivePlacement }`. Each window shows at most one tab. `show` first releases the window's previous tab, then claims the new one if nobody owns it; it never takes a page from another window (focus never moves a page). `bringHere` transfers ownership.

- [ ] **Step 1: Write failing tests**
  - `firstWindowGetsThePage`: A shows T → `.here`; B shows T → `.elsewhere(A)`.
  - `bringHereMovesIt`: then `bringHere(T, to: B)` → B `.here`, A `.elsewhere(B)`.
  - `leavingAPageFreesIt`: A shows T, B shows T (elsewhere), A shows U → B's `placement(of: T)` → `.here` after B calls `show(T)` again.
  - `closingWindowReleases`, `removedTabReleases`.
- [ ] **Step 2: Run** `--filter LivePageRegistryTests` → FAIL.
- [ ] **Step 3: Implement.**
- [ ] **Step 4: Run** → PASS.
- [ ] **Step 5: Commit** `feat: track which window shows each live page`

### Task 10: The window model

**Files:**
- Create: `Sources/StaveCore/Window/StoreRevision.swift`, `Window/StoreErrorText.swift`, `Window/BrowserWindowModel.swift`, `Tests/StaveCoreTests/BrowserWindowModelTests.swift`

**Interfaces:**
- Consumes: the store (T1–T5), `SidebarRows` (T8), `LivePageRegistry` (T9).
- Produces:
  - `@MainActor @Observable public final class StoreRevision { init(); private(set) var value: Int; func bump() }`
  - `StoreErrorText.message(for error: Error) -> String`: `.lastWorkspace` "A profile needs at least one workspace." `.folderTooDeep` "Folders go only one level deep." `.crossProfileMove` "That belongs to another profile. Move it by opening it there." `.notFound` "That item no longer exists." `.notPinned` "Only pinned tabs and Essentials have a pinned page." Anything else: "Something went wrong saving that change."
  - `@MainActor @Observable public final class BrowserWindowModel`:
    - `init(store: OrganizationStore, revision: StoreRevision, livePages: LivePageRegistry, state: WindowState) throws`
    - read-only state: `windowID: UUID` (= `state.id`), `snapshot: SidebarSnapshot`, `rows: [SidebarRow]`, `workspaces: [Workspace]`, `profiles: [Profile]`, `containers: [Container]`, `selectedTabID: UUID?`, `selectedTab: Tab?`, `placement: LivePlacement?`, `lastError: String?`, `lastSwitchDirection: Int` (−1, 0, +1, for the slide animation), `windowState: WindowState`; settable `frame: String`
    - `reload()`: re-reads; a missing workspace falls back to the profile's first (a missing profile to the first profile); a selected tab no longer in the snapshot clears the selection and tells the registry.
    - `select(_ tabID: UUID?)` (marks the tab active, claims it in the registry), `bringSelectedHere()`
    - `switchWorkspace(to id: UUID)`, `switchWorkspace(number: Int)` (1-based), `switchWorkspace(offset: Int)` (no wrap), `switchProfile(to id: UUID)` (first workspace, no selection); each clears the selection unless the selected tab is an Essential
    - `openTab(url: String, origin: NewTabOrigin = .commandBar, containerID: UUID? = nil)` (edge from `SettingKeys.newTabEdge`; selects it), `navigateSelected(to url: String)`
    - `close(_ tabID: UUID)` (selection rule in decision 13), `pin(_:folderID:)`, `unpin(_:)`, `makeEssential(_:)`, `removeEssential(_:)`, `removePinned(_:)`, `resetPinned(_:)`
    - `createFolder(title:parentID:)`, `renameFolder(_:to:)`, `setFolderOpen(_:_:)`, `deleteFolder(_:)`
    - `createWorkspace(name:icon:colorHex:)` (switches to it), `updateWorkspace(_:name:icon:colorHex:)`, `deleteWorkspace(_:)` (switches to the neighbour first if it is current), `moveWorkspace(_:after:)`, `createProfile(name:)` (switches to it)
    - `archivedTabs() -> [ArchivedTab]`, `restoreArchived(_ id: UUID)` (into this workspace, selected)
    - `windowWillClose()`
  - Every write goes through one private `perform(_:)`: on success `revision.bump()` then `reload()`; on any error `lastError = StoreErrorText.message(for:)` then `reload()`. No method throws after `init`.

- [ ] **Step 1: Write failing tests** (two models on one store share a revision and registry, as two windows do)
  - `startsOnSavedWorkspace`, `windowStateFollowsChanges` (profile, workspace, selection, frame).
  - `selectMarksActive`: `lastActiveAt` advances on the test clock.
  - `switchByNumberAndOffset`: three workspaces; number 2 → second; number 9 → unchanged; offset +1 from the last → unchanged; `lastSwitchDirection` is +1 after moving right.
  - `switchProfileGoesToFirstWorkspace`.
  - `openTabHonoursEdgeSetting`: `.bottom` → last regular tab and selected.
  - `closeSelectsNeighbour`: A, B, C; close B (selected) → C; close C → A; close A → nil.
  - `workspaceDeletedElsewhereFallsBack` (Review Focus 2): window 1 on W2, window 2 deletes W2 → window 1 `reload()` → first workspace, `selectedTabID == nil`.
  - `selectedTabClosedElsewhereClearsSelection` (Review Focus 3): window 1 selects T, window 2 closes T → window 1 `reload()` → nil, and `livePages.placement(of: T, in: window2)` is `.here`.
  - `bringHereSwapsPlacement`: both select T → window 2 `.elsewhere(window1)`; `bringSelectedHere()` → `.here`.
  - `errorsBecomeMessages`: creating a folder three levels deep → no throw, `lastError == "Folders go only one level deep."`.
  - `writesBumpRevision`.
  - `navigateSelectedDrifts`: on a pinned tab → `url` stored, `title == ""`, row kind `.pinnedTab(drifted: true)`.
- [ ] **Step 2: Run** `--filter BrowserWindowModelTests` → FAIL.
- [ ] **Step 3: Implement.**
- [ ] **Step 4: Run** the whole suite → PASS.
- [ ] **Step 5: Commit** `feat: window model over the store`

### Task 11: Command bar logic

**Files:**
- Create: `Sources/StaveCore/CommandBar/AddressInput.swift`, `CommandBar/CommandBarSearch.swift`, `CommandBar/CommandBarModel.swift`, `OrganizationStore+CommandBar.swift`, `Tests/StaveCoreTests/AddressInputTests.swift`, `Tests/StaveCoreTests/CommandBarTests.swift`
- Modify: `Window/BrowserWindowModel.swift`

**Interfaces:**
- Produces:
  - `AddressInput.classify(_ text: String) -> AddressInput`. Trim whitespace; empty → `.empty`; an inner space → `.search`; `http`/`https` (any case) with a non-empty host → `.url(text)`; any other scheme → `.search`; `localhost` or an IPv4 address, optional port and path → `.url("http://" + text)`; host-like text (labels of letters, digits and hyphens, at least one dot, last label at least two letters, optional port and path, no `@`) → `.url("https://" + text)`; else `.search(text)`.
  - `commandCandidates(profileID: UUID, archiveLimit: Int = 200) throws -> CommandCandidates`: every tab of the profile (Essentials, pinned, regular) with its workspace name, most recently active first; archived newest first up to the limit; workspaces in order; `actions` empty.
  - `CommandAction.title`: "New Workspace", "New Profile", "New Window", "Toggle Compact Mode", "Import from Arc…", "Show Archive", "Close Tab", "Pin Tab", "Unpin Tab", "Back to Pinned Page", "Copy Address", "Switch to ‹name›", "New Tab in ‹name›".
  - `CommandBarSearch.results(query: String, candidates: CommandCandidates, limit: Int = 12) -> [CommandResult]`: `.empty` query → the first `limit` tabs; otherwise the typed row (`.open` or `.search`) first, then matches by the ranking in decision 23, compared case- and diacritic-insensitively, ties in candidate order.
  - `@MainActor @Observable public final class CommandBarModel { init(mode: CommandBarMode, candidates: CommandCandidates, currentURL: String?); var query: String; private(set) var results: [CommandResult]; private(set) var selectedIndex: Int; func moveSelection(by delta: Int); var selectedResult: CommandResult? }`. `.currentTab` starts with `query = currentURL ?? ""`; the selection is clamped and resets to 0 when the query changes.
  - `BrowserWindowModel.commandCandidates() -> CommandCandidates` (adds actions: pin/unpin/reset/close/copy only when they apply to the selected tab; `switchProfile` for the other profiles; `newTabInContainer` per container) and `perform(_ result: CommandResult, mode: CommandBarMode) -> CommandOutcome`: `.open` opens a new tab (`.newTab`) or navigates the selected tab (`.currentTab`, or a new tab when none is selected); `.search` uses the setting's engine, or returns `.chooseSearchEngine` when none is set; `.tab` switches workspace if needed and selects; `.archived` restores; `.workspace` switches; `.toggleCompactMode` flips the setting and returns `.done`; `.copyAddress` returns `.copy(url)`; the actions with UI return their outcome.

- [ ] **Step 1: Write failing tests**
  - `AddressInputTests`: `"example.com"` → `.url("https://example.com")`; `"Example.com/a?b=1"` → `.url("https://Example.com/a?b=1")`; `"HTTP://example.org"` → `.url` unchanged; `"localhost:3000/x"` → `.url("http://localhost:3000/x")`; `"192.168.1.10"` → `.url("http://192.168.1.10")`; `"foo bar"`, `"a.b"`, `"1.5"`, `"user@example.com"` → `.search`; `"   "` → `.empty`; `nonWebSchemesBecomeSearches` (Review Focus 1): `"javascript:alert(1)"`, `"JavaScript:void(0)"`, `"file:///etc/hosts"`, `"data:text/html,x"`, `"about:blank"` → `.search`.
  - `CommandBarTests`:
    - `candidatesCoverTheProfile`: on the sample, the tabs include Essentials, pinned and regular from both workspaces, most recent first.
    - `typedRowComesFirst`: `"exa"` → first `.search("exa")`; `"example.com"` → first `.open`.
    - `rankingOrder`: titles "Docs", "My docs", "Readocs" with query "doc" → Docs, My docs, Readocs.
    - `diacriticsIgnored`: "Café" matches "cafe".
    - `emptyQueryListsRecentTabs`, `limitIsRespected`.
    - `modelClampsSelection`, `currentTabModePrefills`.
    - `performOpenNewTab`, `performOpenCurrentTab`, `performSearchWithoutEngine` → `.chooseSearchEngine`, `performSearchWithEngine` (opens the Kagi URL), `performTabInOtherWorkspace` (switches and selects), `performArchived` (restored and selected), `performToggleCompact` (setting flips).
    - `actionsFollowSelection`: no selection → no Close/Pin; regular selected → Pin, Close, Copy; drifted pinned → Back to Pinned Page.
- [ ] **Step 2: Run** `--filter AddressInputTests` and `--filter CommandBarTests` → FAIL.
- [ ] **Step 3: Implement.**
- [ ] **Step 4: Run** the whole suite → PASS.
- [ ] **Step 5: Commit** `feat: command bar input, ranking and actions`

### Task 12: App shell on the window model

**Files:**
- Create: `Stave/App/AppDelegate.swift` (moved out of `StaveApp.swift`), `App/DebugLaunchOptions.swift`, `App/BrowserWindowController.swift`, `Views/BrowserWindowView.swift`, `Views/Content/TabPlaceholderView.swift`, `Views/Sidebar/SidebarView.swift`, `scripts/capture-window.swift`, `scripts/ax-dump.sh`
- Modify: `Stave/App/StaveApp.swift`, `App/AppEnvironment.swift`
- Delete: `Stave/Views/FoundationSidebarView.swift`, the Debug "Add sample tab" menu, `addSampleTab()` and `-StaveAddSampleTab`

**Interfaces:**
- Consumes: T3, T4, T8–T10.
- Produces:
  - `DebugLaunchOptions.current` (Debug only; in Release every field is nil/false): `dataDirectory: URL?` (`-StaveDataDirectory`), `arcHome: URL?` (`-StaveArcHome`), `seedSample: Bool` (`-StaveSeedSample`).
  - `AppEnvironment` gains `revision: StoreRevision`, `livePages: LivePageRegistry`, `session: WindowSession`, `arcHome: URL` (Debug override or the real home). Its init uses the Debug data directory when given, then runs `launchMaintenance()`, then `SampleOrganization.seed` when asked.
  - `BrowserWindowController`: owns one `NSWindow` (full-size content view, transparent hidden title bar, default 1200 × 800, min 800 × 500, restored frame through `WindowFrameClamp` with `NSScreen.screens.map(\.visibleFrame)`) and its `BrowserWindowModel`; reports state to `WindowSession` 0.5 s after the last change (model change, move, resize); calls `windowClosed(_:isLast:)` and `model.windowWillClose()` on close.
  - `BrowserWindowView`: an `HSplitView`-style layout of `SidebarView` (width from `SettingKeys.sidebarWidth`, 200–400) and `TabPlaceholderView`; reloads the model when `revision.value` changes. Shows `model.lastError` as a dismissible banner at the bottom of the sidebar.
  - `SidebarView` in this task: a `List(selection:)` over `model.rows` (pinned and regular sections, folders as plain rows), titles and labels from `SidebarRow`, workspace tint. T13 adds the rest.
  - `TabPlaceholderView`: decision 10, plus the "Showing in another window" state with a "Bring It Here" button calling `bringSelectedHere()`.
  - `scripts/capture-window.swift <app name> <output.png>`: finds the frontmost on-screen, layer-0 window owned by the app (`CGWindowListCopyWindowInfo`) and runs `screencapture -x -o -l<id>`; exits 1 with a message when there is none. `scripts/ax-dump.sh <process name>`: prints role and description for every UI element of the front window through System Events.

- [ ] **Step 1: Implement** the files above. Menus in this task: ⌘N New Window (decision 14), ⌘W Close Tab (`close(selected)`), ⇧⌘W Close Window; exactly one item owns each shortcut.
- [ ] **Step 2: Run** `swift test --package-path Packages/StaveCore` → PASS, and the by-hand check step 1 → build succeeds; `xcodebuild … -configuration Release` also succeeds (no Debug-only symbol leaks).
- [ ] **Step 3: By-hand check** (seeded). Confirm in the screenshot: sidebar left with Home's tint, the traffic lights over the sidebar, pinned rows (Reading, Later and their tabs indented) and regular rows, the placeholder card for a selected tab. Press ↓ twice through System Events → the placeholder follows. ⌘N → second window; select the same tab in both → the second shows "Showing in another window" (screenshot it). Quit and relaunch with the same data folder (no `-StaveSeedSample`) → both windows come back with their frames and selection. `ls <folder>/data` shows `stave.sqlite`; `~/Library/Application Support/Stave-debug` was not modified (compare its modification time before and after).
- [ ] **Step 4: Commit** `feat: browser window on the window model, with debug launch options` (stage the named app files, scripts, `project.pbxproj`, and the deletion).

### Task 13: The full sidebar

**Files:**
- Create: `Stave/Views/Sidebar/SidebarRowView.swift`, `EssentialsGrid.swift`, `AddressField.swift`, `ArchivePopover.swift`
- Modify: `Views/Sidebar/SidebarView.swift`

**Interfaces:**
- Consumes: `BrowserWindowModel` (T10), `SidebarRows`/`SidebarLabels`/`DisplayText` (T8).
- Produces the views for decisions 3, 5, 6, 7 and 10:
  - `AddressField`: shows `DisplayText.address` of the selected tab; it is a button that opens the command bar in `.currentTab` mode. Until T15 the button calls a no-op closure passed in by `BrowserWindowView`.
  - `EssentialsGrid`: tiles select the Essential; context menu "Back to Pinned Page" (when drifted), "Remove from Essentials".
  - Folder rows: disclosure chevron calls `setFolderOpen`; ← / → on a selected folder close / open it.
  - Pinned rows show a small "back to pinned page" button when drifted (label "Back to pinned page").
  - Regular rows show the container colour dot.
  - Context menus. Tab: Pin / Unpin, Add to Essentials, Back to Pinned Page, Close Tab, Remove (pinned only). Folder: Rename, New Folder Inside (top level only), Delete Folder (keeps its tabs). Pinned header: New Folder.
  - Each row carries VoiceOver actions matching its context menu (`accessibilityAction(named:)`).
  - A "New Tab" row above the regular tabs (opens the command bar, `.newTab`).
  - `ArchivePopover` from the archive button: a search field filtering by title or URL (`localizedStandardContains`), newest first, Return or a Restore button restores the row; empty state "Nothing in the archive".
  - ⌫ on a selected tab row closes it.

- [ ] **Step 1: Implement.**
- [ ] **Step 2: Build** (by-hand check step 1) → succeeds.
- [ ] **Step 3: By-hand check** (seeded). Screenshot and confirm: address field showing a host, three Essentials tiles with monograms, folders with chevrons, the drifted pinned tab's button, the container dot, the New Tab row, the archive button. Through System Events select a regular tab and press ⌫ → it disappears; open the archive popover (screenshot) → the tab is listed first; restore it → back at the top. Close a folder with ← → its children hide; relaunch → still closed. `scripts/ax-dump.sh Stave` lists the `SidebarLabels` strings for the Essentials and rows. Nico checks: context menus by right-click.
- [ ] **Step 4: Commit** `feat: full sidebar with Essentials, folders, archive and address field`

### Task 14: Workspace switcher, ⌃1–9, swipe and Settings

**Files:**
- Create: `Sources/StaveCore/Sidebar/WorkspaceSwipeTracker.swift`, `Tests/StaveCoreTests/WorkspaceSwipeTrackerTests.swift`, `Stave/Views/Sidebar/WorkspaceSwitcher.swift`, `WorkspaceEditor.swift`, `SwipeCatcher.swift`, `Stave/Views/Settings/SettingsView.swift`
- Modify: `Stave/App/StaveApp.swift`, `Views/Sidebar/SidebarView.swift`

**Interfaces:**
- Produces:
  - `public struct WorkspaceSwipeTracker: Sendable { static let threshold: Double = 60; mutating func began(); mutating func changed(fingerDeltaX: Double, fingerDeltaY: Double) -> Int?; mutating func ended() }`. `changed` takes finger travel (positive = rightward), returns +1 (next workspace, fingers moving left) or −1 once per gesture when the accumulated horizontal travel passes the threshold and horizontal travel is at least 1.5 × vertical; nil otherwise. A gesture that started vertical never switches.
  - `SwipeCatcher` (`NSViewRepresentable`) forwards trackpad `scrollWheel` events with a `phase` (ignoring `momentumPhase`) to the tracker, converting `scrollingDeltaX` to finger travel with `isDirectionInvertedFromDevice`, and calls `switchWorkspace(offset:)`.
  - `WorkspaceSwitcher`: one button per workspace (`WorkspaceIcon`, tinted with its colour, current one highlighted, label `SidebarLabels.workspace`), a "+" button opening `WorkspaceEditor`, context menu Edit / Move Left / Move Right / Delete (Delete confirms: "Delete “‹name›”? Its tabs go to the archive."). A profile menu (decision 3) lists profiles and "New Profile…".
  - The Workspaces menu: one item per workspace of the key window's profile, ⌃1–⌃9 on the first nine when `SettingKeys.workspaceShortcutsEnabled` is true, then New Workspace.
  - `SettingsView` (SwiftUI `Settings` scene): "Use ⌃1–9 to switch workspaces" toggle with the note "If macOS uses ⌃1–9 to switch desktops, turn those off in System Settings ▸ Keyboard ▸ Keyboard Shortcuts ▸ Mission Control, or turn this off."
  - Workspace changes animate per decision 18 using `lastSwitchDirection`.

- [ ] **Step 1: Write failing tests** `WorkspaceSwipeTrackerTests`: 30 + 31 leftward (−) → +1 on the second call, then nil for the rest of the gesture; rightward 61 → −1; 59 then `ended()` → nil, and a new gesture starts from 0; mostly vertical (dx 70, dy 60) → nil; vertical start then horizontal → nil.
- [ ] **Step 2: Run** `--filter WorkspaceSwipeTrackerTests` → FAIL.
- [ ] **Step 3: Implement** the tracker, then the views and menu.
- [ ] **Step 4: Run** `--filter WorkspaceSwipeTrackerTests` → PASS; build → succeeds.
- [ ] **Step 5: By-hand check** (seeded). Screenshot the switcher (Home and Work icons, Home highlighted). ⌃2 → Work's tint and tabs (screenshot); ⌃9 → nothing changes; ⌃1 → Home. Create a workspace from the menu (New Workspace) with the keyboard → it appears third and is current. Open Settings (⌘,), turn off the shortcut toggle → ⌃2 does nothing. Nico checks: two-finger swipe in both directions, one switch per swipe; the workspace context menu.
- [ ] **Step 6: Commit** `feat: workspace switcher with ⌃1–9, swipe and Settings`

### Task 15: Command bar UI

**Files:**
- Create: `Stave/Views/CommandBar/CommandBarView.swift`
- Modify: `Views/BrowserWindowView.swift`, `Views/Sidebar/AddressField.swift`, `Stave/App/StaveApp.swift`

**Interfaces:**
- Consumes: `CommandBarModel`, `BrowserWindowModel.commandCandidates()` and `perform(_:mode:)` (T11).
- Produces: a centred overlay (decision 22) with a text field and result list. ↑/↓ move the selection, Return performs, Escape or a click outside closes it, and focus goes back to the sidebar list. Rows show an icon per kind, the title, and a secondary line (URL host, workspace name for tabs in other workspaces, "Archived" for archived). Each row's VoiceOver label is "‹title›, ‹kind›", with ", in ‹workspace›" where shown. Menus: ⌘T New Tab (`.newTab`), ⌘L Open Location (`.currentTab`). Outcomes: `.showArcImport` → the import sheet (T19; until then, nothing), `.showArchive` → the archive popover, `.newWindow`, `.newWorkspace` → `WorkspaceEditor`, `.newProfile` → a name prompt, `.chooseSearchEngine` → an inline engine picker inside the bar that saves the setting and then runs the search, `.copy` → `NSPasteboard`.

- [ ] **Step 1: Implement.**
- [ ] **Step 2: Build** → succeeds.
- [ ] **Step 3: By-hand check** (seeded). ⌘T, type `exa` → screenshot: the "Search for exa" row first, then matching tabs from both workspaces. Return with no engine → the engine picker (screenshot); choose DuckDuckGo → a new tab at the top whose placeholder shows the DuckDuckGo URL. ⌘T, type `example.net`, Return → a new tab for `https://example.net`. ⌘L → the bar opens prefilled with the selected tab's full URL. ⌘T, type `javascript:alert(1)` → the first row is a search, not an open. Type the name of a tab in Work, ↓, Return → the window switches to Work with that tab selected. Escape → focus back in the list (↓ moves the selection).
- [ ] **Step 4: Commit** `feat: command bar`

### Task 16: Drag and drop, and keyboard moves

**Files:**
- Create: `Sources/StaveCore/Sidebar/SidebarDropPlanner.swift`, `Tests/StaveCoreTests/SidebarDropPlannerTests.swift`
- Modify: `Window/BrowserWindowModel.swift` (`apply(_ move: SidebarMove)`, `moveSelected(by delta: Int)`), `Stave/Views/Sidebar/SidebarView.swift`, `SidebarRowView.swift`, `EssentialsGrid.swift`, `WorkspaceSwitcher.swift`, `Stave/App/StaveApp.swift`

**Interfaces:**
- Produces:
  - `SidebarDropPlanner.move(dragging: SidebarItemID, onto target: SidebarDropTarget, snapshot: SidebarSnapshot) -> SidebarMove?`. `.row(r, .before)` anchors after r's previous sibling in r's list (nil when r is first); `.after` anchors after r; `.into` a folder appends to the folder (allowed for a folder only when the folder being dragged has no sub-folders and the target is top-level); `.essentials(index:)` → `.essential` after the Essential at `index − 1`; `.pinnedEnd` → pinned root, last; `.regularTop` → regular, first; `.workspace(w)` per decision 39. Dropping onto itself or into its own folder chain → nil. A folder can't go into the regular section or Essentials → nil.
  - `SidebarDropPlanner.keyboardMove(_ item: SidebarItemID, by delta: Int, snapshot: SidebarSnapshot) -> SidebarMove?`: one step within the item's own sibling list; nil at either end.
  - `BrowserWindowModel.apply(_:)` calls `moveTab` / `moveFolder` through `perform`; `moveSelected(by:)` uses `keyboardMove` on the selected row.
  - Views: rows, the Essentials grid, the pinned-section end, the regular top and each workspace button are drop targets (the drop shows an insertion line, or highlights a folder for `.into`). The drag payload follows decision 38. Menu items Move Up ⌥⌘↑ and Move Down ⌥⌘↓, plus matching VoiceOver actions.

- [ ] **Step 1: Write failing tests**: `beforeFirstAnchorsNil`, `afterAnchorsTheRow`, `intoFolderAppends`, `folderWithSubfoldersCantGoIntoAFolder`, `ontoItselfIsNil`, `regularToEssentials` (index 1 → after the first Essential, section `.essential`, workspace nil), `pinnedToWorkspaceKeepsPinned`, `essentialOntoWorkspaceIsNil`, `folderIntoRegularIsNil`, `keyboardMoveStepsWithinList` (up from the first → nil; down from the middle → after the next sibling), and in `BrowserWindowModelTests` `applyMovesAndBumps`.
- [ ] **Step 2: Run** `--filter SidebarDropPlannerTests` → FAIL.
- [ ] **Step 3: Implement** the planner, the model methods, then the views.
- [ ] **Step 4: Run** the whole suite → PASS; build → succeeds.
- [ ] **Step 5: By-hand check** (seeded). Select a regular tab and press ⌥⌘↑ twice through System Events → screenshot shows it two places higher; ⌥⌘↓ at the bottom does nothing. Relaunch → the order holds. Nico checks: drag a regular tab into Reading, a pinned tab into Essentials, a folder into another folder (refused when it has a sub-folder), a tab onto the Work icon, and a tab out to TextEdit (gives its URL).
- [ ] **Step 6: Commit** `feat: drag and drop and keyboard moves in the sidebar`

### Task 17: Compact mode

**Files:**
- Create: `Sources/StaveCore/Window/CompactReveal.swift`, `Tests/StaveCoreTests/CompactRevealTests.swift`, `Stave/Views/Compact/CompactContainer.swift`
- Modify: `Views/BrowserWindowView.swift`, `Views/Settings/SettingsView.swift`, `Stave/App/StaveApp.swift`

**Interfaces:**
- Produces:
  - `public struct CompactReveal: Equatable, Sendable { static let edgeWidth: Double = 8; static let hideDelay: TimeInterval = 0.4; private(set) var isRevealed: Bool; private(set) var hideAt: TimeInterval?; mutating func pointerMoved(x: Double, sidebarWidth: Double, at time: TimeInterval); mutating func setHeld(_ held: Bool, at time: TimeInterval); mutating func tick(at time: TimeInterval) }`. Rules from decision 17: x ≤ edge reveals; revealed and x ≤ sidebar width cancels any hide; revealed and x > sidebar width schedules `hideAt = time + hideDelay` (not rescheduled while already scheduled); `tick` at or after `hideAt` hides unless held; releasing a hold while the pointer is outside schedules a hide.
  - `CompactContainer`: when `SettingKeys.compactMode` is on, the content fills the window and the sidebar slides in as an overlay with a shadow, driven by `CompactReveal` (pointer from an `NSTrackingArea` / `onContinuousHover`, ticks from a 0.1 s timer only while a hide is pending). The hold is set while the command bar, a context menu, a popover or a drag is active. View ▸ Compact Mode (⌃⌘S) and a Settings toggle flip the setting; the command bar action does too (T11).
  - Keyboard-only: when compact mode is on, moving keyboard focus into the sidebar (⌘L/⌘T closing back to it, or Tab) reveals it and holds while it has focus.

- [ ] **Step 1: Write failing tests**: `edgeReveals`, `insideSidebarStays`, `leavingSchedulesHide`, `returningCancelsHide`, `tickHidesAfterDelay` (0.39 s → shown, 0.4 s → hidden), `heldNeverHides`, `releasingHoldOutsideSchedules`, `notRescheduledWhilePending`.
- [ ] **Step 2: Run** `--filter CompactRevealTests` → FAIL.
- [ ] **Step 3: Implement.**
- [ ] **Step 4: Run** → PASS; build → succeeds.
- [ ] **Step 5: By-hand check** (seeded). ⌃⌘S → screenshot: placeholder fills the window, no sidebar. ⌘T → the command bar works; Escape. ⌃⌘S again → the sidebar is back. Relaunch with compact on → still compact. Nico checks: hover at the left edge reveals; moving away hides after a short beat; the sidebar stays open while a context menu is open.
- [ ] **Step 6: Commit** `feat: compact mode`

### Task 18: The Arc import flow

**Files:**
- Create: `Sources/StaveCore/ArcImport/ArcImportFlow.swift`, `Tests/StaveCoreTests/ArcImportFlowTests.swift`

**Interfaces:**
- Consumes: `ArcImporter.run(sidebarFile:…)`, `localStateFile(nextTo:)`, `isAvailable(home:)`, `lastImport` (T5); `ArcImportSummary`, `ArcImportCopy` (T7); `StoreRevision` (T10).
- Produces:
  - `@MainActor @Observable public final class ArcImportFlow`
    - `public enum Source: Equatable, Sendable { case arcOnThisMac(home: URL), pickedFile(URL) }`
    - `public enum Phase: Equatable { case ready, confirmRepeat(previous: Date), importing, finished(ArcImportSummary), failed(String) }`
    - `init(store: OrganizationStore, revision: StoreRevision, source: Source)` reads `previousImport: Date?`
    - `var includeUnpinnedTabs: Bool` (default false); `private(set) var phase: Phase`
    - `func start() async` (with a previous import and phase `.ready` → `.confirmRepeat`; otherwise runs), `func confirmRepeat() async` (runs), `func cancelRepeat()` (back to `.ready`)
    - `static func shouldOfferOnFirstRun(arcHome: URL, store: OrganizationStore) throws -> Bool` = `ArcImporter.isAvailable(home:)` and no previous import and `firstRunCompleted == false`
  - The import runs off the main actor (`Task.detached`, the store is `Sendable`); success → `revision.bump()` and `.finished`; failure → `.failed(ArcImportCopy.errorMessage(for:))`.

- [ ] **Step 1: Write failing tests**
  - `importsFromAHome`: a temp home holding `basic.json` → `.finished`; the summary's imported lines match `basic.json`'s counts; the revision is bumped; `lastImport` is set.
  - `repeatAsksFirst`: a second flow → `start()` → `.confirmRepeat(previous:)` with the first import's date; `cancelRepeat()` → `.ready` and no second copy; `confirmRepeat()` → `.finished` and workspace count doubled.
  - `unpinnedOptionIsPassed`: with `includeUnpinnedTabs` on → regular tabs imported.
  - `failedImportLeavesNoRecord` (Review Focus 4): a picked file containing `{}` → `.failed("This file doesn't contain an Arc sidebar.")`, `lastImport` nil, revision unchanged.
  - `offerRules`: offered when the file exists, nothing was imported and first run isn't completed; not offered when any of the three fails.
- [ ] **Step 2: Run** `--filter ArcImportFlowTests` → FAIL.
- [ ] **Step 3: Implement.**
- [ ] **Step 4: Run** the whole suite → PASS.
- [ ] **Step 5: Commit** `feat: Arc import flow with repeat confirmation`

### Task 19: First run and the Arc import UI

**Files:**
- Create: `Stave/Views/Import/FirstRunView.swift`, `Views/Import/ArcImportSheet.swift`
- Modify: `Stave/App/AppDelegate.swift`, `App/StaveApp.swift`, `Views/Settings/SettingsView.swift`, `Views/BrowserWindowView.swift`

**Interfaces:**
- Consumes: `ArcImportFlow` (T18), `ArcImportCopy`/`ArcImportSummary` (T7), settings (T3).
- Produces:
  - `FirstRunView`: a sheet on the first window when `firstRunCompleted` is false. Title "Welcome to Stave". "Choose a search engine": the five engines, none selected; Continue is disabled until one is chosen. The ⌃1–9 note from T14 with its toggle. When `shouldOfferOnFirstRun` is true: "Bring your Arc spaces, pinned tabs and Favorites into Stave." with an "Import from Arc…" button that opens the import sheet after Continue. Continue saves the engine and sets `firstRunCompleted`.
  - `ArcImportSheet(flow:)` by phase. `.ready`: the source ("From Arc on this Mac" or the picked file's name), the "Also import unpinned tabs" toggle, `loginsNotice`, `keepACopy`, Cancel / Import. `.confirmRepeat`: `repeatWarning`, Cancel / "Import Again". `.importing`: a progress indicator. `.finished`: the headline and three sections ("Imported", "Changed to fit Stave", "Not imported"), each shown only when non-empty, plus Done. `.failed`: the message plus Choose Another File… / Close.
  - File ▸ Import from Arc…: with `ArcImporter.isAvailable(home: arcHome)` it opens the sheet for `.arcOnThisMac`; otherwise, and from "Choose Another File…", an `NSOpenPanel` (one file, any type, starting in the home folder, message "Choose a copy of Arc's StorableSidebar.json") then the sheet for `.pickedFile`.
  - Settings gains the search engine picker.

- [ ] **Step 1: Implement.**
- [ ] **Step 2: Build** → succeeds.
- [ ] **Step 3: By-hand check** with a fresh data folder and the synthetic `basic.json` under `-StaveArcHome` (no seed). Screenshot the first-run sheet: Continue disabled until an engine is picked; the Arc offer is present. Choose an engine, Continue → the import sheet (screenshot: toggle, logins notice, keep-a-copy line). Import → the report sheet (screenshot); its counts match `basic.json`, and the sidebar shows the imported workspaces. File ▸ Import from Arc… → the repeat warning (screenshot); Cancel → nothing added. Relaunch with a home that has no Arc file → no Arc offer in the first run (fresh data folder), and File ▸ Import from Arc… opens the file picker (screenshot). Pick `Packages/StaveCore/Tests/StaveCoreTests/Fixtures/arc/local-state.json` → the "doesn't contain an Arc sidebar" message. The real `~/Library/Application Support/Arc` is never offered or read: `-StaveArcHome` is always passed.
- [ ] **Step 4: Commit** `feat: first run and Arc import UI`

### Task 20: Accessibility pass

**Files:**
- Modify: whichever views the pass finds wanting (expected: `SidebarRowView`, `EssentialsGrid`, `WorkspaceSwitcher`, `CommandBarView`, `ArcImportSheet`, `SettingsView`)

**Interfaces:**
- Consumes everything above. Produces no new API; any missing rule found here goes into `SidebarLabels` with a test first.

- [ ] **Step 1: Keyboard-only walk-through** (seeded; Full Keyboard Access on, which System Events can enable). Using only keys: first-run sheet; switch workspaces (⌃1–9, the Workspaces menu); move through Essentials, folders and tabs; open and close folders; close, pin, unpin and reorder a tab (⌥⌘↑/↓); open and use the command bar; restore from the archive; toggle compact mode; run an import from the synthetic file; change every setting. Record each step as passed or fixed; screenshot the focus ring on an Essential tile and on a workspace button.
- [ ] **Step 2: VoiceOver labels.** `scripts/ax-dump.sh Stave` on the main window, the command bar, the archive popover, the import report and Settings: every button, row and tile has a non-empty description matching `SidebarLabels` where one applies; no element reads only as an SF Symbol name. Fix and re-run until clean.
- [ ] **Step 3: Reduce Motion.** With Reduce Motion on (`defaults write com.apple.universalaccess reduceMotion -bool true`, then restore), switching workspaces, the command bar and the compact reveal don't animate.
- [ ] **Step 4: Run** `swift test --package-path Packages/StaveCore` → PASS; build → succeeds. Nico checks: a short VoiceOver session (VO-arrow through the sidebar, the rotor's buttons list, the import report read aloud).
- [ ] **Step 5: Commit** `fix: accessibility pass over sidebar, command bar and import`

### Task 21: Docs and CI

**Files:**
- Modify: `README.md` (Status: the window, sidebar, command bar, compact mode and Arc import UI are done; web pages still wait on the engine), `docs/superpowers/plans/2026-10-28-stave-foundation.md` (roadmap entry 4 status), `CLAUDE.md` (the by-hand check's launch arguments and the rule that checks always pass `-StaveArcHome`)

- [ ] **Step 1: Update the three files** in plain words, unwrapped.
- [ ] **Step 2: Push the branch** and confirm CI is green on macOS 14 (Xcode 16.2) and macOS 15, Debug and Release.
- [ ] **Step 3: Commit** `docs: status and rules after plan 4`

The plan's "Outcome" and "Carried into later plans" sections are added after execution, from the final review.
