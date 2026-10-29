# Stave Foundation Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** A buildable Stave app whose organization model (profiles, workspaces, Essentials, pinned tabs and folders, regular tabs, archive, containers, window state) is stored safely on disk, fully unit-tested, and shown read-only in a first window — with no web views yet.

**Architecture:** All model and storage logic lives in a local Swift package, `StaveCore`, tested with `swift test` (no app host, so tests never launch the app). Storage is SQLite through GRDB, written on every change; there is no in-memory cache that could be lost. The app target is a thin AppKit/SwiftUI shell that opens the store at an explicit path and renders a snapshot.

**Tech Stack:** Swift 6, macOS 14+, XcodeGen, Swift Testing, GRDB 7 (SQLite, WAL mode), SwiftUI for the shell.

**Spec:** `docs/superpowers/specs/2026-10-28-stave-design.md`

## Roadmap (separate plans, written when their turn comes)

1. **Foundation** — this plan.
2. **Arc import** — parser for `StorableSidebar.json` into `OrganizationStore` calls, synthetic fixtures, import report. Depends only on this plan.
3. **Web layer** — tab web-view pool, restore of `interactionState`, popups tied to opener, data stores per profile/container/private window, content blocking, downloads, permissions. Depends on this plan and the Chorus engine tag (1.5.32+).
4. **Window and sidebar** — real sidebar (Essentials grid, folders, drag and drop, archive), command bar, workspace switching, compact mode, "bring it here" placeholder, accessibility.
5. **Browser basics and release** — default-browser registration, settings, site-compatibility tools, shortcuts, Sparkle, signing, notarization, Homebrew, the "beta is ready when" gate.

## Global Constraints

- macOS deployment target `14.0`; `SWIFT_VERSION` `6.0`; strict concurrency on.
- Bundle ID `com.nicojan.Stave`; Debug uses `com.nicojan.Stave.debug`.
- Data folder is always explicit: `~/Library/Application Support/Stave` (Release) or `~/Library/Application Support/Stave-debug` (Debug). Never a framework default path.
- Database file name `stave.sqlite`.
- Licence MIT; copy no code from Zen (MPL-2.0) or Ora (GPL-2.0).
- Every record has a `UUID` id and a `modifiedAt: Date`.
- Folders nest at most one level.
- Archived tabs are trimmed after 30 days.
- Nothing is ever deleted without passing through the archive, except by an explicit profile or container deletion the user confirmed.
- Markdown files are never hard-wrapped.
- Commits: `<type>: <description>`; stage named paths only, never `git add -A`.

## Review Focus

1. **A write for a tab that no longer exists** (the page reports a title change just after the tab was closed): the write throws `StoreError.notFound` and never re-creates the tab. Test in Task 5.
2. **A tab with no title, or a very long or non-Latin title:** stored unchanged; the snapshot shows the URL's host when the title is empty. Test in Task 5.
3. **Deleting a folder that still holds pinned tabs:** the tabs move to the workspace's pinned root, in order; nothing is archived or lost. Test in Task 6.
4. **Opening a database written by a newer Stave** (the user downgraded): opening fails with `StoreError.newerSchema` and leaves the file untouched. Test in Task 2.
5. **A saved window points at a workspace that was deleted** (deleted in another window before quit): on load the window falls back to the profile's first workspace instead of failing. Test in Task 9.

---

## File structure

```
Stave/
├── project.yml                         # XcodeGen: app target + local package
├── LICENSE                             # MIT
├── .github/workflows/test.yml          # swift test + xcodebuild build, macOS 14 and 15
├── Stave/
│   ├── App/StaveApp.swift              # @main, opens store, ensures a profile
│   ├── App/AppEnvironment.swift        # holds OrganizationStore for views
│   ├── Views/FoundationSidebarView.swift  # read-only snapshot list (replaced in plan 4)
│   ├── Info.plist
│   └── Stave.entitlements
└── Packages/StaveCore/
    ├── Package.swift
    ├── Sources/StaveCore/
    │   ├── StavePaths.swift            # data folder resolution
    │   ├── StoreError.swift
    │   ├── Database/StaveDatabase.swift    # open, WAL, migrator, schema v1
    │   ├── Model/Records.swift         # Profile, Workspace, Folder, Slot, Tab, Container, ArchivedTab, WindowState
    │   ├── Model/TabPlacement.swift    # pure ordering rules
    │   ├── OrganizationStore.swift     # core type + profiles/workspaces
    │   ├── OrganizationStore+Tabs.swift
    │   ├── OrganizationStore+Pinned.swift
    │   ├── OrganizationStore+Containers.swift
    │   └── OrganizationStore+Session.swift   # snapshot + window state
    └── Tests/StaveCoreTests/
        ├── TestSupport.swift           # temp-file store helper
        ├── PathsAndDatabaseTests.swift
        ├── TabPlacementTests.swift
        ├── ProfileWorkspaceTests.swift
        ├── TabTests.swift
        ├── PinnedTests.swift
        ├── MoveTests.swift
        ├── ContainerTests.swift
        └── SessionTests.swift
```

## Shared types (defined in Tasks 2–3, used everywhere)

```swift
public enum SlotSection: String, Codable, Sendable { case essential, pinned, regular }
public enum SlotKind: String, Codable, Sendable { case tab, split }   // only .tab created in v1
public enum NewTabOrigin: Sendable, Equatable { case commandBar, link(openerTabID: UUID), externalApp }
public enum NewTabEdge: String, Codable, Sendable { case top, bottom }
public enum CloseResult: Sendable, Equatable { case archived(UUID), unloaded }
public enum StoreError: Error, Equatable { case notFound, newerSchema, folderTooDeep, crossProfileMove, lastWorkspace, lastProfile, containerInUse, notPinned }
```

Records (GRDB `Codable, FetchableRecord, PersistableRecord, Sendable, Identifiable`), all with `id: UUID` and `modifiedAt: Date`:

- `Profile { name, dataStoreID: UUID, sortIndex: Double }`
- `Workspace { profileID, name, icon: String, colorHex: String, sortIndex: Double }`
- `Folder { workspaceID, parentFolderID: UUID?, title, sortIndex: Double, isOpen: Bool }`
- `Slot { profileID, workspaceID: UUID? (nil for essentials), section: SlotSection, kind: SlotKind, folderID: UUID?, sortIndex: Double }`
- `Tab { slotID, containerID: UUID?, pinnedURL: String?, pinnedTitle: String?, url: String, title: String, faviconURL: String?, interactionState: Data?, lastActiveAt: Date }`
- `Container { profileID, name, colorHex, dataStoreID: UUID }` (named containers only; throwaway containers are never stored — my call: their cookies are gone at quit, so restoring their tabs would mislead)
- `ArchivedTab { profileID, workspaceID: UUID?, url, title, faviconURL: String?, interactionState: Data?, containerID: UUID?, closedAt: Date }`
- `WindowState { profileID, workspaceID: UUID, selectedTabID: UUID?, frame: String, sortIndex: Double }`

Ordering uses `Double` sort indices: inserting between two neighbours takes their midpoint, so a move rewrites one row.

---

### Task 1: Project scaffold and CI

**Files:**
- Create: `project.yml`, `LICENSE`, `.github/workflows/test.yml`, `Stave/App/StaveApp.swift`, `Stave/Info.plist`, `Stave/Stave.entitlements`, `Packages/StaveCore/Package.swift`, `Packages/StaveCore/Sources/StaveCore/StaveCore.swift` (temporary `public let staveCoreVersion = "0.1.0"`), `Packages/StaveCore/Tests/StaveCoreTests/SmokeTests.swift`
- Modify: `.gitignore` (add `.build/`, `.swiftpm/`, `Stave.xcodeproj/xcuserdata/`)

**Interfaces:**
- Produces: package `StaveCore` (swift-tools-version 6.0, platform `.macOS(.v14)`, dependency `GRDB` from `https://github.com/groue/GRDB.swift` — use the newest 7.x release, `.upToNextMajor(from: "7.0.0")`); app target `Stave` depending on product `StaveCore`.

- [ ] **Step 1: Write the smoke test** `@Test func packageLinks() { #expect(staveCoreVersion == "0.1.0") }`
- [ ] **Step 2: Run** `swift test --package-path Packages/StaveCore` — expected: FAIL to compile until the source file exists, then PASS once Step 3 lands.
- [ ] **Step 3: Write `project.yml`** — mirror Chorus's `project.yml` shape: `bundleIdPrefix: com.nicojan`, deployment target 14.0, `packages: StaveCore: path: Packages/StaveCore`, app target `Stave` with `PRODUCT_BUNDLE_IDENTIFIER: com.nicojan.Stave`, Debug override `com.nicojan.Stave.debug`, `ENABLE_HARDENED_RUNTIME: true`, `GENERATE_INFOPLIST_FILE: true`, `MARKETING_VERSION: "0.1.0"`, `CURRENT_PROJECT_VERSION: "1"`. `StaveApp.swift` shows an empty `WindowGroup` titled "Stave". `LICENSE`: MIT, "Copyright (c) 2026 Nico Jan".
- [ ] **Step 4: Verify** `xcodegen generate && xcodebuild build -project Stave.xcodeproj -scheme Stave -destination 'platform=macOS'` → `BUILD SUCCEEDED`; run `xcodegen generate` again and confirm `git status --porcelain Stave.xcodeproj` shows no change.
- [ ] **Step 5: Write CI** — `.github/workflows/test.yml`: matrix `macos-14`, `macos-15`; select the newest installed Xcode (copy Chorus's step); install XcodeGen (`brew install xcodegen`); run `swift test --package-path Packages/StaveCore`, then `xcodegen generate` and `xcodebuild build` (Debug).
- [ ] **Step 6: Commit** `git add project.yml LICENSE .gitignore .github/workflows/test.yml Stave Packages Stave.xcodeproj && git commit -m "chore: scaffold Stave app and StaveCore package"`

### Task 2: Paths, database and schema v1

**Files:**
- Create: `Sources/StaveCore/StavePaths.swift`, `StoreError.swift`, `Database/StaveDatabase.swift`, `Model/Records.swift`; `Tests/StaveCoreTests/TestSupport.swift`, `PathsAndDatabaseTests.swift`
- Delete: `StaveCore.swift`, `SmokeTests.swift`

**Interfaces:**
- Produces: `StavePaths.dataDirectory(bundleIdentifier: String, applicationSupport: URL) -> URL`; `StaveDatabase.open(at fileURL: URL) throws -> StaveDatabase` (creates folder, WAL, runs migrations); `StaveDatabase.writer: any DatabaseWriter`; `StaveDatabase.schemaVersion: Int` (= 1); all record types above; `StoreError`; test helper `makeTempDatabase() throws -> (StaveDatabase, URL)` (a fresh file in a temp folder). Task 4 adds `makeTempStore() throws -> (OrganizationStore, URL)` beside it.

- [ ] **Step 1: Write failing tests**
  - `dataDirectoryForRelease`: `dataDirectory(bundleIdentifier: "com.nicojan.Stave", applicationSupport: base)` == `base/Stave`.
  - `dataDirectoryForDebug`: `"com.nicojan.Stave.debug"` → `base/Stave-debug`.
  - `openCreatesSchema`: open a temp file; the tables `profile, workspace, folder, slot, tab, container, archivedTab, windowState` exist.
  - `reopenKeepsData`: insert a `Profile`, close, reopen the same file; the profile is there.
  - `newerSchemaIsRefused` (Review Focus 4): open, then register an extra migration `"v999"` on a raw `DatabaseMigrator` and apply it to the file; `StaveDatabase.open(at:)` throws `StoreError.newerSchema`, and the file's byte size and modification date are unchanged.
- [ ] **Step 2: Run** `swift test --package-path Packages/StaveCore --filter PathsAndDatabaseTests` → FAIL (types missing).
- [ ] **Step 3: Implement.** Any bundle ID ending in `.debug` maps to `Stave-debug`, everything else to `Stave`. Migrator migration `"v1"` creates the tables with foreign keys (`workspace.profileID` cascade, `slot.workspaceID` cascade, `tab.slotID` cascade, `folder.workspaceID` cascade, `tab.containerID` set null is **not** used — containers can't be deleted while in use, see Task 8). Before migrating, compare `migrator.appliedIdentifiers(db)` with known identifiers; any unknown identifier → throw `.newerSchema` without writing. Use `DatabasePool` (WAL).
- [ ] **Step 4: Run** the filter again → PASS.
- [ ] **Step 5: Commit** `feat: store paths and schema v1`

### Task 3: Tab placement rules

**Files:**
- Create: `Sources/StaveCore/Model/TabPlacement.swift`, `Tests/StaveCoreTests/TabPlacementTests.swift`

**Interfaces:**
- Produces: `TabPlacement.sortIndex(origin: NewTabOrigin, regularIndices: [UUID: Double], edge: NewTabEdge) -> Double` where `regularIndices` maps the workspace's regular tab IDs to their sort indices.

- [ ] **Step 1: Write failing tests** (spec: command bar and external links go to the top, links from a tab go directly below it, setting flips top to bottom)
  - empty workspace → `0`.
  - `.commandBar`, `.top`, indices `[a:1, b:2]` → result `< 1`.
  - `.externalApp`, `.bottom`, `[a:1, b:2]` → result `> 2`.
  - `.link(openerTabID: a)`, `[a:1, b:2]` → `1 < result < 2`.
  - `.link(openerTabID: b)` where `b` is last (`[a:1, b:2]`) → `> 2`.
  - `.link(openerTabID: unknown)` → treated as `.commandBar` with the given edge.
  - Repeated insertion below the same opener 60 times keeps all indices distinct and ordered.
- [ ] **Step 2: Run** `--filter TabPlacementTests` → FAIL.
- [ ] **Step 3: Implement** with midpoints; top = `min - 1`, bottom = `max + 1`. If two neighbours are closer than `1e-9`, return the midpoint anyway and let the store renormalize (Task 5 owns renormalizing).
- [ ] **Step 4: Run** → PASS.
- [ ] **Step 5: Commit** `feat: deterministic new-tab placement`

### Task 4: OrganizationStore — profiles and workspaces

**Files:**
- Create: `Sources/StaveCore/OrganizationStore.swift`, `Tests/StaveCoreTests/ProfileWorkspaceTests.swift`
- Modify: `Tests/StaveCoreTests/TestSupport.swift` (add `makeTempStore()`)

**Interfaces:**
- Consumes: `StaveDatabase`, records.
- Produces: `public final class OrganizationStore: Sendable` with `init(database: StaveDatabase)`, `now: @Sendable () -> Date` (injectable clock, default `Date.init`), and:
  - `createProfile(name: String) throws -> Profile` (also creates workspace "Home", icon `"house"`, colour `"#8E8E93"`)
  - `profiles() throws -> [Profile]` (by `sortIndex`)
  - `ensureDefaultProfile() throws -> Profile` (creates "Personal" only if none exist)
  - `createWorkspace(profileID: UUID, name: String, icon: String, colorHex: String) throws -> Workspace` (appended last)
  - `renameWorkspace(_ id: UUID, to name: String) throws`
  - `workspaces(profileID: UUID) throws -> [Workspace]`
  - `deleteWorkspace(_ id: UUID) throws`

- [ ] **Step 1: Write failing tests**
  - `createProfileMakesHomeWorkspace`: one workspace named "Home"; the profile's `dataStoreID` differs from its `id`.
  - `ensureDefaultProfileIsIdempotent`: two calls → one profile named "Personal".
  - `workspacesKeepOrder`: create A, B, C → returned A, B, C.
  - `renameBumpsModifiedAt`: with the clock advanced 1 s, `modifiedAt` increases.
  - `deleteLastWorkspaceRefused`: deleting the only workspace throws `.lastWorkspace`.
  - `deleteWorkspaceArchivesItsTabs`: (written now, passes after Task 5 — mark with `.disabled("needs Task 5")` and enable in Task 5) a workspace with one pinned and one regular tab is deleted → both appear in `archivedTabs(profileID:)`.
  - `everyWriteSurvivesReopen`: create profile and workspace, open a second `OrganizationStore` on the same file → same data.
- [ ] **Step 2: Run** `--filter ProfileWorkspaceTests` → FAIL.
- [ ] **Step 3: Implement.** Every mutating method is one `writer.write` transaction that sets `modifiedAt = now()`.
- [ ] **Step 4: Run** → PASS (except the disabled test).
- [ ] **Step 5: Commit** `feat: profiles and workspaces in OrganizationStore`

### Task 5: Regular tabs and the archive

**Files:**
- Create: `Sources/StaveCore/OrganizationStore+Tabs.swift`, `Tests/StaveCoreTests/TabTests.swift`
- Modify: `ProfileWorkspaceTests.swift` (enable the archived-tabs test)

**Interfaces:**
- Consumes: `TabPlacement.sortIndex`.
- Produces:
  - `openTab(url: String, title: String, workspaceID: UUID, origin: NewTabOrigin, containerID: UUID?, edge: NewTabEdge) throws -> Tab`
  - `updateNavigation(tabID: UUID, url: String, title: String, faviconURL: String?, interactionState: Data?) throws`
  - `markActive(tabID: UUID) throws`
  - `closeTab(_ id: UUID) throws -> CloseResult`
  - `archivedTabs(profileID: UUID) throws -> [ArchivedTab]` (newest first)
  - `restoreArchivedTab(_ id: UUID, workspaceID: UUID) throws -> Tab` (to the top, by the `.commandBar` rule)
  - `trimArchive(olderThan days: Int = 30) throws -> Int` (rows removed)
  - `regularTabs(workspaceID: UUID) throws -> [Tab]` (by slot `sortIndex`)
  - `displayTitle(for tab: Tab) -> String` (title, or the URL's host when the title is empty, or the URL)

- [ ] **Step 1: Write failing tests**
  - `openPlacesByOrigin`: command-bar tab above existing ones; a link tab directly below its opener.
  - `closeRegularArchives`: result `.archived(id)`, the tab is gone from `regularTabs`, the archive holds its URL, title and `interactionState`.
  - `restoreFromArchive`: restored tab is first in `regularTabs`, keeps `interactionState`; the archive row is removed.
  - `trimRemovesOnlyOld`: archive rows closed 31 and 29 days before `now()` → `trimArchive()` returns 1 and keeps the 29-day row.
  - `updateAfterCloseThrowsNotFound` (Review Focus 1): close a tab, then `updateNavigation` on its id throws `.notFound`, and `regularTabs` stays empty.
  - `titlesStoredUnchanged` (Review Focus 2): titles `""`, 5,000 × "a", "日本語のタイトル 🎵" round-trip exactly; `displayTitle` of a tab with title `""` and URL `https://example.com/x` is `"example.com"`.
  - `renormalizesWhenCrowded`: 60 links opened below the same opener leave `regularTabs` in insertion order with distinct indices.
- [ ] **Step 2: Run** `--filter TabTests` → FAIL.
- [ ] **Step 3: Implement.** A tab and its slot are created together (`section: .regular, kind: .tab`). Closing a regular tab writes the `ArchivedTab` and deletes the slot in one transaction. When the gap between neighbours drops below `1e-9`, renumber the workspace's regular slots `0, 1, 2…` in the same transaction.
- [ ] **Step 4: Run** `--filter TabTests` and `--filter ProfileWorkspaceTests` → PASS.
- [ ] **Step 5: Commit** `feat: regular tabs, archive and placement`

### Task 6: Pinned tabs, folders and Essentials

**Files:**
- Create: `Sources/StaveCore/OrganizationStore+Pinned.swift`, `Tests/StaveCoreTests/PinnedTests.swift`

**Interfaces:**
- Produces:
  - `pinTab(_ id: UUID, folderID: UUID?) throws` (sets `pinnedURL`/`pinnedTitle` from current `url`/`title`; appended last in that folder or root)
  - `unpinTab(_ id: UUID) throws` (becomes a regular tab at the top; clears `pinnedURL`)
  - `resetPinnedTab(_ id: UUID) throws` (`url = pinnedURL`, `title = pinnedTitle`, `interactionState = nil`; throws `.notPinned` for a regular tab)
  - `removePinnedTab(_ id: UUID) throws` (archives it, then deletes)
  - `makeEssential(_ id: UUID) throws` / `removeEssential(_ id: UUID) throws` (an Essential slot has `workspaceID == nil`, `section: .essential`; removing archives it)
  - `essentials(profileID: UUID) throws -> [Tab]`
  - `createFolder(workspaceID: UUID, parentFolderID: UUID?, title: String) throws -> Folder`
  - `deleteFolder(_ id: UUID) throws`
  - `pinnedItems(workspaceID: UUID) throws -> [PinnedItem]` where `public enum PinnedItem: Sendable, Equatable { case tab(Tab), folder(Folder, children: [PinnedItem]) }`
  - `isDrifted(_ tab: Tab) -> Bool` (`pinnedURL != nil && url != pinnedURL`)
  - `closeTab` (from Task 5) returns `.unloaded` for pinned tabs and Essentials and changes nothing in the store.

- [ ] **Step 1: Write failing tests**
  - `pinThenResetRestoresPinnedPage`: pin at `https://a.com`, update navigation to `https://a.com/deep`; `isDrifted` true; after `resetPinnedTab`, `url == "https://a.com"`, `interactionState == nil`.
  - `closingPinnedUnloads`: `closeTab` → `.unloaded`; the tab is still in `pinnedItems`; archive empty.
  - `folderNestsOneLevel`: a folder inside a top-level folder succeeds; a third level throws `.folderTooDeep`.
  - `deleteFolderKeepsTabs` (Review Focus 3): folder holding tabs T1, T2 is deleted → T1 then T2 appear at the pinned root, archive empty.
  - `essentialsAreProfileWide`: an Essential made in workspace A appears in `essentials(profileID:)` and in neither workspace's `pinnedItems` or `regularTabs`.
  - `removePinnedArchives`: removed pinned tab is in the archive.
  - `unpinMovesToRegularTop`.
- [ ] **Step 2: Run** `--filter PinnedTests` → FAIL.
- [ ] **Step 3: Implement.** `deleteFolder` re-parents children: a sub-folder moves to the root; its tabs keep their order after the deleted folder's position.
- [ ] **Step 4: Run** → PASS.
- [ ] **Step 5: Commit** `feat: pinned tabs, folders and Essentials`

### Task 7: Moving and reordering

**Files:**
- Modify: `Sources/StaveCore/OrganizationStore+Pinned.swift` (or a new `OrganizationStore+Move.swift` if the file passes ~250 lines)
- Create: `Tests/StaveCoreTests/MoveTests.swift`

**Interfaces:**
- Produces: `moveTab(_ id: UUID, toWorkspace workspaceID: UUID?, section: SlotSection, folderID: UUID?, after previousTabID: UUID?) throws` — `workspaceID == nil` only with `.essential`; `previousTabID == nil` means first. Moving between sections applies the pin/unpin side effects of Task 6.

- [ ] **Step 1: Write failing tests**
  - `reorderWithinRegular`: A, B, C → move C after A → A, C, B.
  - `moveBetweenWorkspacesKeepsState`: `interactionState` and `id` unchanged after a move to another workspace of the same profile.
  - `crossProfileRefused`: move to a workspace of another profile throws `.crossProfileMove` and nothing changes.
  - `regularToPinnedFolderPins`: moving into a folder in `.pinned` sets `pinnedURL`.
  - `essentialToWorkspaceUnessentials`.
- [ ] **Step 2: Run** `--filter MoveTests` → FAIL.
- [ ] **Step 3: Implement** in one transaction per move; sort index is the midpoint between `previousTabID` and its next neighbour in the target list.
- [ ] **Step 4: Run** → PASS.
- [ ] **Step 5: Commit** `feat: move and reorder tabs`

### Task 8: Named containers and profile deletion

**Files:**
- Create: `Sources/StaveCore/OrganizationStore+Containers.swift`, `Tests/StaveCoreTests/ContainerTests.swift`

**Interfaces:**
- Produces:
  - `createContainer(profileID: UUID, name: String, colorHex: String) throws -> Container`
  - `containers(profileID: UUID) throws -> [Container]`
  - `deleteContainer(_ id: UUID) throws -> UUID` (returns the `dataStoreID` the caller must remove; throws `.containerInUse` when any tab or archived tab uses it — archived tabs keep the container alive so restoring one never lands in the wrong store)
  - `deleteProfile(_ id: UUID) throws -> [UUID]` (returns the profile's and its containers' `dataStoreID`s for the web layer to remove; cascades everything else; throws `.lastProfile` for the only profile)

- [ ] **Step 1: Write failing tests**
  - `containerTabsCarryContainer`: `openTab(..., containerID: c)` → `tab.containerID == c`.
  - `deleteInUseRefused`: container used by an open tab → `.containerInUse`; after closing the tab it is still refused (archived tab uses it); after `trimArchive` removes that row, deletion returns the container's `dataStoreID`.
  - `deleteProfileReturnsAllStores`: a profile with two containers → three distinct IDs, and its workspaces, tabs and archive are gone.
  - `lastProfileRefused` → `.lastProfile`.
- [ ] **Step 2: Run** `--filter ContainerTests` → FAIL.
- [ ] **Step 3: Implement.**
- [ ] **Step 4: Run** → PASS.
- [ ] **Step 5: Commit** `feat: named containers and safe profile deletion`

### Task 9: Session snapshot and window state

**Files:**
- Create: `Sources/StaveCore/OrganizationStore+Session.swift`, `Tests/StaveCoreTests/SessionTests.swift`

**Interfaces:**
- Produces:
  - `public struct SidebarSnapshot: Sendable, Equatable { profile: Profile; workspace: Workspace; essentials: [Tab]; pinned: [PinnedItem]; regular: [Tab] }`
  - `sidebarSnapshot(workspaceID: UUID) throws -> SidebarSnapshot`
  - `saveWindows(_ windows: [WindowState]) throws` (replaces all rows in one transaction)
  - `restoredWindows() throws -> [WindowState]` (a window whose `workspaceID` no longer exists falls back to its profile's first workspace; a window whose profile is gone is dropped; if none remain, returns one window on the default profile's first workspace)
  - Private windows are never passed to `saveWindows` (enforced by the caller in plan 4; documented on the method).

- [ ] **Step 1: Write failing tests**
  - `snapshotOrdersEverything`: Essentials, pinned tree and regular tabs come back in stored order.
  - `windowsRoundTrip`: two windows saved → same two restored, same order and frames.
  - `deletedWorkspaceFallsBack` (Review Focus 5): save a window on workspace B, delete B → restored window shows the profile's first workspace and `selectedTabID == nil`.
  - `noWindowsGivesDefault`: empty store → one window on "Personal" / "Home".
- [ ] **Step 2: Run** `--filter SessionTests` → FAIL.
- [ ] **Step 3: Implement** each read in a single `writer.read`.
- [ ] **Step 4: Run** the whole suite `swift test --package-path Packages/StaveCore` → all PASS.
- [ ] **Step 5: Commit** `feat: sidebar snapshot and window restore`

### Task 10: App shell on the real store

**Files:**
- Create: `Stave/App/AppEnvironment.swift`, `Stave/Views/FoundationSidebarView.swift`
- Modify: `Stave/App/StaveApp.swift`

**Interfaces:**
- Consumes: `StavePaths.dataDirectory`, `StaveDatabase.open`, `OrganizationStore.ensureDefaultProfile`, `restoredWindows`, `sidebarSnapshot`, `saveWindows`, `displayTitle`.
- Produces: `@MainActor final class AppEnvironment: ObservableObject { let store: OrganizationStore }`, created once at launch from `Bundle.main.bundleIdentifier!` and `FileManager.default.url(for: .applicationSupportDirectory, …)`.

- [ ] **Step 1: Implement.** On launch: open the database at `dataDirectory/stave.sqlite`; if it throws `.newerSchema`, show an alert ("This copy of Stave is older than the one that last used your data. Install the newest Stave to open it.") and quit without touching the file. Otherwise `ensureDefaultProfile()`, then open one window per `restoredWindows()`. The window lists the snapshot read-only: Essentials, pinned tree, regular tabs (titles via `displayTitle`). On quit, `saveWindows` with the open windows.
- [ ] **Step 2: Verify** `xcodegen generate && xcodebuild build -project Stave.xcodeproj -scheme Stave -destination 'platform=macOS'` → `BUILD SUCCEEDED`. Launch the Debug build; a window titled "Stave" shows "Home" with empty sections; `~/Library/Application Support/Stave-debug/stave.sqlite` exists and `~/Library/Application Support/Stave/` does not.
- [ ] **Step 3: Verify crash safety by hand.** With the Debug app running, insert a tab through a temporary Debug-only menu item "Add sample tab" (remove it in plan 4), then `kill -9` the process and relaunch: the tab is listed.
- [ ] **Step 4: Run** the full package suite again → PASS; push and confirm CI is green on macOS 14 and 15.
- [ ] **Step 5: Commit** `feat: app shell restores the stored organization`
