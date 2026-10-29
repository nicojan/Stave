# Stave Arc Import Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** `StaveCore` can read Arc's `StorableSidebar.json` (and, optionally, Arc's `Local State` for profile names), turn it into Stave profiles, workspaces, pinned tabs and folders, Essentials and (optionally) regular tabs in one all-or-nothing write, and return a report of everything it imported, flattened or skipped. No UI.

**Architecture:** Three pure layers and one write, all in `StaveCore/ArcImport/`. (1) `ArcSidebarParser` turns bytes into an `ArcSidebar` value that mirrors Arc's shape (spaces, item trees in `childrenIds` order, Favorites per profile), tolerating unknown shapes. (2) `ArcImportPlanner` turns that into an `ArcImportPlan` that already obeys Stave's rules (folders nest one level, Essentials are flat, only web URLs) and the report's flattened/skipped entries. (3) `OrganizationStore.importArc(_:)` writes the plan in a single GRDB transaction and fills in the report's imported counts. `ArcImporter` chains the three for callers (plan 4's UI).

**Tech Stack:** Swift 6 (language mode 6, must compile on Swift 6.0.3 / Xcode 16.2), Swift Testing, GRDB 7 (capped `<7.9`), Foundation `JSONDecoder` only.

**Spec:** `docs/superpowers/specs/2026-10-28-stave-design.md` — item 4 ("Arc import"), "Bookmarks", the folder rule under "Pinned tabs", and "The Arc import parser" (the confirmed format, with sources). Read that section before Task 1; it is the format reference for this whole plan.

## Global Constraints

- Licence MIT. Copy no code from Zen (MPL-2.0), Ora (GPL-2.0) or Nook (GPL-3.0). This plan adapts no code from anyone; the format facts come from the spec.
- Test fixtures never contain anyone's real browsing data (the repo is public). Every fixture URL uses `example.com`, `example.org` or `example.net`; titles are invented.
- Never read, copy or print `~/Library/Application Support/Arc/` in tests, fixtures, logs or commits. Tests use only the fixtures in this plan.
- Folders hold pinned tabs and nest one level: a top-level folder may contain folders, which may not. Deeper Arc folders are flattened into their nearest allowed parent, and the report says so.
- Unpinned Arc tabs → regular tabs is optional and **off by default**.
- Nothing already in the user's Stave is changed, moved or deleted by an import.
- On Swift 6.0, `try #require` must not be nested inside `#expect`; hoist it to a `let` first.
- `swift test --package-path Packages/StaveCore` must pass on macOS 14 (Xcode 16.2) and macOS 15 in CI.
- Commits: `<type>: <description>`; stage named paths only, never `git add -A`. Markdown is never hard-wrapped.

## Rulings made while writing this plan (Nico was asleep)

Each can be revisited; the cost if wrong is noted.

1. **Only `http` and `https` URLs are imported** (case-insensitive scheme). Everything else (`javascript:`, `file:`, `data:`, `arc:`, `chrome:`, `about:`, empty) is skipped and reported. Cost if wrong: a user loses, say, a pinned `file:` link, and the report names it.
2. **Arc's default profile imports into Stave's first profile** (`ensureDefaultProfile`). Each custom Arc profile that has at least one space or one Favorite becomes a new Stave profile. It is named from `Local State` when that is supplied and holds a name, and otherwise from its `directoryBasename`. Custom profiles with neither spaces nor Favorites are dropped silently, since there is nothing in them. Cost if wrong: a user who wanted everything in one profile has to move it by hand.
3. **A new profile created by the import gets no "Home" workspace** unless it would otherwise have no workspace, because a profile must keep at least one. Stave's existing default profile and its Home workspace are left alone, even if empty.
4. **An Arc space whose profile marker isn't recognised goes to the default profile**, and the report says so.
5. **Workspace icon:** Arc's emoji (`emoji_v2`) is kept as the workspace `icon` string. Arc's named icons are not SF Symbols, so they and missing icons become `"square.grid.2x2"`. Plan 4 renders an `icon` that is not plain ASCII as an emoji. Cost if wrong: an icon looks generic.
6. **Workspace colour:** Arc's `primaryColorPalette.midTone` channels are clamped to 0…1 and written as `#RRGGBB`, uppercase. When the colour is missing it becomes `#8E8E93`, Stave's Home grey.
7. **Split views are flattened** into separate tabs at the split's position (pinned or regular), reported once per split. Favorites folders and splits flatten into the flat Essentials list, also reported.
8. **`easel`, `welcomeToArc` and any unknown item kind are skipped** and reported with their kind and title.
9. **A repeat import is not detected.** It adds a second copy. Plan 4's UI offers the import once and warns before a repeat. That item is added to the carry-forward list below.
10. **File limits:** a sidebar file larger than 64 MiB is refused (`ArcImportError.fileTooLarge`), and so is a tree deeper than 64 levels. Nico's real file is under 100 KB.
11. **An item reached a second time** (listed under two parents, or in a cycle) is imported only at its first position. It is reported as `.duplicateItem`, and the walk never loops.

## Review Focus

1. **A dangerous or non-web URL in a pinned tab or Favorite** (`javascript:alert(1)`, `file:///etc/hosts`, `data:…`, `JavaScript:` with odd casing): it never becomes a tab, and the report lists it as skipped with its scheme. Test in Task 3 (`nonWebURLsAreSkipped`).
2. **A cycle or an item listed under two parents** (a damaged or hand-edited file): the parse finishes and the item appears once. Test in Task 2 (`cycleAndSharedChildImportOnce`).
3. **The write fails partway** (a plan that breaks a store rule): the store is unchanged. That means no profile, workspace, folder, tab or Essential, and the error propagates. Test in Task 4 (`failedImportWritesNothing`).
4. **Importing into a Stave that already has data:** existing profiles, workspaces, Essentials and tabs keep their ids and order. Imported workspaces come after the existing ones, and imported Essentials after the existing Essentials. Test in Task 4 (`importAppendsAfterExistingData`).
5. **Titles that are empty, very long, non-Latin or emoji:** stored exactly as Arc had them, never trimmed or replaced. An empty title stays empty, because `displayTitle` already falls back to the host. Test in Task 3 (`titlesAreKeptVerbatim`).

---

## File structure

```
Packages/StaveCore/
├── Package.swift                                   # test target gains resources: [.copy("Fixtures")]
├── Sources/StaveCore/ArcImport/
│   ├── JSONValue.swift                             # tolerant Sendable JSON tree (Decodable)
│   ├── ArcSidebar.swift                            # parsed Arc model + ArcImportError
│   ├── ArcSidebarParser.swift                      # bytes → ArcSidebar
│   ├── ArcProfileNames.swift                       # Local State bytes → [directoryBasename: name]
│   ├── ArcImportPlan.swift                         # Stave-shaped plan + options
│   ├── ArcImportReport.swift                       # imported counts, flattened, skipped
│   ├── ArcImportPlanner.swift                      # ArcSidebar → (ArcImportPlan, report entries)
│   ├── ArcImporter.swift                           # facade + Arc's default file locations
│   └── (store write) ../OrganizationStore+ArcImport.swift
└── Tests/StaveCoreTests/
    ├── Fixtures/arc/basic.json                     # synthetic: two spaces, default profile, the common shapes
    ├── Fixtures/arc/edge-cases.json                # synthetic: profiles, legacy markers, deep folders, splits, bad URLs, cycle
    ├── Fixtures/arc/local-state.json               # synthetic: profile.info_cache names
    ├── ArcFixtures.swift                           # loads fixtures from Bundle.module
    ├── ArcSidebarParserTests.swift
    ├── ArcImportPlannerTests.swift
    └── ArcImportStoreTests.swift
```

## Shared types (defined in Tasks 1–3, used by later tasks)

```swift
// ArcSidebar.swift
public enum ArcImportError: Error, Equatable { case fileTooLarge, notJSON, noSidebar, tooDeep }
public enum ArcProfileKey: Hashable, Sendable { case `default`; case custom(directoryBasename: String); case unrecognized }
public struct ArcTab: Equatable, Sendable { public var url: String; public var title: String }   // title = item.title ?? savedTitle ?? ""
public indirect enum ArcNode: Equatable, Sendable {
    case tab(ArcTab)
    case folder(title: String, children: [ArcNode])
    case split([ArcTab])
    case unsupported(kind: String, title: String?)
}
public struct ArcSpace: Equatable, Sendable {
    public var title: String?          // nil when unnamed in Arc
    public var profile: ArcProfileKey
    public var emoji: String?          // customInfo.iconType.emoji_v2
    public var colorHex: String?       // from windowTheme.primaryColorPalette.midTone, clamped, "#RRGGBB"
    public var pinned: [ArcNode]
    public var unpinned: [ArcNode]
}
public struct ArcSidebar: Equatable, Sendable {
    public var spaces: [ArcSpace]                       // sidebar order
    public var favorites: [ArcProfileKey: [ArcNode]]    // one entry per topApps container
    public var duplicateItems: Int                      // items reached twice (ruling 11)
}

// ArcImportPlan.swift
public struct ArcImportOptions: Equatable, Sendable { public var includeUnpinnedTabs: Bool = false; public init(includeUnpinnedTabs: Bool = false) }
public struct PlannedTab: Equatable, Sendable { public var url: String; public var title: String }
public indirect enum PlannedPinned: Equatable, Sendable { case tab(PlannedTab); case folder(title: String, children: [PlannedPinned]) }
public struct PlannedWorkspace: Equatable, Sendable { public var name, icon, colorHex: String; public var pinned: [PlannedPinned]; public var regular: [PlannedTab] }
public enum PlannedProfileTarget: Equatable, Sendable { case existingDefault; case new(name: String) }
public struct PlannedProfile: Equatable, Sendable { public var target: PlannedProfileTarget; public var workspaces: [PlannedWorkspace]; public var essentials: [PlannedTab] }
public struct ArcImportPlan: Equatable, Sendable { public var profiles: [PlannedProfile]; public var flattened: [ArcImportReport.Flattened]; public var skipped: [ArcImportReport.Skipped] }

// ArcImportReport.swift
public struct ArcImportReport: Equatable, Sendable {
    public struct Counts: Equatable, Sendable { public var profiles = 0, workspaces = 0, folders = 0, pinnedTabs = 0, essentials = 0, regularTabs = 0 }
    public enum Flattened: Equatable, Sendable {
        case folderTooDeep(space: String, folder: String)            // its contents moved up into the nearest allowed folder
        case splitView(space: String?, tabCount: Int)                 // space nil = a Favorite
        case favoritesFolder(folder: String)
    }
    public enum Skipped: Equatable, Sendable {
        case nonWebURL(space: String?, title: String, scheme: String) // scheme "" when the URL is empty or unparseable
        case unsupportedItem(space: String?, kind: String, title: String?)
        case unpinnedTabs(space: String, count: Int)                  // only when includeUnpinnedTabs is false and count > 0
        case unrecognizedProfile(space: String)                       // ruling 4: imported into the default profile
        case duplicateItem(count: Int)                                // once per import, when count > 0
    }
    public var imported: Counts
    public var flattened: [Flattened]
    public var skipped: [Skipped]
}
```

`space:` strings are the workspace name the space gets ("Space N" when unnamed; ruling below in Task 3). Every type listed has a `public init` with these memberwise parameters. Implementers may add `private` helpers, but no other public API.

---

### Task 1: Fixtures, JSON tree and the space/item parser

**Files:**
- Create: `Sources/StaveCore/ArcImport/JSONValue.swift`, `ArcSidebar.swift`, `ArcSidebarParser.swift`
- Create: `Tests/StaveCoreTests/Fixtures/arc/basic.json`, `Tests/StaveCoreTests/ArcFixtures.swift`, `Tests/StaveCoreTests/ArcSidebarParserTests.swift`
- Modify: `Package.swift` (test target: `resources: [.copy("Fixtures")]`)

**Interfaces:**
- Produces: the `ArcSidebar.swift` types above; `public enum ArcSidebarParser { public static let maximumFileSize = 64 * 1024 * 1024; public static let maximumDepth = 64; public static func parse(_ data: Data) throws -> ArcSidebar }`; test helper `func arcFixture(_ name: String) throws -> Data` (loads `Fixtures/arc/<name>.json` from `Bundle.module`).
- `JSONValue` is `internal`: `enum JSONValue: Decodable, Sendable, Equatable { case object([String: JSONValue]), array([JSONValue]), string(String), number(Double), bool(Bool), null }`, with `subscript(key: String) -> JSONValue?`, plus `var string: String?`, `var array: [JSONValue]?`, `var object: [String: JSONValue]?` and `var number: Double?`.

- [ ] **Step 1: Write `basic.json`** (synthetic, hand-written, following the spec's "Arc import parser" facts). Top level is `{"version": 1, "sidebar": {"containers": [{"global": {}}, {"spaces": [...], "items": [...], "topAppsContainerIDs": [...]}]}, "sidebarSyncState": {"items": []}}`. `spaces` and `items` alternate `"<id>", {object}`. It contains:
  - Space `S-WORK`: `"title": "Work"`, `profile: {"default": true}`, `customInfo: {iconType: {emoji_v2: "💼"}, windowTheme: {primaryColorPalette: {midTone: {red: 0.36, green: 0.42, blue: 0.95, alpha: 1}}}}`. Its `newContainerIDs` is `[{"pinned": {}}, "WORK-PIN", {"unpinned": {"_0": {"shared": {}}}}, "WORK-UNPIN"]`.
  - Space `S-2`: no `title`, `profile: {"default": true}`, `customInfo: {iconType: {icon: "star"}}`, and the containers `HOME-PIN` and `HOME-UNPIN`.
  - The containers are root items with `parentID: null` and `data.itemContainer.containerType.spaceItems._0 = <space id>`. `WORK-PIN` children are `["F-DOCS", "T-BOARD"]`. `F-DOCS` (`data: {"list": {}}`, `title: "Docs"`) has children `["T-SPEC", "T-NOTES"]`. In the flat `items` list, `T-NOTES` is placed **before** `T-SPEC` and `T-BOARD` before `F-DOCS`, so a walk in flat-list order fails. `T-BOARD` has `title: "My Board"` and `savedTitle: "Board — Example"`, so the rename wins. `WORK-UNPIN` holds two tabs, and `HOME-PIN` holds one tab.
  - A Favorites container `FAV-DEF` (`data.itemContainer.containerType.topApps._0 = {"default": true}`) holding two tabs. `topAppsContainerIDs` is `[{"default": true}, "FAV-DEF"]`.
  - Every `savedURL` is `https://<something>.example.com/…`.
- [ ] **Step 2: Write the failing tests** in `ArcSidebarParserTests.swift`:
  - `basicSpacesInSidebarOrder`: `spaces.map(\.title) == ["Work", nil]`; both `.default`.
  - `basicPinnedTreeFollowsChildrenIds`: Work pinned == `[.folder(title: "Docs", children: [.tab(spec), .tab(notes)]), .tab(ArcTab(url: …, title: "My Board"))]`, with the exact URLs from the fixture.
  - `basicUnpinnedAndFavorites`: Work unpinned has 2 tabs in fixture order; `favorites[.default]` has 2 tabs.
  - `basicIconAndColour`: Work `emoji == "💼"`, `colorHex == "#5C6BF2"` (0.36→92→5C, 0.42→107→6B, 0.95→242→F2; round to nearest). `S-2` `emoji == nil`, `colorHex == nil`.
  - `rejectsNonJSON`: `parse(Data("nope".utf8))` throws `ArcImportError.notJSON`.
  - `rejectsMissingSidebar`: `parse(Data(#"{"sidebar":{"containers":[{"global":{}}]}}"#.utf8))` throws `.noSidebar`.
  - `rejectsOversizeFile`: `Data(count: ArcSidebarParser.maximumFileSize + 1)` throws `.fileTooLarge`, checked before decoding.
- [ ] **Step 3: Run** `swift test --package-path Packages/StaveCore --filter ArcSidebarParserTests` → FAIL (types missing).
- [ ] **Step 4: Implement.** The container is the first element of `sidebar.containers` that is an object holding both `spaces` and `items`. Build `[id: item object]` from the object elements of `items`, ignoring the strings. Walk each container's `childrenIds` recursively, not the flat list. A child id that is missing from the map is ignored. Read the pinned and unpinned container ids from `newContainerIDs`, pairing each marker object with the string that **follows** it. Turn each item's `data` key into an `ArcNode`: `tab` → `.tab`, `list` → `.folder`, `splitView` → `.split` of its tab children (any non-tab child is dropped), anything else → `.unsupported(kind: <the data key>, title: item.title)`. A tab's title is the item's `title` when it is a non-null string, otherwise `savedTitle`, otherwise `""`. A tab with no `savedURL` becomes `ArcTab(url: "", title: …)`, and the planner skips it. Keep the walk under `maximumDepth` (throw `.tooDeep`). Compute the colour per ruling 6.
- [ ] **Step 5: Run** the filter again → PASS; run the full package suite → PASS.
- [ ] **Step 6: Commit** `feat: parse Arc sidebar spaces and item trees`

### Task 2: Profiles, Favorites, legacy markers and damaged files

**Files:**
- Create: `Sources/StaveCore/ArcImport/ArcProfileNames.swift`
- Create: `Tests/StaveCoreTests/Fixtures/arc/edge-cases.json`, `Tests/StaveCoreTests/Fixtures/arc/local-state.json`
- Modify: `ArcSidebarParser.swift`, `ArcSidebarParserTests.swift`

**Interfaces:**
- Consumes: Task 1's types and parser.
- Produces: `public enum ArcProfileNames { public static func names(fromLocalState data: Data) -> [String: String] }`. It returns `[directoryBasename: name]` from `profile.info_cache.<basename>.name`, skipping entries without a string name, and returns `[:]` on any malformed input. It never throws.

- [ ] **Step 1: Write `edge-cases.json`** (synthetic). Keep the container keys in the order `items`, `topAppsContainerIDs`, `spaces` so nothing depends on key order. It contains:
  - Space `S-ACME` (`title: "Acme"`, `profile: {"custom": {"_0": {"directoryBasename": "Profile 1", "machineID": "00000000-0000-4000-8000-000000000001"}}}`) with **only** legacy `containerIDs: ["unpinned", "ACME-UNPIN", "pinned", "ACME-PIN"]`, which puts unpinned first.
  - Space `S-ODD` (`title: "Odd"`, `profile: {"something": {}}`) with `newContainerIDs` listing unpinned before pinned.
  - In `ACME-PIN`, in order:
    - Folder `L1` "Level 1" → folder `L2` "Level 2" → folder `L3` "Level 3" → tab `T-DEEP`.
    - A `splitView` with tabs `T-SA` and `T-SB`.
    - An `easel` item titled "Sketch".
    - A `welcomeToArc` item.
    - A tab `javascript:alert(1)`, a tab `JavaScript:void(0)`, a tab `file:///etc/hosts`, a tab with `savedURL: ""`, and a tab with no `savedURL` key.
    - A tab whose `title` is a long mixed-script string: 300 characters of "東京🚀Ünïcødé" repeated.
    - A tab `T-SHARED`.
  - `ACME-UNPIN` holds a splitView and one tab.
  - `S-ODD`'s pinned container lists `T-SHARED` again, and a folder `CYC` whose `childrenIds` includes `CYC` itself.
  - Favorites:
    - `FAV-P1`, whose `topApps._0` is the `Profile 1` custom marker, holds a folder "Fav Folder" with one tab, plus one plain tab.
    - `FAV-P9`, whose marker is a custom `Profile 9`, is empty.
    - `topAppsContainerIDs` lists them id first: `["FAV-P1", {custom…P1}, "FAV-P9", {custom…P9}]`. The parser must read markers from the container items.
  - Write `local-state.json` as `{"profile": {"info_cache": {"Default": {"name": "Person 1"}, "Profile 1": {"name": "Client Work"}, "Profile 2": {}}}}`.
- [ ] **Step 2: Write the failing tests:**
  - `legacyContainerIDsWithUnpinnedFirst`: Acme's pinned list starts with the `Level 1` folder and its unpinned list has 2 nodes. Odd's pinned list is read correctly from `newContainerIDs` with unpinned first.
  - `customAndUnrecognizedProfiles`: Acme `.custom(directoryBasename: "Profile 1")`, Odd `.unrecognized`.
  - `favoritesKeyedByContainerMarker`: `favorites[.custom(directoryBasename: "Profile 1")]` == `[.folder(title: "Fav Folder", …), .tab(…)]`. `favorites[.custom(directoryBasename: "Profile 9")] == []`.
  - `deepFoldersAreKeptForThePlanner`: the parser keeps all three folder levels, because flattening is the planner's job.
  - `cycleAndSharedChildImportOnce` (Review Focus 2): the parse returns. `T-SHARED` appears only under Acme, at its first position. The `CYC` folder's children do not include itself. `duplicateItems == 2`.
  - `unknownKindsAreUnsupportedNodes`: `.unsupported(kind: "easel", title: "Sketch")`, `.unsupported(kind: "welcomeToArc", title: nil)`.
  - `profileNamesFromLocalState`: `["Default": "Person 1", "Profile 1": "Client Work"]`. `names(fromLocalState: Data("x".utf8)) == [:]`.
- [ ] **Step 3: Run** the filter → FAIL.
- [ ] **Step 4: Implement.**
  - **Profile marker.** `{"default": true}` → `.default`. `{"custom": {"_0": {"directoryBasename": String}}}` → `.custom`. Anything else, or a missing marker → `.unrecognized`.
  - **Favorites.** Every root item whose `itemContainer.containerType` has `topApps` gives one Favorites list, keyed by its `topApps._0` marker. A `.unrecognized` Favorites marker is dropped.
  - **Containers.** Use `newContainerIDs` when present, otherwise `containerIDs`. In either list a marker is the object `{"pinned": …}` / `{"unpinned": …}` or the string `"pinned"` / `"unpinned"`, and the container id is the element right after it.
  - **The walk.** Keep one `visited` set across the whole parse: spaces in order, then Favorites in container order. An item already visited is skipped and counts toward `duplicateItems`.
- [ ] **Step 5: Run** the filter → PASS; full suite → PASS.
- [ ] **Step 6: Commit** `feat: parse Arc profiles, Favorites and damaged sidebars`

### Task 3: The import planner and report

**Files:**
- Create: `Sources/StaveCore/ArcImport/ArcImportPlan.swift`, `ArcImportReport.swift`, `ArcImportPlanner.swift`
- Create: `Tests/StaveCoreTests/ArcImportPlannerTests.swift`

**Interfaces:**
- Consumes: `ArcSidebar` and friends (Task 1), `ArcProfileNames` output (Task 2).
- Produces: the `ArcImportPlan.swift` and `ArcImportReport.swift` types above, and `public enum ArcImportPlanner { public static let defaultIcon = "square.grid.2x2"; public static let defaultColorHex = "#8E8E93"; public static func plan(_ sidebar: ArcSidebar, options: ArcImportOptions, profileNames: [String: String]) -> ArcImportPlan }`.

Rules the tests pin:
- **Profiles.** Ordering is the default profile first, then custom profiles in order of first appearance: spaces first, then Favorites. A custom profile with no spaces and no Favorites is dropped (ruling 2). `.unrecognized` spaces join the default profile, each adding `.unrecognizedProfile(space:)`. A custom profile becomes `.new(name: profileNames[basename] ?? basename)`.
- **Workspace names.** The space title, or "Space N" for unnamed spaces, where N counts unnamed spaces from 1 in sidebar order. The workspace `icon` is the emoji or `defaultIcon`, and `colorHex` is the parsed colour or `defaultColorHex`.
- **Pinned folders.**
  - A folder at depth 1 or 2 is kept.
  - A folder at depth ≥ 3 is dropped. Its children are spliced, in order and recursively flattened, into its parent at the folder's position. That parent is the depth-2 folder. One `.folderTooDeep(space:, folder:)` is recorded per dropped folder.
  - A `.split` becomes its tabs in place, and records `.splitView(space:, tabCount:)`.
- **Unpinned.** When `includeUnpinnedTabs` is true, unpinned tabs and split tabs become `regular` in order (splits reported as above), and folders are flattened, reported as `.folderTooDeep`. When it is false, `regular` is empty, and `.unpinnedTabs(space:, count:)` is recorded with the number of tabs that would have been imported, if > 0.
- **Essentials.** Each profile's Favorites flatten into `essentials` in order. Each folder records `.favoritesFolder(folder:)` and each split `.splitView(space: nil, …)`.
- **URL filter (ruling 1).** It applies everywhere a tab would be created. The scheme is `URL(string:)?.scheme?.lowercased()`. Anything not `http`/`https` records `.nonWebURL(space:, title:, scheme:)`, with `scheme` = the lowercased scheme or `""`. `.unsupported` nodes record `.unsupportedItem`. `duplicateItems > 0` records one `.duplicateItem(count:)`.
- **Titles and URLs** are copied verbatim (ruling: no trimming).

- [ ] **Step 1: Write the failing tests**, all on the parsed fixtures (`ArcSidebarParser.parse(arcFixture(…))`):
  - `basicPlan`:
    - One profile, `.existingDefault`.
    - Workspaces "Work" (`icon` "💼", `#5C6BF2`) and "Space 1" (`defaultIcon`, `defaultColorHex`).
    - Work pinned == `[.folder(title: "Docs", children: [spec, notes]), .tab(board)]`.
    - Regular empty, and `skipped` contains `.unpinnedTabs(space: "Work", count: 2)`.
    - Essentials 2.
  - `includeUnpinnedTabsCreatesRegularTabs`: with the option on, Work regular has 2 tabs in order and there is no `.unpinnedTabs` entry.
  - `deepFolderFlattensIntoLevelTwo`: Acme pinned starts `.folder("Level 1", [.folder("Level 2", [.tab(deep)])])`, and `flattened` contains `.folderTooDeep(space: "Acme", folder: "Level 3")`.
  - `splitViewBecomesTabsInPlace`: Acme pinned holds `T-SA`, `T-SB` adjacent where the split was. `.splitView(space: "Acme", tabCount: 2)` is recorded.
  - `nonWebURLsAreSkipped` (Review Focus 1): no planned tab anywhere has a scheme other than http/https. `skipped` contains `.nonWebURL` with schemes `"javascript"` (twice), `"file"` and `""` (twice).
  - `titlesAreKeptVerbatim` (Review Focus 5): the 300-character mixed-script title arrives byte-identical. A tab with an empty `savedTitle` and null `title` keeps `""`.
  - `profilesNamedFromLocalState`:
    - With the names map, the plan has `.existingDefault` (holding Odd, plus `.unrecognizedProfile(space: "Odd")`) and `.new(name: "Client Work")` (holding Acme, with essentials of 2 tabs and one `.favoritesFolder(folder: "Fav Folder")`).
    - With `[:]` the new profile is named "Profile 1".
    - "Profile 9" appears nowhere.
  - `unsupportedAndDuplicatesReported`: `.unsupportedItem(space: "Acme", kind: "easel", title: "Sketch")`, `.unsupportedItem(space: "Acme", kind: "welcomeToArc", title: nil)`, `.duplicateItem(count: 2)`.
- [ ] **Step 2: Run** `--filter ArcImportPlannerTests` → FAIL.
- [ ] **Step 3: Implement** as pure functions over values. No store and no Foundation I/O.
- [ ] **Step 4: Run** the filter → PASS; full suite → PASS.
- [ ] **Step 5: Commit** `feat: plan an Arc import with flattening and a report`

### Task 4: Writing the plan to the store, and the facade

**Files:**
- Create: `Sources/StaveCore/OrganizationStore+ArcImport.swift`, `Sources/StaveCore/ArcImport/ArcImporter.swift`
- Create: `Tests/StaveCoreTests/ArcImportStoreTests.swift`
- Modify: `Sources/StaveCore/OrganizationStore.swift`. Change `insertProfile` and `insertWorkspace` from `private` to internal so the import extension can call them inside its transaction. Add `withHomeWorkspace: Bool = true` to `insertProfile`. Existing callers keep `true`.

**Interfaces:**
- Consumes: `ArcImportPlan`, `ArcImportReport` (Task 3); `ensureDefaultProfile(in:)`, `insertProfile`, `insertWorkspace`, `essentials(profileID:in:)` (existing).
- Produces:
  - `extension OrganizationStore { public func importArc(_ plan: ArcImportPlan) throws -> ArcImportReport }`.
  - `public enum ArcImporter { public static func sidebarFile(home: URL) -> URL; public static func localStateFile(home: URL) -> URL; public static func run(sidebar: Data, localState: Data?, options: ArcImportOptions, into store: OrganizationStore) throws -> ArcImportReport }`.
  - The two file functions return `home/Library/Application Support/Arc/StorableSidebar.json` and `home/Library/Application Support/Arc/User Data/Local State`. `run` = parse → `ArcProfileNames.names` (or `[:]`) → plan → `importArc`.

- [ ] **Step 1: Write the failing tests** (use `makeTempStore(now:)` with a `TestClock`):
  - `importBasicFixture`:
    - Run `ArcImporter.run(sidebar: arcFixture("basic"), localState: nil, options: .init(), into: store)`.
    - The report counts are `profiles 0` (none created; the default already existed or was ensured), `workspaces 2`, `folders 1`, `pinnedTabs 4`, `essentials 2`, `regularTabs 0`.
    - `store.workspaces(profileID:)` ends with "Work", "Space 1".
    - `pinnedItems(workspaceID: work)` mirrors the plan.
    - Each pinned tab has `pinnedURL == url` and `pinnedTitle == title`.
    - `essentials(profileID:)` lists the two Favorites in order.
  - `importEdgeCasesCreatesProfile`:
    - Run with `local-state.json`.
    - `profiles()` gains "Client Work", which has exactly one workspace "Acme" and **no** "Home" (ruling 3), plus 2 Essentials.
    - The nested folder "Level 2" has `parentFolderID` = "Level 1"'s id.
  - `favoritesOnlyProfileGetsHome`: hand-build a plan with `.new(name: "Solo")`, no workspaces and one essential. After the import "Solo" has exactly one workspace, "Home", and one Essential.
  - `importAppendsAfterExistingData` (Review Focus 4):
    - Set up a store with profile "Personal", its Home workspace, one pinned tab in Home and one existing Essential.
    - Import `basic`.
    - Home is still first with the same id and its pinned tab unchanged. The existing Essential is still first in `essentials`, followed by the two imported ones. No regular tab was added to Home.
  - `regularTabsKeepArcOrder`: import `basic` with `includeUnpinnedTabs: true`. `regularTabs(workspaceID: work)` URLs are in Arc order.
  - `failedImportWritesNothing` (Review Focus 3):
    - Hand-build a plan whose workspace has `.folder(a, [.folder(b, [.folder(c, [])])])`, three levels.
    - `importArc` throws `StoreError.folderTooDeep`.
    - Afterwards `profiles()`, each profile's `workspaces`, `essentials` and `archivedTabs` equal their values from before the call.
- [ ] **Step 2: Run** `--filter ArcImportStoreTests` → FAIL.
- [ ] **Step 3: Implement `importArc`** in one `database.writer.write`.
  - **Profiles.** `.existingDefault` → `ensureDefaultProfile(in:)`. `.new` → `insertProfile(name:withHomeWorkspace: workspaces.isEmpty, in:)`.
  - **Workspaces** via `insertWorkspace` (appends).
  - **Pinned children.** Each root gets sortIndex `0, 1, 2…` in plan order (the workspace is new and empty), and folders and tabs share that sequence. A folder nested in a folder is created with `parentFolderID`. A third level throws `StoreError.folderTooDeep`, which rolls the whole transaction back. Each pinned tab is a `Slot(section: .pinned, kind: .tab, folderID:)` plus a `Tab` with `pinnedURL`/`pinnedTitle` = `url`/`title`.
  - **Regular tabs**: slots `section: .regular` with sortIndex `0, 1, 2…` in Arc order (ascending = top).
  - **Essentials**: `Slot(workspaceID: nil, section: .essential)` with sortIndex continuing after the profile's current maximum.
  - **Report.** Counts `profiles` only for `.new`. `flattened` and `skipped` are copied from the plan.
  - Every record is stamped with `now()`, and `lastActiveAt` = `now()`.
- [ ] **Step 4: Run** the filter → PASS; full suite → PASS. Also run `xcodegen generate && xcodebuild build -project Stave.xcodeproj -scheme Stave -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO` from the repo root → `BUILD SUCCEEDED`. The app doesn't use the importer yet, but must still build.
- [ ] **Step 5: Commit** `feat: write an Arc import to the store in one transaction`

---

## Outcome (2026-10-29)

Built on `feat/arc-import` (draft PR #2): all 4 tasks reviewed, then the final whole-branch review and one fix wave. There are 167 package tests, and CI is green on macOS 14 (Xcode 16.2) and 15, Debug and Release. A throwaway program outside the repo printed only counts from a dry run on Nico's real Arc file into a temporary database. Its counts matched the structure dump: 1 workspace, 1 folder, 6 pinned tabs, 2 Essentials, and 2 unpinned tabs when that option is on.

Departures from this plan, all made as rulings during execution:

- **URL check.** The scheme check no longer uses `URL(string:)`, which behaves differently on macOS 14 and 15. It reads an RFC 3986 scheme prefix, and `http`/`https` also need a non-empty authority after `//`.
- **Unrecognised Favorites.** Favorites whose profile marker is missing or unrecognised now go to the default profile's Essentials, reported as `.unrecognizedFavoritesProfile`, instead of being dropped.
- **Unresolved spaces.** Pinned and unpinned containers resolve independently: `newContainerIDs` is tried first, then `containerIDs`. A space whose contents can't be found still becomes a workspace and is reported as `.spaceContentsMissing`.
- **Unknown item kinds** that have children keep those children, in place.
- **Unpinned folders** are reported as `.unpinnedFolder`, not `.folderTooDeep`.
- **Walk order** is every pinned tree, then Favorites, then every unpinned tree, so a pinned copy of a duplicated item wins.
- **Space profile.** A missing `profile` key means the default profile, with no report. An empty space title or emoji counts as missing.
- **Nesting limit.** JSON nested more than 100 levels deep is refused as `.notJSON`. A crafted file nested about 500 levels deep crashed the parser before this guard.
- **Default profile first.** `importArc` resolves the default profile before creating any new profile.

## Carried into later plans

- **Plan 4 (window and sidebar):**
  - Offer the import on first launch when `ArcImporter.sidebarFile(home:)` exists, from the File menu, and from a file the user picks.
  - Show the `ArcImportReport` in plain words.
  - Say plainly that logins and cookies can't be imported, and point to iCloud Passwords and passkeys.
  - Warn before a repeat import (ruling 9).
  - Render a non-ASCII workspace `icon` as an emoji (ruling 5).
  - Read Arc's files through a user-granted file access if the app is sandboxed.
- **Risk:** it is unknown whether Arc deletes `StorableSidebar.json` when it shuts down on 2026-12-22. The file-picker path covers a user who copied it first. The beta's release notes should tell Arc users to keep a copy.
- **Not imported (by design for now):** per-tab emoji icons, Arc's archive (`StorableArchive.json`), Boosts, Easels, Notes, split-view layout (split view is 2.x), and the `machineID` on custom profiles.
- **Plan 4, from this plan's review:**
  - Check the file size before reading the file (an `ArcImporter` entry point that takes a URL).
  - Make report labels unambiguous when two spaces share a name, and label Favorites entries with their profile.
  - Report `.unrecognizedFavoritesProfile` only when the container actually held tabs. Arc keeps stale, empty profile containers.
- **Test debts that can wait:**
  - Pin `profile: null` → `.unrecognized`.
  - Make the doubling-folders test fail by itself, not just hang, if the visited set regresses.
  - Pin the remaining scheme-table cases (`"foo bar:x"`, `"1http://x"`, `":"`).
  - Add a test that the store's clock stamps imported records.
  - Make the order tests distinguish equal sortIndex values.
