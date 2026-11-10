# Stave Browser Basics and Release Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

> **Status: draft for Nico's review (2026-11-10).** Nothing here is built. Every choice that needs Nico is in "Open questions for Nico" at the end of the decisions. Tasks that depend on an unanswered question say so, and name the question.

**Goal:** Stave becomes a browser Nico can set as his default and live in, then a signed, notarized, self-updating public beta. Part A (browser basics) adds what every browser has and Stave still lacks: default-browser registration, history, favicons, find, zoom, print, Web Inspector, HTTP sign-in prompts, the full standard shortcut set, a real Settings window (profiles and containers included), a per-site settings panel, rolling database backups, and the review leftovers from plans 1–4. Part B (release) adds Sparkle, Developer ID signing, notarization, the Homebrew cask and the "beta is ready when" gate.

**Architecture:** Unchanged from plans 3 and 4. Rules stay in `StaveCore` with `swift test` coverage and no WebKit: host display, backup schedule, history, site values, shortcut table, settings copy. WebKit glue goes in `StaveWeb`: favicon loading, find, zoom, print, inspector, HTTP auth, the default-browser opener. The app target holds AppKit windows and thin SwiftUI views. Every label, message and enablement rule is a `StaveCore` function. Part B adds a `release/` folder modelled on Chorus's, and a Sparkle dependency in the app target only.

**Tech stack:** Swift 6 (language mode 6, package manifests at swift-tools-version 6.0), Xcode 26 (newest non-beta), macOS 15 minimum, Swift Testing, GRDB 7 (uncapped, `from: "7.0.0"`), WebKit, `ChorusEngine` pinned `exact: "1.5.36"`, SwiftUI in AppKit windows, XcodeGen. Part B adds Sparkle 2.x (MIT), `xcrun notarytool`, `hdiutil` and a Homebrew cask in `nicojan/tap`.

**Spec:** `docs/superpowers/specs/2026-10-28-stave-design.md`: "First release" items 5, 7, 8, 10 and 11 (and the parts of 1 and 9 that the carry-forwards touch), "The beta is ready when", "Apple approvals", "Dependencies on Chorus's engine", "Constraints" (distribution and privacy), "Open checks". Inputs also: roadmap entry 5 in `2026-10-28-stave-foundation.md`, and the "Outcome" and "Carried into later plans" sections of all four earlier plans.

**Stacks on PR #4.** PR #3 (plan 4) and PR #4 (plan 3) are both still drafts; `main` is at plan 2. Part A's branch, `feat/browser-basics`, starts from the head of `feat/web-layer` (`5010cc0` when this was written). Once Nico merges PR #3 and PR #4, rebase onto `main` (`git rebase --onto main <base> feat/browser-basics`) before opening this plan's PR. If PR #4 changes first, rebase onto its new head. Part B gets its own branch, `feat/release`, from Part A's head (see question 1).

## Already settled (stated as given, not reopened)

- macOS 15 is the minimum, and `ChorusEngine` stays pinned `exact: "1.5.36"` until an engine change Stave asks for comes back through a new tag.
- No page parking: WebKit suspends off-screen pages as before. Parking needs a public Chorus API (plan 3's Carried, "Engine parking").
- A reopened page asks ("‹host› wants to download a file") before it downloads. That is intended (Nico, 2026-11-04).
- Compact mode hides only the sidebar and keeps a real title bar (Nico, 2026-11-09).
- A private window takes the front browser window's profile, and the private windows of one profile share one session (Nico, 2026-11-04; checked 2026-11-10).
- ITP stays on (Nico, 2026-11-03). Compact-mode Tab past a page's last field reveals the sidebar (Nico, 2026-11-03).
- Anything Stave shares with other browsers acts the way Chrome, Safari and Firefox do. Where they disagree, Nico decides (spec, Anti-goals).

## Scope

In, Part A (browser basics), in the order the tasks run:

- Rolling database backups (plan 3's Carried; needs question 2).
- One host-display rule for `DisplayText` and `SiteHost`, and the bugs found on 2026-11-10 (listed under Task 2).
- The deferred review minors from plans 1–4: store tidy-ups, missing tests, literal strings in views, app-side leftovers.
- Default-browser registration and links from other apps (spec item 5).
- History recording and the command bar's history source.
- Favicon images in the sidebar.
- Find in page, zoom per site, print, Web Inspector.
- The full set of Safari/Chrome-standard shortcuts.
- HTTP auth prompts.
- The Settings window, with profile rename and delete, and container create, rename and delete, each deletion behind a confirmation.
- A per-site settings panel from the address field (camera, microphone, content blocking, zoom, user agent, and location and notifications once they exist).
- Downloads hardening and the prompt leftovers from plan 3.
- Site-compatibility tools: per-site user agent and "Open in Safari/Chrome" (spec item 7).
- Location permission, web notifications and passkeys, each gated as marked.

In, Part B (release): version and update feed, Sparkle, Developer ID signing, notarization, DMG, GitHub release, Homebrew cask, release notes, README and the beta gate.

Out, each with its reason:

- Page parking (settled above).
- Throwaway containers (post-beta by the spec's cut line).
- Bookmarks as a separate system, extensions, sync, split view, Glance, Boosts, Reader mode (spec non-goals for the first release).
- Import from browsers other than Arc (spec, 1.x).
- iCloud Passwords allow-list request: after the public release (spec, Apple approvals 2). Part B's last task writes it down as the next step.
- `markActive` bumping `modifiedAt` (a sync question, foundation Carried) and split-slot archiving (2.x).

### Foundation Carried items already done (dropped)

Checked against the code on 2026-11-10:

- `moveTab` item anchor and `moveFolder`: plan 4 Task 2 (`OrganizationStore+Move.swift` `MoveAnchor`, `OrganizationStore+Folders.swift` `moveFolder`).
- Window state saved as it changes: plan 4 decision 33 (`WindowSession`, saved 0.5 s after the last change by `BrowserWindowController`).
- Restored frames clamped to visible screens: plan 4 Task 4 (`Session/WindowFrameClamp.swift`, `WindowFrameRestore.swift`).
- `trimArchive` scheduled: `launchMaintenance()` runs at launch from `AppEnvironment`.
- Duplicated store helpers consolidated: `OrganizationStore+Ordering.swift` (`uncrowdedIndex`, `essentialSlots`, `requireFolder`, one `renumber`).
- `rowid` tie-breaks: every sorted read ends with `rowid`; tests added on 2026-11-10 (`f7a2c8a`).
- `deleteWorkspace` throws instead of `continue`: done in plan 4 Task 1. The guard is now unreachable (Task 2 removes it).
- Debug "Add sample tab" and `-StaveAddSampleTab` removed: plan 4 Task 12.
- A late favicon adopted as `pinnedFaviconURL`: plan 3 Task 3 (`updateNavigation`, using `Tab.isSamePage`).

Still open from the foundation: the `.debug` data-folder mapping if a third bundle ID appears (question 23); `markActive` and split slots (out, above).

## Global Constraints

- macOS deployment target `15.0`; `SWIFT_VERSION` `6.0`; strict concurrency complete; manifests at swift-tools-version 6.0. CI runs on macos-15 and macos-26 with the newest installed Xcode that isn't a beta or release candidate. Check each new WebKit or AppKit symbol's availability against macOS 15. Never nest `try #require` inside `#expect`; hoist it to a `let`.
- `ChorusEngine` stays `exact: "1.5.36"`. Engine code is never edited here. An engine change goes to Chorus as its own work, comes back through a tag, and Stave moves its `exact:` pin only after reading ENGINE.md's "Engine API changes by release".
- Bundle ID `com.nicojan.Stave` never changes; Debug is `com.nicojan.Stave.debug` with `Application Support/Stave-debug`. No store, backup, favicon cache or history is ever opened through a framework default path. `WKWebsiteDataStore.default()` is never used.
- Never lose user data. Nothing is deleted without passing through the archive, except a profile or container deletion the user confirmed. Backups, history clearing and favicon-cache pruning delete only their own files or rows, never a tab, pinned tab, workspace or archived tab.
- Data from outside (a link from another app, an opened HTML file, a favicon, an HTTP auth challenge) is hostile input: checked, capped, and never fatal.
- Logic goes in `StaveCore` with tests; WebKit code goes in `StaveWeb`; views hold layout, focus and animation state only. Every label, message, shortcut and menu enablement rule is a `StaveCore` function.
- The private window writes nothing to disk: no history, no favicon cache files, no site values, no backup rows that name it.
- Test fixtures use `example.com`, `example.org` and `example.net`, invented titles, or local HTML strings. IDN tests use invented names (`bücher.example`, `xn--bcher-kva.example`). Package tests never touch the network.
- By-hand checks follow "The by-hand check" in plan 4 (Debug app, a throwaway folder under `/private/tmp`, literal path, `-StaveDataDirectory <folder>/data -StaveArcHome <folder>/home -StaveSeedSample`). Screenshots are named `plan5-task<N>-<what>.png` and stay in the session scratchpad. Send keystrokes only after confirming Stave is frontmost in the same osascript call, and never click outside Stave.
- Every new WebKit delegate method is added to `DelegateSelectorTests`' hand-kept list (plan 3's Carried).
- Every new way the user opens a page sets `PageRequest.openedByUser` (plan 3's Carried): links from other apps, opened files, history results, reopen-closed-tab.
- Licence MIT. Copy no code from Zen (MPL-2.0), Ora (GPL-2.0) or Nook (GPL-3.0); behaviour reference only. MIT code may be adapted with attribution in `THIRD_PARTY_NOTICES.md` (Sparkle goes there in Part B).
- Commits: `<type>: <description>`. Stage named paths only, never `git add -A`. Never `--no-verify`, never force-push. Markdown is never hard-wrapped. After adding or removing app files, run `xcodegen generate` and commit `Stave.xcodeproj/project.pbxproj` with the task.
- Schema changes: each task that needs a table takes the next free migration name in task order (`v5`, `v6`, …), adds it to `PathsAndDatabaseTests`' table list, and keeps the newer-schema refusal test passing.

## Start now (Nico, outside the tasks)

These have lead time and need Nico's accounts, so they run alongside Part A:

1. **[Name]** Run the USPTO check on "Stave" (spec, Apple approvals 0). Nothing goes to Apple before it, since the bundle ID can never change once Apple approves it.
2. **[Apple account]** After the name check, request the `com.apple.developer.web-browser.public-key-credential` entitlement for `com.nicojan.Stave` (spec, Apple approvals 1). Zen 1.24b carries it with a Developer ID provisioning profile (checked 2026-11-04), so Developer ID is possible. Apple's criteria and timeline are still unknown (spec, Open checks).
3. **[Apple account]** Confirm the Developer ID Application certificate and notarytool credentials Chorus uses are available for Stave (same team, `3CY4DX3K45` in Chorus's `release/ExportOptions.plist`).
4. Answer the open questions below. Tasks that wait on an answer say which.

## Decisions (my call unless noted; Nico can overturn any)

Data safety:

1. **Backups are copies of the whole database made with GRDB's online backup** (`DatabaseReader.backup(to:)`), into `<data folder>/Backups/`. One at launch, one every hour while Stave runs, and one before any schema migration. Keep the 10 newest hourly copies and the newest copy of each of the last 3 days. Reason: the archive guards only against the user's own deletions, not against a Stave bug writing bad rows (plan 3's Carried; Nico confirms, question 2). A copy is written under a temporary name, checked with `PRAGMA quick_check`, then renamed, so a half-written copy is never kept. Pruning deletes only files in `Backups/` whose names match Stave's own pattern.
2. **Backups never block the main thread and never stop Stave.** A failed backup is logged and retried at the next hour; after three failures in a row the Settings window shows "Stave couldn't back up your data" with the reason. Reason: a backup failure must be visible but must not cost the user their session.

Display text (the 2026-11-10 findings):

3. **One host rule, `HostText`, for every place that shows or keys a host.** It lowercases the host, strips one leading `www.`, and handles IDN per question 4. `DisplayText.address`, `DisplayText.monogram` and `SiteHost.normalized` all call it. Reason: plan 3's `SiteHost` and plan 4's `DisplayText` drifted apart (one lowercases, one doesn't; neither handles punycode).
4. **A monogram is one character.** It comes from the trimmed source (host, else title), uppercased, and the first `Character` of the uppercased form is kept, so "ßeta" gives "S" and "ﬁsh" gives "F". Leading spaces and newlines are skipped, so "  lead" gives "L". Reason: a tile shows one letter; multi-letter uppercase and blank monograms are bugs.
5. **Unreachable guards go.** `switchWorkspace(number:)` checks `number >= 1` before subtracting, so `Int.min` can't overflow (unreachable today, but the guard is free). `deleteWorkspace`'s missing-slot guard can never fire (the tabs are fetched by those very slot IDs) and is removed, with a comment saying why.

Default browser and links:

6. **Stave declares `http`, `https` and HTML files** (`public.html`, `public.xhtml`) in `Info.plist`, and Settings ▸ General has "Make Stave your default browser", which calls `NSWorkspace.setDefaultApplication(at:toOpenURLsWithScheme:)` for `http` (macOS asks the user to confirm and sets `https` with it). Stave never sets itself as default without that button. `mailto:` and other schemes are not declared and go to their own apps (spec item 5).
7. **A link from another app** goes through `NavigationPolicy.decide(_, isMainFrame: true, source: .typed)` and opens per question 14, at the top of the target workspace's regular tabs (`NewTabOrigin.externalApp`), with `openedByUser = true`. A refused link opens a new tab that shows the refused panel and loads nothing, so the user sees why.
8. **The Debug build shows as "Stave Debug" in the default-browser list** (`CFBundleDisplayName` for Debug only; the bundle ID is unchanged). Reason: two entries both named "Stave" would let Nico pick the Debug build by mistake. Task 5 checks that `capture-window.swift` and `ax-dump.sh` still find the app by name.

History and favicons:

9. **History is one row per visit** (`historyVisit`: profile, URL, title, visited-at), written on a main-frame commit and updated when the title arrives, never in a private window. Repeat visits to the same URL within 30 minutes update the last row rather than adding one. The command bar ranks history after open tabs and before archived tabs, newest first among equals. History > Clear History… offers Safari's ranges (the last hour, today, today and yesterday, all history) and removes history rows only, never the archive or tabs. Retention follows question 15.
10. **Favicons are fetched without cookies and cached on disk.** `FaviconLoader` in `StaveWeb` fetches the URL the page reported through an ephemeral `URLSession` (no cookies, no credentials, `https` and `http` only, redirects to other schemes refused), caps the body at 512 KB, decodes it with `NSImage` off the main thread, scales it to 32 × 32 pt @2x, and stores a PNG in `<data folder>/Favicons/<sha256 of URL>.png`. The cache keeps at most 2,000 files, oldest-used first out. Private windows keep favicons in memory only. A failure falls back to the monogram. Reason: a favicon request with the profile's cookies would tell a site the user has a tab open, which no mainstream browser does in a background fetch.

Page tools:

11. **Find** uses WKWebView's public `find(_:configuration:completionHandler:)` with a Stave find bar above the page (⌘F, ⌘G, ⇧⌘G, ⌘E, Escape). Task 8's first step is a spike: if `performTextFinderAction(_:)` gives the system find bar with a match count on macOS 15 and 26, use it instead. Either way, the bar's strings and enablement come from `StaveCore`.
12. **Zoom** is per site and per profile, through `WKWebView.pageZoom`: ⌘+ / ⌘- step through Safari's levels (50, 75, 85, 100, 115, 125, 150, 175, 200, 250, 300 %), ⌘0 resets. A non-default level is stored as a site value (Task 9's table) and applied on every main-frame commit to that host. Private windows keep zoom in memory.
13. **Print** uses `WKWebView.printOperation(with:)` with the page's title as the job name. ⌘P. A blank tab or a failure panel has nothing to print (menu disabled).
14. **Web Inspector:** every page is created with `isInspectable = true` only while Settings ▸ Advanced ▸ "Show features for web developers" is on (off by default, as in Safari). With it on, Develop ▸ Show Web Inspector (⌥⌘I) is enabled. How the in-app inspector opens is question 21.
15. **HTTP auth** (Basic, Digest, NTLM) shows a sheet on the tab: "‹host› wants you to sign in", with the realm shown as the site's own words, a user name field and a password field. Cancel cancels the challenge. Stave stores nothing (no password manager). A challenge for a page not shown waits until its tab is shown, like the camera question. A challenge from a cross-site subframe names the frame's host, not the top page's. Server trust challenges keep plan 3's handling (no "proceed anyway").

Shortcuts:

16. **Shortcuts come from one table, `StandardShortcuts`, in `StaveCore`,** with a test that no two menu items share a key. The table adds, with Safari's meaning: ⌘F, ⌘G, ⇧⌘G, ⌘E (find); ⌘+, ⌘-, ⌘0 (zoom); ⌘P (print); ⌥⌘I (Web Inspector); ⌘Y (history, question 16); ⌥⌘L (downloads popover); ⇧⌘T (reopen the last closed tab from the archive); ⌃Tab, ⌃⇧Tab, ⇧⌘], ⇧⌘[ (next and previous tab in sidebar order); ⌘1–9 (question 17); ⌘D (question 18); ⌥⌘U (Show Page Source, which opens Web Inspector's source view when web developer features are on, as in Safari's Develop menu). Existing assignments are unchanged.

Settings and site panel:

17. **The Settings window has six panes:** General (search engine, default browser, where links from other apps land, new tabs at top or bottom), Tabs (⌃1–9, compact mode, archive trim days shown read-only at 30), Profiles, Containers, Websites (every stored per-site answer and value, by host, with Remove and Remove All), Advanced (web developer features, backups status and "Show Backups in Finder"). Every control has a label from `SettingsCopy` and works with the keyboard alone.
18. **Deleting a profile** asks first, naming what goes: "Delete the profile “‹name›”? Its ‹n› workspaces, ‹n› tabs, its archive, history and website data (cookies, sign-ins) will be deleted. This can't be undone." Delete is the destructive button, not the default. Windows showing that profile switch to the first remaining profile first. The data stores are removed with `WKWebsiteDataStore.remove(forIdentifier:)` only after the store rows are gone and no page uses them. The last profile can't be deleted (`.lastProfile`). The private session of that profile closes first.
19. **Containers:** Settings lists named containers with Create, Rename and Delete. Delete keeps the store's rule: refused while any tab or archived tab uses it, with "‹n› tabs still use “‹name›”. Close them or move them out first." When allowed, it asks first, naming the website data that goes. Throwaway containers stay post-beta.
20. **The per-site panel** opens from the address field (a site button beside it) and from View ▸ Settings for This Website. It shows camera, microphone, content blocking, zoom, user agent, and location and notifications once those exist, each with Ask / Allow / Block (or its own values) and "Reset This Site". It edits the same rows Settings ▸ Websites shows.

Downloads and prompts (plan 3's leftovers, matching mainstream behaviour):

21. **Background-tab dialogs wait** (R15 reversed): `alert`, `confirm` and `prompt` from a tab not shown are held until it is shown, then asked, as Chrome and Firefox do with tab-modal dialogs. A navigation or close resolves them (false or nil).
22. **The external-app question becomes tab-scoped:** it hides when its tab is not shown and comes back when it is, and it is dropped when the page navigates or moves to another window ("Bring It Here"), so a stale sheet can't open a link for a page the window no longer shows.
23. **The downloads popover** sits fully inside the window with one material, and the quarantine record carries the source page URL and the download URL (Gatekeeper then names the site).

Site compatibility:

24. **Per-site user agent:** Default, Safari, or Chrome on Mac, stored as a site value and applied as `customUserAgent` before each main-frame navigation to that host. The Chrome string names the current stable major version, kept in one constant that Part B's release checklist bumps.
25. **"Open in Safari" and "Open in Chrome"** appear in the page's View menu and the site panel only when that app is installed (`NSWorkspace.urlForApplication(withBundleIdentifier:)`). They pass the current URL and nothing else.

Release (Part B):

26. **Distribution copies Chorus's setup** (spec): a notarized, stapled DMG attached to a GitHub release tagged `vX.Y.Z`, a signed `docs/appcast.xml`, Sparkle 2.x in the app target, and a cask `stave.rb` in `nicojan/tap` (repo `nicojan/homebrew-tap`). Sparkle's update check sends no identifier. Whether it is counted, and through which feed URL, is question 25; the README says plainly what happens.
27. **The Sparkle feed URL chosen for the first public build is permanent.** Chorus learned that every build ever shipped asks its first feed forever. So Part B picks the final URL before the first signed build, never a temporary one.
28. **Signing and notarizing run from a local script, not CI.** No certificate or notary password goes into GitHub. CI keeps building Debug and Release unsigned.

## Open questions for Nico

Each has my recommendation first, then the alternatives. Marks: **[Apple]** needs Nico's Apple account, **[TCC]** changes what macOS asks the user, **[Chorus]** needs an engine change made in Chorus and pinned back through an exact tag (Stave stays on 1.5.36 until then).

1. **How to split plan 5.** *Recommend:* two parts in this file now, built as two branches and PRs: Part A (browser basics, Tasks 1–20) then Part B (release, Tasks 21–25). Part A is useful alone: it makes Stave a default browser Nico can live in, so the two-week daily-driver clock in the beta gate can start when Part A lands, while Part B is built. Once you agree, Part B moves to its own file (`2026-11-10-stave-release.md`). *Alternatives:* one plan and one PR (very large to review); three parts (A1 data safety and tidy-ups, Tasks 1–4; A2 browser basics; B release).
2. **Rolling backups.** *Recommend:* yes, as in decisions 1–2 (online backup at launch, hourly and before a migration; keep 10 hourly and 3 daily). *Alternatives:* no backups (Time Machine only); more copies (Zen keeps 20); daily only.
3. **Restoring a backup.** *Recommend:* no in-app restore for the beta; the README gives the steps (quit, move `stave.sqlite` aside, copy a backup in its place), and Settings ▸ Advanced shows the folder. *Alternatives:* a "Restore from Backup…" command that first backs up the current file, then swaps and relaunches.
4. **IDN hosts (`xn--` punycode) in the address field and monograms.** Today `bücher.example` shows as `xn--bcher-kva.example` with monogram "X". *Recommend for the beta:* the address field keeps showing punycode (safe against look-alike hosts), and the monogram uses the title when the host's first label starts with `xn--`. Later, decode to Unicode with a same-script check, as Chrome and Safari do. *Alternatives:* write an RFC 3492 decoder now and show Unicode when every label is in one script; show Unicode always (open to look-alike spoofing).
5. **A folder with a blank or whitespace-only title** reads to VoiceOver as ", folder, open, 0 items". *Recommend:* such a folder shows and reads as "Untitled Folder" (as Finder names new folders); creating or renaming to a blank name keeps the old name (or "Untitled Folder" for a new one); an Arc import keeps the blank title stored and shows "Untitled Folder". *Alternatives:* store "Untitled Folder" in place of the blank title on import and rename; drop the title from the label and say "folder" first.
6. **`https://user@host` links** (plan 3 decision 9). *Recommend:* keep opening them as other browsers do, with the address field showing only the real host. *Alternatives:* refuse them; open with a warning sheet.
7. **A several-downloads question that can't be asked** (another sheet up, tab hidden). Today it refuses the rest of the document's downloads. *Recommend:* refuse only that one download, so the next one asks again, which matches Chrome's per-request behaviour. *Alternatives:* keep refusing the rest of the document; hold it until the tab is shown, like the camera question.
8. **Dropping the selected tab on another workspace's icon.** Today the window stays and selects a neighbour. *Recommend:* keep it (the window stays where the user is working). *Alternatives:* the window follows the tab to its new workspace.
9. **A drifted pinned tab or Essential that is unpinned or restored.** Today its drifted page is archived so nothing is lost. *Recommend:* keep archiving (never lose data). *Alternatives:* refuse the unpin until it's reset; ask.
10. **Staying open with no windows.** Today closing the last window quits. Safari, Chrome and Firefox all stay open on macOS. *Recommend:* stay open, as they do; the Dock icon or ⌘N opens a window, and a link from another app opens one. This also fixes the Dock-reopen-with-only-Settings-open case. *Alternatives:* keep quitting.
11. **Remember for Don't Allow, once the site panel exists** (plan 3, Nico's 2026-11-04 answer). *Recommend:* yes: Remember keeps Block as well as Allow, and the panel shows and clears both, as all three browsers do. *Alternatives:* keep remembering only Allow.
12. **The one-frame layout change while toggling compact mode** (plan 4's "Compact mode, sidebar only"). *Waits on Nico's by-hand check.* *Recommend:* fix it only if Nico sees a flash; the fix passes the compact layout into `BrowserWindowView` so the style and the layout change in one turn (now possible, since `feat/web-layer` holds both changes). *Alternatives:* fix it anyway; leave it.
13. **Opening a local HTML file** (spec item 5 says Stave registers for HTML files, but plan 3's policy refuses every `file:` URL). *Recommend:* a new `NavigationSource.openedFile`, used only for a file the user opened in Finder or with File ▸ Open File… (⌘O); it loads with `loadFileURL(_:allowingReadAccessTo:)` and read access to that file only; links from it to other `file:` URLs stay refused; a stored or restored `file:` tab still shows the refused panel (it doesn't reload by itself after a restart). *Alternatives:* read access to the file's folder, as Safari does (pages that load sibling images work); drop HTML files from the spec.
14. **Where a link from another app lands.** The spec says a chosen profile and workspace, default the last used. *Recommend:* the last-active browser window; if it is on another workspace of the target profile it switches there; if no window shows the target profile, a new window opens on it; the tab goes to the top of regular tabs and is selected. *Alternatives:* always a new window; a small Little-Arc-style window (post-beta).
15. **History retention.** Safari keeps one year, Chrome 90 days. *Recommend:* Safari's one year, with Safari's choices in Settings (one day, one week, two weeks, one month, one year, manually). *Alternatives:* 90 days; no setting.
16. **A history view.** *Recommend:* for the beta, history in the command bar plus History > Clear History…; ⌘Y opens a searchable History window in Part A only if time allows, else just after the beta. *Alternatives:* build the History window now; no ⌘Y until later.
17. **⌘1–9.** Safari and Chrome select the nth tab, and ⌘9 the last. *Recommend:* ⌘1–8 select the nth tab in sidebar order (Essentials, then visible pinned tabs, then regular tabs), ⌘9 the last. *Alternatives:* count regular tabs only; leave ⌘1–9 unassigned.
18. **⌘D** (Safari: Add Bookmark; Chrome: Bookmark This Tab). Stave's bookmarks are pinned tabs. *Recommend:* ⌘D pins the selected tab (or unpins it when already pinned). *Alternatives:* leave unassigned.
19. **Location permission. [TCC]** Plan 3 found that WebKit asks through private SPI on macOS. *Recommend:* Task 17 starts with a spike on macOS 15 and 26. If the only route is WebKit's private delegate method, use it behind `responds(to:)` (direct distribution allows it) with Stave's own sheet, the same per-site rules as the camera, `NSLocationUsageDescription` and the `com.apple.security.personal-information.location` entitlement (macOS will ask the user too). *Alternatives:* deny location for the beta and say so; wait for a public API.
20. **Web notifications. [Chorus] [TCC]** *Recommend:* ask Chorus for engine change 1 (a public way to install the notification bridge on any `WKUserContentController`, handler name and JS globals configurable), then move the pin; Stave adds per-site permission and macOS's notification permission. Until the tag exists, Task 18 waits and the beta ships without web notifications. *Alternatives:* Stave writes its own small bridge (no engine change, but two copies of the same logic); notifications after the beta.
21. **How Web Inspector opens.** `isInspectable` (public) makes pages inspectable from Safari's Develop menu. An in-app inspector and "Inspect Element" in the page menu need WebKit's private `developerExtrasEnabled` preference. *Recommend:* with "Show features for web developers" on, set both, so ⌥⌘I and Inspect Element work inside Stave, as in Safari. *Alternatives:* public API only (inspect from Safari's Develop menu).
22. **Keeping the downloads list across restarts.** Plan 3 keeps it in memory. Safari, Chrome and Firefox keep it. *Recommend:* keep it per profile in the database (never for private windows), clearing finished rows by the same ranges as history. *Alternatives:* keep it in memory.
23. **A third bundle ID for betas** (foundation Carried: the `.debug` data-folder mapping). *Recommend:* no beta bundle ID; the beta is the normal `com.nicojan.Stave` app at a 0.x version, so the mapping and the passkey identity stay as they are. *Alternatives:* `com.nicojan.Stave.beta` with its own data folder (a separate identity for Apple's passkey and Passwords approvals).
24. **The Sparkle signing key.** *Recommend:* a new EdDSA key for Stave, backed up like Chorus's, so a leak of one doesn't cover both apps. *Alternatives:* reuse the Chorus and WatchMeType key.
25. **The update feed and counting.** The spec's call: count anonymously, like Chorus, and say so. *Recommend:* `https://updates.nicojan.com/stave/appcast.xml` through the same Cloudflare Worker pattern from the very first build (decision 27), passing through `docs/appcast.xml` served by GitHub Pages; README states that daily checks are counted with no identifier. *Alternatives:* GitHub Pages only, no counting.
26. **The first public version number.** *Recommend:* `0.1.0` labelled "beta" in the release notes and About box, with `CURRENT_PROJECT_VERSION` counting up for Sparkle. *Alternatives:* `0.9.0`; `1.0.0-beta.1`.
27. **Auto-archiving idle tabs** (spec: a setting, off by default). *Recommend:* after the beta: being off by default, nobody misses it in the beta. *Alternatives:* build it in Part A.
28. **Containers in the beta.** The spec's cut line puts containers after the beta, but nothing in the app can create a named container yet, so deletion has nothing to delete. *Recommend:* the small Settings pane in decision 19 (create, rename, delete), since "New Tab in ‹container›" already exists. *Alternatives:* hide containers until after the beta.
29. **Passkeys before the entitlement arrives. [Apple]** *Recommend:* a plain notice at first run and on a passkey request: "Passkeys need Apple's approval for Stave, which hasn't arrived yet. Use the Passwords app to copy sign-ins for now." Once granted, Task 19 adds the entitlement and provisioning profile. *Alternatives:* no notice.

## Review Focus

1. **A backup never touches the live database or anything outside `Backups/`.** A failed or half-written copy leaves no file under a final name; pruning with unrelated files in `Backups/` (`notes.txt`, `stave-old.sqlite`) leaves them alone. Tests: Task 1 `pruneKeepsOnlyOwnFiles`, `failedCopyLeavesNoFinalFile`.
2. **A link from another app with a hostile scheme or a `file:` URL** (`javascript:alert(1)`, `file:///etc/hosts`, `data:text/html,x`, a 100,000-character URL) never loads as a page; a `file:` URL loads only through the opened-file path (question 13) with read access to that file only. Tests: Task 5 `externalLinksPassThePolicy`, `openedFileReadsOnlyItself`.
3. **Deleting a profile or container** asks first, removes its data stores only after its rows are gone and no live page uses them, and refuses the last profile and a container still used by a tab or an archived tab. Tests: Task 12 `profileDeletionNamesWhatGoes`, `storesRemovedOnlyAfterRows`, `containerInUseRefusedWithCount`.
4. **History is never written for a private window, and Clear History removes only history.** Tests: Task 6 `privateVisitsNeverStored`, `clearHistoryLeavesArchiveAndTabs`.
5. **A hostile favicon** (2 GB response, HTML instead of an image, a redirect to `file:`, a 1 × 100,000 image, a slow trickle) is capped, never fetched with cookies, and falls back to the monogram without blocking the main thread. Tests: Task 7 `faviconBodyCapped`, `faviconRedirectToFileRefused`, `faviconRequestCarriesNoCookies`.
6. **An HTTP auth challenge names the real host of the frame that asks**, never the top page's when they differ, and a cancelled sheet sends no credentials. Tests: Task 11 `authNamesTheAskingFrame`, `cancelSendsNothing`.

---

## File structure

```
Packages/StaveCore/Sources/StaveCore/
├── Database/StaveDatabase.swift            # T6 v5 historyVisit; T9 v6 siteValue; T14 v7 downloadRecord (question 22)
├── Database/BackupPolicy.swift             # T1: names, schedule, which copies to keep
├── Database/DatabaseBackups.swift          # T1: the online copy, off the main actor
├── Sidebar/HostText.swift                  # T2: one host rule (lowercase, www., IDN)
├── Sidebar/DisplayText.swift               # T2: monogram and address through HostText
├── Sidebar/SidebarRows.swift               # T2: blank folder label (question 5)
├── Web/SiteSettings.swift                  # T2: SiteHost through HostText
├── Window/PageChromeText.swift             # T4: "Loading", "n percent", "No tab selected", content-blocking enablement
├── Links/ExternalOpen.swift                # T5: link-from-another-app routing (question 14)
├── OrganizationStore+History.swift         # T6
├── History/HistoryRanking.swift            # T6: command bar source
├── Web/FindState.swift                     # T8
├── Web/ZoomLevels.swift                    # T9
├── OrganizationStore+SiteValues.swift      # T9: zoom, user agent
├── Shortcuts/StandardShortcuts.swift       # T10
├── Web/AuthChallenge.swift                 # T11
├── Settings/SettingsCopy.swift             # T12
├── Settings/DeletionCopy.swift             # T12
├── Web/SitePanelModel.swift                # T13
├── Web/DownloadList.swift                  # T14 (hardening)
├── Web/UserAgent.swift                     # T16 (per-site choices)
Packages/StaveCore/Sources/StaveWeb/
├── FaviconLoader.swift                     # T7
├── PageTools.swift                         # T8, T9: find, zoom, print, inspector
├── PageDelegate+Auth.swift                 # T11
├── PageDelegate+Location.swift             # T17
Stave/App/
├── AppDelegate+Links.swift                 # T5 (also moves private-window routing out of AppDelegate, T4)
├── Updater.swift                           # T21
Stave/Views/
├── Content/FindBar.swift                   # T8
├── Content/AuthSheet.swift                 # T11
├── Settings/SettingsView.swift             # T12 (panes)
├── Settings/ProfilesPane.swift, ContainersPane.swift, WebsitesPane.swift, AdvancedPane.swift   # T12
├── Sidebar/SitePanel.swift                 # T13
Stave/Info.plist                            # T5 URL and document types; T17 location; T21 SUFeedURL, SUPublicEDKey
release/                                    # T22–T23: DISTRIBUTION.md, ExportOptions.plist, release.sh, homebrew/stave.rb
docs/appcast.xml                            # T22
THIRD_PARTY_NOTICES.md, README.md           # T21, T24
```

---

# Part A: browser basics

### Task 1: Rolling database backups (waits on question 2)

**Files:**
- Create: `Sources/StaveCore/Database/BackupPolicy.swift`, `Sources/StaveCore/Database/DatabaseBackups.swift`; `Tests/StaveCoreTests/BackupPolicyTests.swift`, `Tests/StaveCoreTests/DatabaseBackupsTests.swift`
- Modify: `Database/StaveDatabase.swift` (a hook to copy before migrating), `Stave/App/AppEnvironment.swift`

**Interfaces:**
- Consumes: `StaveDatabase.writer`, `StavePaths`.
- Produces:
  - `public enum BackupPolicy { static let folderName = "Backups"; static func fileName(at: Date) -> String` (`stave-YYYYMMDD-HHMMSS.sqlite`, UTC) `; static func date(fromFileName: String) -> Date?` (nil for anything not Stave's pattern) `; static func toDelete(existing: [Date], now: Date, hourly: Int = 10, dailyDays: Int = 3) -> [Date]; static let interval: TimeInterval = 3600 }`
  - `@MainActor public final class DatabaseBackups { init(database: StaveDatabase, folder: URL, now: @escaping () -> Date); func backUpNow() async -> Result<URL, BackupError>; func start(); func stop(); private(set) var consecutiveFailures: Int }`
  - `StaveDatabase.open(at:backupBeforeMigrating:)`: when a migration is pending and the file already has data, copy it to `Backups/` first; if that copy fails, open fails with `StoreError.backupFailed` and the file is untouched.

- [ ] **Step 1: Write failing tests**
  - `fileNamesRoundTrip`: `date(fromFileName: fileName(at: d)) == d` to the second; `"notes.txt"`, `"stave-old.sqlite"`, `"stave-20261110-999999.sqlite"` give nil.
  - `keepsTenHourlyAndThreeDaily`: 40 copies an hour apart over two days plus one copy on each of the 5 days before → `toDelete` leaves the 10 newest, plus the newest of each of the last 3 days.
  - `pruneKeepsOnlyOwnFiles` (Review Focus 1): a folder with Stave copies and `notes.txt`, `stave-old.sqlite` → after pruning both strangers remain.
  - `backupIsAReadableCopy`: write a profile, `backUpNow()`, open the copy read-only → the profile is there and `PRAGMA quick_check` is `ok`.
  - `failedCopyLeavesNoFinalFile` (Review Focus 1): with the folder read-only, `backUpNow()` returns a failure, no file has a final name, and `consecutiveFailures == 1`.
  - `migrationBacksUpFirst`: a v4 file opened by the current code leaves one copy in `Backups/` whose schema is v4.
- [ ] **Step 2: Run** `swift test --package-path Packages/StaveCore --filter BackupPolicyTests` and `--filter DatabaseBackupsTests` → FAIL.
- [ ] **Step 3: Implement.** Copy to `<name>.partial` in the same folder, `quick_check`, then `rename`. Run the copy off the main actor. `AppEnvironment` starts backups after launch maintenance. Settings shows the failure message from Task 12 once `consecutiveFailures >= 3`.
- [ ] **Step 4: Run** the full package suite → PASS.
- [ ] **Step 5: By-hand check:** launch with a throwaway folder; `ls <folder>/data/Backups` shows one copy; relaunch → two; `sqlite3 -readonly` on a copy lists the tables.
- [ ] **Step 6: Commit** `feat: rolling database backups`

### Task 2: One host rule and the display-text bugs

**Files:**
- Create: `Sources/StaveCore/Sidebar/HostText.swift`; `Tests/StaveCoreTests/HostTextTests.swift`
- Modify: `Sidebar/DisplayText.swift`, `Web/SiteSettings.swift` (`SiteHost`), `Sidebar/SidebarRows.swift` (`SidebarLabels.folder`), `Window/BrowserWindowModel.swift` (`switchWorkspace(number:)`), `OrganizationStore.swift` (`deleteWorkspace`); `Tests/StaveCoreTests/SidebarRowsTests.swift`, `WebStoreTests.swift`, `BrowserWindowModelTests.swift`

**Interfaces:**
- Produces: `public enum HostText { static func host(of url: String) -> String?` (lowercased, `www.` stripped once, nil when empty) `; static func isPunycode(_ host: String) -> Bool` (any label starts with `xn--`) `}`. `DisplayText.monogram`, `DisplayText.address` and `SiteHost.normalized` call it. `SidebarLabels.untitledFolder = "Untitled Folder"` (question 5).

- [ ] **Step 1: Write failing tests** (each one fails on today's code):
  - `uppercaseWWWIsStripped`: `DisplayText.address(for: "https://WWW.Example.com/a") == "example.com"`; `monogram` of that URL is `"E"` (today `"W"`).
  - `monogramIsOneCharacter`: titles `"ßeta"` → `"S"` (today `"SS"`), `"ﬁsh"` → `"F"` (today `"FI"`).
  - `monogramSkipsLeadingWhitespace`: title `"  lead"` → `"L"` (today `" "`); title `"   "` with no URL → `"?"`.
  - `punycodeMonogramUsesTitle` (question 4, recommended answer): URL `https://xn--bcher-kva.example`, title `"Bücher"` → `"B"` (today `"X"`); `address` stays `"xn--bcher-kva.example"`.
  - `siteHostAndDisplayAgree`: for a table of URLs (upper case, `www.`, port, user info, IPv6, punycode), `SiteHost.normalized(u)` equals `HostText.host(of: u)` minus any port.
  - `blankFolderLabel` (question 5): titles `""` and `"  "` → `"Untitled Folder, folder, open, 0 items"`.
  - `switchByNumberAtIntMin`: `switchWorkspace(number: Int.min)` and `Int.max` change nothing and don't trap.
- [ ] **Step 2: Run** `--filter HostTextTests`, `--filter SidebarRowsTests`, `--filter WebStoreTests`, `--filter BrowserWindowModelTests` → the new tests FAIL.
- [ ] **Step 3: Implement** decisions 3–5. Remove the unreachable `deleteWorkspace` guard with a one-line comment (tabs are fetched by those slots' IDs). Existing `DisplayText` and `SiteHost` tests pass unedited.
- [ ] **Step 4: Run** the full package suite → PASS.
- [ ] **Step 5: Commit** `fix: one host rule for display and site keys, and one-letter monograms`

### Task 3: Store tidy-ups and missing tests from plans 1–4

**Files:**
- Modify: `OrganizationStore.swift`, `OrganizationStore+ArcImport.swift`, `OrganizationStore+Imports.swift`, `Window/BrowserWindowModel.swift`; tests across `StaveCoreTests` and `StaveWebTests`

**Interfaces:**
- Produces: no new public API. Removes dead `renameWorkspace` (replaced by `updateWorkspace`) and `navigateSelected` if nothing calls them (check with `command grep -rn` across `Stave/` and both packages first; keep and test any that has a caller). Moves the repeat-import check inside the import's own write transaction (plan 4's Carried). `deleteWorkspace` and `BrowserWindowModel.reload()` stop reading archived IDs and tab existence with `try?`: a read failure becomes `lastError`.

- [ ] **Step 1: Write failing tests** (plans 2, 3 and 4 listed them):
  - `repeatImportCheckedInsideTheTransaction`: two imports started together from the same file write one import and refuse the other.
  - `deleteWorkspaceWithPinnedInFolder` archives the folder's tabs.
  - `reloadReportsAReadFailure`: a store whose read throws sets `lastError` and keeps the last snapshot.
  - From plan 3's "Missing tests": the unique `(profileID, host, key)` index; a v3 file has no `siteSetting` table before migrating (control); `MAILTO:`, `ABOUT:BLANK` and typed `data:` through `NavigationPolicy`; flush resetting the recorder's throttle clock; same-state commit; the idle-plus-overflow union in `HibernationPolicy`; `#expect(ready)` gets a failure message; the `EngineLinkTests` 60 s timeout task is cancelled.
  - From plan 2's "can wait": `profile: null` → `.unrecognized`; the scheme-table cases `"foo bar:x"`, `"1http://x"`, `":"`; the store clock stamps imported records; the doubling-folders test fails by itself rather than hanging.
- [ ] **Step 2: Run** the full suite → the new tests FAIL where the code is missing, PASS where they only pin behaviour (note which in the commit body).
- [ ] **Step 3: Implement.** Remove the unused `StaveWebTests` dependency on `StaveCore` only if the build still passes.
- [ ] **Step 4: Run** the full package suite and both app builds → PASS.
- [ ] **Step 5: Commit** `refactor: store tidy-ups and the tests deferred from plans 1-4`

### Task 4: Strings out of views and app-side leftovers

**Files:**
- Create: `Sources/StaveCore/Window/PageChromeText.swift`, `Stave/App/AppDelegate+Private.swift`; `Tests/StaveCoreTests/PageChromeTextTests.swift`
- Modify: `Stave/Views/Content/PageContentView.swift`, `TabPlaceholderView.swift`, `Stave/Views/Settings/SettingsView.swift`, `Stave/App/AppDelegate.swift`, `Stave/App/AppMenuState.swift`, `Window/BrowserWindowModel.swift`, `Window/PageMenuState.swift`

**Interfaces:**
- Produces: `PageChromeText.loadingLabel` ("Loading"), `progressValue(_ fraction: Double) -> String` ("‹n› percent", clamped 0–100, NaN → "0 percent"), `noSelection` ("No tab selected"), `dataNotOpen` ("Stave's data is not open."); `PageMenuState.contentBlockingEnabled(url:)` (false for `about:blank`, blank and non-web URLs; the rule moves out of the app).
- App leftovers: the ⌘N nested-sheet gate bypass closed (⌘N disabled while a sheet is up, like the other window commands); a failed workspace delete leaves the window on the workspace it was on; private-window routing moves into `AppDelegate+Private.swift` so `AppDelegate.swift` drops under 400 lines; staying open with no windows per question 10.

- [ ] **Step 1: Write failing tests:** `progressValueIsClamped` (−0.2, 0.5, 1.7, NaN), `contentBlockingDisabledOnBlank`, and in `BrowserWindowModelTests` `failedDeleteKeepsTheWorkspace`.
- [ ] **Step 2: Run** → FAIL.
- [ ] **Step 3: Implement.** `command grep -rn 'Text("' Stave/Views` afterwards lists no literal user-facing string outside previews.
- [ ] **Step 4: Run** the suite and both builds → PASS.
- [ ] **Step 5: By-hand check:** ⌘N with the archive sheet up does nothing; with question 10 answered "stay open", closing the last window leaves Stave running and ⌘N opens one.
- [ ] **Step 6: Commit** `refactor: page chrome text in StaveCore and app-side leftovers`

### Task 5: Default browser and links from other apps (waits on questions 13 and 14)

**Files:**
- Create: `Sources/StaveCore/Links/ExternalOpen.swift`, `Stave/App/AppDelegate+Links.swift`; `Tests/StaveCoreTests/ExternalOpenTests.swift`, `Tests/StaveWebTests/OpenedFileTests.swift`
- Modify: `Stave/Info.plist`, `project.yml` (Debug display name), `Web/NavigationPolicy.swift` (`.openedFile`), `Settings/SettingKey.swift` (`externalLinkTarget`), `Sources/StaveWeb/PageHost.swift`

**Interfaces:**
- Produces:
  - `NavigationSource.openedFile`: allows exactly one `file:` main frame, the opened file; other sources keep refusing `file:`.
  - `public enum ExternalLinkTarget: Codable, Sendable, Equatable { case lastUsed, workspace(profileID: UUID, workspaceID: UUID) }` and `SettingKeys.externalLinkTarget` (default `.lastUsed`).
  - `public enum ExternalOpen { static func route(target: ExternalLinkTarget, windows: [WindowSummary], lastActiveWindowID: UUID?) -> ExternalRoute }` with `ExternalRoute { case existing(windowID: UUID, switchTo: UUID?), newWindow(profileID: UUID, workspaceID: UUID) }` (question 14's rule). A target whose workspace was deleted falls back to its profile's first workspace; a deleted profile falls back to `.lastUsed`.
  - `AppDelegate.application(_:open:)` handles each URL in order: web URLs through the policy as `.typed`, HTML files through `.openedFile`. A URL longer than 32,768 characters is refused with the refused panel.
  - Settings ▸ General: "Make Stave your default browser" (disabled with "Stave is your default browser" when it already is) and "Open links from other apps in" (Last used / a profile and workspace).

- [ ] **Step 1: Write failing tests**
  - `externalLinksPassThePolicy` (Review Focus 2): `javascript:alert(1)`, `file:///etc/hosts`, `data:text/html,x` as `.typed` → refused; a 100,000-character URL → refused before the policy.
  - `openedFileReadsOnlyItself` (Review Focus 2): a temp `a.html` with an `<img src="b.png">` sibling and a link to `file:///etc/hosts`: the page loads, the link is refused, and the read-access URL passed to WebKit is the file itself (or its folder, per question 13).
  - `routes`: last-used window on the right workspace → `.existing(switchTo: nil)`; on another workspace of the profile → `.existing(switchTo: w)`; no window on the profile → `.newWindow`; deleted workspace → its profile's first.
  - `restoredFileTabIsRefused`: a stored `file:` URL restored at launch still shows the refused panel.
- [ ] **Step 2: Run** `--filter ExternalOpenTests`, `--filter OpenedFileTests`, `--filter NavigationPolicyTests` → FAIL.
- [ ] **Step 3: Implement** decisions 6–8. Every opened page sets `openedByUser = true`.
- [ ] **Step 4: Run** the suite and both builds → PASS.
- [ ] **Step 5: By-hand check** (Debug build): Settings ▸ General ▸ Make default → macOS asks; choose "Stave Debug". `open https://example.com` from Terminal → a new top tab in the last-used window. `open -a "Stave Debug" <scratchpad>/a.html` → the page loads. `capture-window.swift Stave` and `ax-dump.sh Stave` still find the app (decision 8); if not, adjust the scripts, not the bundle. Afterwards Nico sets his real default browser back (his call). **Nico checks:** a link from Mail and from Slack; a link while Stave isn't running.
- [ ] **Step 6: Commit** `feat: Stave as the default browser, and links from other apps`

### Task 6: History (questions 15 and 16 set the retention and the view)

**Files:**
- Create: `Sources/StaveCore/OrganizationStore+History.swift`, `History/HistoryRanking.swift`; `Tests/StaveCoreTests/HistoryTests.swift`
- Modify: `Database/StaveDatabase.swift` (migration `v5`: `historyVisit(id, profileID → cascade, url, title, visitedAt, modifiedAt)` with an index on `(profileID, visitedAt)`), `CommandBar/CommandTypes.swift`, `CommandBar/CommandBarSearch.swift`, `OrganizationStore+CommandBar.swift`, `Sources/StaveWeb/PageHost.swift` (record on commit), `Stave/App/StaveApp.swift` (History menu), `Settings/SettingKey.swift` (`historyRetentionDays`)

**Interfaces:**
- Produces: `recordVisit(profileID:url:title:at:) throws` (merges a repeat within 30 minutes), `updateVisitTitle(profileID:url:title:) throws`, `history(profileID:matching:limit:) throws -> [HistoryVisit]`, `clearHistory(profileID:since: Date?) throws -> Int`, `trimHistory(olderThan days: Int) throws -> Int` (run in `launchMaintenance`); `CommandResult.history(HistoryVisit)` ranked after open tabs and before archived tabs; `HistoryClearRange` (lastHour, today, todayAndYesterday, all) with titles.

- [ ] **Step 1: Write failing tests:** `visitRecordedOnce` (two commits 10 minutes apart → one row, newest time), `visitsSeparateAfterThirtyMinutes`, `titleArrivesLater`, `privateVisitsNeverStored` (Review Focus 4: a private page's commit writes nothing), `clearHistoryLeavesArchiveAndTabs` (Review Focus 4), `clearRanges`, `trimByRetention`, `historyRanksAfterOpenTabs`, `nonWebURLsNotRecorded` (`about:blank`, refused URLs), `profileDeletionCascades`.
- [ ] **Step 2: Run** `--filter HistoryTests` and `--filter CommandBarTests` → FAIL.
- [ ] **Step 3: Implement** decision 9. A history result opens through the policy with `openedByUser = true`. The blank "New Tab" ranking leftover from plan 4 is settled here: blank tabs rank last.
- [ ] **Step 4: Run** the suite → PASS.
- [ ] **Step 5: By-hand check:** visit three local pages, ⌘T, type part of a title → the history row appears; History ▸ Clear History… ▸ the last hour → gone; the archive is unchanged.
- [ ] **Step 6: Commit** `feat: history recording, command bar history and Clear History`

### Task 7: Favicons in the sidebar

**Files:**
- Create: `Sources/StaveWeb/FaviconLoader.swift`; `Tests/StaveWebTests/FaviconLoaderTests.swift`
- Modify: `Stave/Views/Sidebar/SidebarRowView.swift`, `EssentialsGrid.swift`, `Stave/Views/CommandBar/CommandBarView.swift`, `Stave/App/AppEnvironment.swift`

**Interfaces:**
- Produces: `@MainActor public final class FaviconLoader { init(cacheFolder: URL?, session: URLSession = .ephemeralNoCookies, maxBytes: Int = 524_288, maxFiles: Int = 2000); func image(for faviconURL: String?) -> NSImage?` (cached only) `; func load(_ faviconURL: String) async -> NSImage?; func prune() }`. `cacheFolder == nil` means memory only (private windows).

- [ ] **Step 1: Write failing tests** with a `URLProtocol` stub (no network): `faviconBodyCapped` (Review Focus 5: a 2 MB body → nil, the transfer is cancelled at the cap), `faviconRedirectToFileRefused`, `faviconRequestCarriesNoCookies` (the stub sees no `Cookie` header with a cookie set in the shared store), `htmlBodyIsNotAnImage`, `cachedOnDiskByHash`, `pruneKeepsNewest`, `privateLoaderWritesNoFiles`, `decodeOffMain` (the main actor keeps running during a slow decode stub).
- [ ] **Step 2: Run** `--filter FaviconLoaderTests` → FAIL.
- [ ] **Step 3: Implement** decision 10. Rows and tiles show the image when cached, the monogram otherwise; the image has no accessibility label of its own (the row's label already names the tab).
- [ ] **Step 4: Run** → PASS; build → succeeds.
- [ ] **Step 5: By-hand check:** a local page with `<link rel="icon">` → the icon shows in the row and the tile after the load; relaunch → shows at once from the cache.
- [ ] **Step 6: Commit** `feat: favicons in the sidebar, fetched without cookies`

### Task 8: Find in page

**Files:**
- Create: `Sources/StaveCore/Web/FindState.swift`, `Sources/StaveWeb/PageTools.swift`, `Stave/Views/Content/FindBar.swift`; `Tests/StaveCoreTests/FindStateTests.swift`, `Tests/StaveWebTests/PageToolsTests.swift`

**Interfaces:**
- Produces: `public struct FindState: Equatable, Sendable { var query: String; var isVisible: Bool; var result: FindOutcome?; mutating func ...}` with `FindOutcome { case found, notFound }` (or a count, if the Step 3 spike finds one) and `FindText.notFound` ("Not found"); `PageTools.find(_ query: String, backwards: Bool, in: WKWebView) async -> FindOutcome`.

- [ ] **Step 1: Write failing tests:** `findStateTransitions` (show, type, next, previous, Escape hides and keeps the query for ⌘G, as Safari does), `useSelectionForFind`, and `findsInLocalHTML` (a page with "alpha beta alpha" → found; "gamma" → notFound).
- [ ] **Step 2: Run** → FAIL.
- [ ] **Step 3: Spike** (one attempt, decision 11): does `performTextFinderAction(_:)` on a `WKWebView` show the system find bar with a count on macOS 15 and 26? Record the answer in the commit body, then implement the chosen path.
- [ ] **Step 4: Run** → PASS; build.
- [ ] **Step 5: By-hand check:** ⌘F, type, Return and ⇧Return step through matches; Escape closes; ⌘G finds again; VoiceOver reads "Not found" (ax-dump shows the label).
- [ ] **Step 6: Commit** `feat: find in page`

### Task 9: Zoom per site, print and Web Inspector (question 21)

**Files:**
- Create: `Sources/StaveCore/Web/ZoomLevels.swift`, `OrganizationStore+SiteValues.swift`; `Tests/StaveCoreTests/ZoomAndSiteValueTests.swift`
- Modify: `Database/StaveDatabase.swift` (migration `v6`: `siteValue(id, profileID → cascade, host, key, value TEXT, modifiedAt)`, unique `(profileID, host, key)`), `Sources/StaveWeb/PageTools.swift`, `PageHost.swift`, `PageConfiguration.swift`, `Settings/SettingKey.swift` (`webDeveloperFeatures`)

**Interfaces:**
- Produces: `public enum SiteValueKey: String { case zoom, userAgent }`; `siteValue<V: Codable>(profileID:host:key:as:) throws -> V?`, `setSiteValue(profileID:host:key:_:) throws` (nil removes); `ZoomLevels.levels`, `next(after:)`, `previous(before:)`, `isDefault(_:)`; `PageTools.print(_ webView:, title:)`; inspector on and off per decision 14.

- [ ] **Step 1: Write failing tests:** `zoomStepsThroughSafariLevels` (100 → 115 → 125; at 300 stays; at 50 stays), `zoomStoredPerHostAndProfile`, `defaultZoomRemovesTheRow`, `privateZoomNotStored`, `siteValueIndexIsUnique`, `migrationAddsSiteValue`.
- [ ] **Step 2: Run** → FAIL.
- [ ] **Step 3: Implement** decisions 12–14. Zoom applies on every main-frame commit to a host with a stored value.
- [ ] **Step 4: Run** → PASS; build.
- [ ] **Step 5: By-hand check:** ⌘+ twice on a local page, open another page on the same host → same zoom; relaunch → kept; ⌘0 → 100 % and the row is gone. ⌘P shows the print panel (Cancel). With web developer features on, ⌥⌘I opens the inspector. **Nico checks:** printing to PDF.
- [ ] **Step 6: Commit** `feat: zoom per site, print and Web Inspector`

### Task 10: The standard shortcut set (questions 16, 17, 18)

**Files:**
- Create: `Sources/StaveCore/Shortcuts/StandardShortcuts.swift`; `Tests/StaveCoreTests/StandardShortcutsTests.swift`
- Modify: `Stave/App/StaveApp.swift`, `Window/BrowserWindowModel.swift` (`selectTab(number:)`, `selectAdjacentTab(_:)`, `reopenLastClosed()`)

**Interfaces:**
- Produces: `public struct ShortcutEntry { command: ShortcutCommand; key: String; modifiers: ShortcutModifiers; menu: MenuName }` and `StandardShortcuts.all`; `BrowserWindowModel.selectTab(number:)` per question 17, `selectAdjacentTab(_ delta: Int)` (wraps, as Safari does), `reopenLastClosed()` (restores the newest archived tab of this workspace, selected; nothing when the archive is empty).

- [ ] **Step 1: Write failing tests:** `noTwoCommandsShareAKey` (over the whole table, including the existing ⌘T, ⌘N, ⌘L, ⌘W, ⇧⌘W, ⌃⌘S, ⌘[, ⌘], ⌘R, ⌘., ⇧⌘N, ⌥⌘↑, ⌥⌘↓, ⌃1–9), `safariMeaningsKept` (each key in decision 16 maps to its Safari command), `selectByNumber` (⌘1 the first Essential, ⌘9 the last regular tab), `adjacentWraps`, `reopenLastClosedRestoresNewest`.
- [ ] **Step 2: Run** → FAIL.
- [ ] **Step 3: Implement.** Menus are built from the table; each menu item keeps a VoiceOver label.
- [ ] **Step 4: Run** → PASS; build.
- [ ] **Step 5: By-hand check:** each new shortcut through System Events (Stave confirmed frontmost in the same osascript call); screenshot the View and History menus.
- [ ] **Step 6: Commit** `feat: the standard browser shortcuts`

### Task 11: HTTP auth prompts

**Files:**
- Create: `Sources/StaveCore/Web/AuthChallenge.swift`, `Sources/StaveWeb/PageDelegate+Auth.swift`, `Stave/Views/Content/AuthSheet.swift`; `Tests/StaveCoreTests/AuthChallengeTests.swift`, `Tests/StaveWebTests/AuthDelegateTests.swift`
- Modify: `Tests/StaveWebTests/DelegateSelectorTests.swift`, `Stave/App/PagePrompts.swift`

**Interfaces:**
- Produces: `public struct AuthChallenge: Equatable, Sendable { host: String; realm: String?; isProxy: Bool; previousFailureCount: Int }` with `AuthText.title(for:)` ("‹host› wants you to sign in"), `detail(for:)` (realm in quotes, capped at 200 characters; "Your user name or password was wrong." after a failure), and `static func shouldAsk(method: String) -> Bool` (Basic, Digest, NTLM yes; client certificate no, which cancels; server trust is plan 3's path).

- [ ] **Step 1: Write failing tests:** `authNamesTheAskingFrame` (Review Focus 6: a subframe on `example.org` inside `example.com` → title names `example.org`), `cancelSendsNothing` (Review Focus 6), `realmIsCapped`, `failureCountShowsRetryText`, `clientCertificateCancels`, the selector test lists the auth method.
- [ ] **Step 2: Run** → FAIL.
- [ ] **Step 3: Implement** decision 15, with the wait-until-shown queue the camera question uses.
- [ ] **Step 4: Run** → PASS; build.
- [ ] **Step 5: By-hand check:** a local server in the scratchpad answering 401 with `WWW-Authenticate: Basic realm="test"` → the sheet; wrong password → retry text; right one → the page. **Nico checks:** a real Basic-auth site, if he has one.
- [ ] **Step 6: Commit** `feat: HTTP sign-in prompts`

### Task 12: The Settings window, profiles and containers (question 28)

**Files:**
- Create: `Sources/StaveCore/Settings/SettingsCopy.swift`, `Settings/DeletionCopy.swift`, `Stave/Views/Settings/ProfilesPane.swift`, `ContainersPane.swift`, `WebsitesPane.swift`, `AdvancedPane.swift`; `Tests/StaveCoreTests/SettingsCopyTests.swift`, `ProfileDeletionTests.swift`
- Modify: `Stave/Views/Settings/SettingsView.swift`, `OrganizationStore.swift` (`renameProfile`), `OrganizationStore+Containers.swift` (`renameContainer`, `containerUsage`), `Sources/StaveWeb/WebDataStores.swift` (`remove(_ dataStoreID:) async throws`), `Stave/App/AppDelegate.swift`

**Interfaces:**
- Produces:
  - `renameProfile(_:to:) throws` (blank names refused with a message), `renameContainer(_:to:) throws`, `containerUsage(_:) throws -> (open: Int, archived: Int)`, `profileSummary(_:) throws -> ProfileSummary` (workspace, tab, archived and history counts).
  - `DeletionCopy.profileQuestion(_ summary: ProfileSummary, name: String) -> String` and `containerQuestion`, `containerInUse(count:name:)` per decisions 18–19.
  - `WebDataStores.remove(_:)` removes a persistent store with `WKWebsiteDataStore.remove(forIdentifier:)` after checking no live page uses it, and throws `.inUse` otherwise.
  - An app-level `ProfileDeletion` flow: close that profile's private session, switch every window showing it, `deleteProfile`, then remove the returned stores.

- [ ] **Step 1: Write failing tests:** `profileDeletionNamesWhatGoes` (Review Focus 3: counts in the question match the summary), `storesRemovedOnlyAfterRows` (Review Focus 3: a fake `WebDataStores` sees `remove` only after `deleteProfile` returned, and never for a store a live page holds), `lastProfileRefused`, `containerInUseRefusedWithCount` (Review Focus 3), `blankProfileNameRefused`, `settingsCopyIsComplete` (every pane title and control label is non-empty and unique).
- [ ] **Step 2: Run** → FAIL.
- [ ] **Step 3: Implement** decisions 17–19. The Websites pane lists `siteSetting` and `siteValue` rows by host, with Remove and Remove All (a confirmation for Remove All). Advanced shows backup status (Task 1) and web developer features (Task 9).
- [ ] **Step 4: Run** → PASS; build.
- [ ] **Step 5: By-hand check** (seeded): rename a profile; create a second profile with a tab, delete it → the question names its counts; afterwards `<folder>/data` and the WebKit store list no longer have it, and the window is on the first profile. Delete "Work Google" while a tab uses it → refused with the count. Keyboard only through every pane; ax-dump shows every control's label.
- [ ] **Step 6: Commit** `feat: Settings window with profiles, containers and websites`

### Task 13: The per-site panel (question 11)

**Files:**
- Create: `Sources/StaveCore/Web/SitePanelModel.swift`, `Stave/Views/Sidebar/SitePanel.swift`; `Tests/StaveCoreTests/SitePanelModelTests.swift`
- Modify: `Stave/Views/Sidebar/AddressField.swift`, `Stave/App/PagePrompts.swift` (Remember keeps Block when question 11 is yes), `Stave/App/MediaQuestionCenter.swift`

**Interfaces:**
- Produces: `@MainActor @Observable public final class SitePanelModel { init(store:, profileID: UUID?, host: String); var rows: [SitePanelRow]; func set(_ key: SitePanelKey, _ choice: SiteChoice); func resetSite() }`, with `SiteChoice { case ask, allow, block }` for permissions and value pickers for zoom and user agent. A private window's panel edits the in-memory answers only.

- [ ] **Step 1: Write failing tests:** `panelShowsStoredAnswers`, `askRemovesTheRow`, `blockIsRemembered` (question 11), `resetSiteClearsEveryKey`, `privatePanelWritesNothing`, `nonWebPageHasNoPanel`.
- [ ] **Step 2: Run** → FAIL.
- [ ] **Step 3: Implement** decision 20. Changing content blocking reloads, as plan 3 does; changing zoom applies at once.
- [ ] **Step 4: Run** → PASS; build.
- [ ] **Step 5: By-hand check:** `cam.html` from plan 3: Block with Remember → reload, no sheet, camera off; the panel shows Block; Ask → the next load asks. **Nico checks:** Google Meet with Block then Ask.
- [ ] **Step 6: Commit** `feat: settings for this website`

### Task 14: Downloads hardening (question 22)

**Files:**
- Modify: `Sources/StaveCore/Web/DownloadList.swift`, `Sources/StaveWeb/PageDelegate.swift`, `Sources/StaveWeb/Quarantine.swift`, `Stave/Views/Sidebar/DownloadsPopover.swift`; tests in `DownloadListTests.swift` and `StaveWebTests`
- If question 22 is yes: migration `v7` (`downloadRecord`, per profile), and `OrganizationStore+Downloads.swift`

**Interfaces:**
- Produces: the plan 3 Carried fixes, one test each: a finished file is never deleted when a re-mark throws after a successful first mark (check for an existing quarantine first); `failed` claims an unclaimed file so no unmarked partial is left; same-name concurrent downloads reserve their name (create the file exclusively, then write); names can't start with a combining mark; `a.tar.gz` becomes `a (2).tar.gz`; `DownloadFilename` drops U+061C, U+2028, U+2029, U+200B–U+200D, U+2060 and U+FEFF; a NaN progress is ignored; the `claimDownloadFile` test seam moves out of production code; `fileExists` in `~/Downloads` runs off the main thread; the quarantine record names the source page and the download URL (decision 23); the popover sits inside the window with one material (decision 23); question 7's answer.

- [ ] **Step 1: Write failing tests:** `finishedFileSurvivesARemarkFailure`, `failedClaimsThePartial`, `concurrentSameNameDownloadsDontCollide`, `leadingCombiningMarkStripped`, `multiDotExtensionNumbered`, `invisibleCodePointsRemoved`, `nanProgressIgnored`, `quarantineNamesTheSource`, and, with question 22 yes, `listSurvivesRelaunch`, `privateRowsNeverStored`.
- [ ] **Step 2: Run** → FAIL.
- [ ] **Step 3: Implement.**
- [ ] **Step 4: Run** → PASS; build.
- [ ] **Step 5: By-hand check:** two downloads of the same name at once → `name.txt` and `name (2).txt`, both quarantined, `xattr -p com.apple.quarantine` shows the source host; the popover inside the window (screenshot). **Nico checks:** Show in Finder selects the file (asked twice in plan 3, still unconfirmed); the Don't Allow half of the Downloads-folder prompt.
- [ ] **Step 6: Commit** `fix: downloads hardening`

### Task 15: Prompts and pages leftovers

**Files:**
- Modify: `Stave/App/PagePrompts.swift`, `Stave/App/MediaQuestionCenter.swift`, `Sources/StaveWeb/PageDelegate+UI.swift`, `Sources/StaveWeb/PageHost.swift`, `Sources/StaveCore/Web/PageRecorder.swift`, `Sources/StaveCore/Window/BrowserWindowModel.swift`; tests in `StaveWebTests` and `StaveCoreTests`

**Interfaces:**
- Produces, each from plan 3's Carried:
  - Background-tab dialogs wait (decision 21). The external-app question is tab-scoped and dropped on navigation or "Bring It Here" (decision 22); its heading names the frame that clicked when WebKit gives it.
  - Hibernation forgets the page's prompts in both window kinds; `hibernateIdle` reads `hasOpenPopups` after the media checks.
  - Title-only writes are coalesced (at most one store write per 500 ms per tab); `tabDeselected` flushes only the deselected tab; the menu snapshot recomputes only when `PageStatus` fields it reads change.
  - Plan 3 decision 5's typed external scheme is unreachable today. `AddressInput` classifies a typed `mailto:` or `tel:` as a link to hand to another app, so the external-app question and the "No app can open this link" panel are reachable, as in Safari. `javascript:`, `file:`, `data:` and `about:` still become searches (plan 4 Review Focus 1 is unchanged).

- [ ] **Step 1: Write failing tests:** `backgroundAlertWaitsUntilShown`, `navigationResolvesAWaitingConfirm`, `externalQuestionDroppedOnBringHere`, `hibernationForgetsPrompts`, `titleWritesCoalesced`, `typedMailtoAsks`.
- [ ] **Step 2: Run** → FAIL.
- [ ] **Step 3: Implement.**
- [ ] **Step 4: Run** → PASS; build.
- [ ] **Step 5: By-hand check:** a local page that calls `alert()` on a timer in a background tab → no sheet until the tab is shown, then the sheet. A `mailto:` sheet, then Bring It Here in a second window → the first window's sheet goes away.
- [ ] **Step 6: Commit** `fix: dialogs wait for their tab, and other page leftovers`

### Task 16: Site-compatibility tools

**Files:**
- Modify: `Sources/StaveCore/Web/UserAgent.swift`, `Sources/StaveWeb/PageHost.swift`, `Stave/Views/Sidebar/SitePanel.swift`, `Stave/App/StaveApp.swift`; `Tests/StaveCoreTests/UserAgentTests.swift`

**Interfaces:**
- Produces: `public enum SiteUserAgent: String, Codable { case standard, safari, chrome }` stored as the `userAgent` site value; `UserAgent.string(for: SiteUserAgent, safariVersion:)`; `UserAgent.chromeMajorVersion` constant; `OpenElsewhere.available(installed: Set<String>) -> [OpenElsewhereApp]` (Safari `com.apple.Safari`, Chrome `com.google.Chrome`). Also plan 3's leftover: `UserAgent` refuses a version of only dots.

- [ ] **Step 1: Write failing tests:** `chromeAgentNamesChrome`, `perSiteAgentStoredAndCleared`, `dotsOnlyVersionFallsBack`, `openElsewhereListsOnlyInstalled`.
- [ ] **Step 2: Run** → FAIL.
- [ ] **Step 3: Implement** decisions 24–25.
- [ ] **Step 4: Run** → PASS; build.
- [ ] **Step 5: By-hand check:** a local page that prints `navigator.userAgent` → Chrome after the switch, back to standard after Reset; View ▸ Open in Safari opens the same URL in Safari (Stave frontmost check first; the session never clicks in Safari).
- [ ] **Step 6: Commit** `feat: per-site user agent and Open in Safari or Chrome`

### Task 17: Location permission (waits on question 19) [TCC]

**Files:**
- Create: `Sources/StaveWeb/PageDelegate+Location.swift`; tests in `StaveWebTests`
- Modify: `Stave/Info.plist` (`NSLocationUsageDescription`: "Websites you allow can use your location."), `Stave/Stave.entitlements` (`com.apple.security.personal-information.location`), `Sources/StaveCore/Web/SiteSettings.swift` (`SiteSettingKey.location`), `Tests/StaveWebTests/DelegateSelectorTests.swift`

- [ ] **Step 1: Spike** (one attempt): on macOS 15 and 26, find which delegate method WebKit calls for `navigator.geolocation.getCurrentPosition` in a `WKWebView`. Record the selector and whether it is public in the commit body. If the answer to question 19 rules the SPI out, stop here and mark the task "not in the beta".
- [ ] **Step 2: Write failing tests:** `locationQuestionNamesTheTopSite`, `rememberedAllowSkipsTheSheet`, `privateAnswersInMemory`, the selector list.
- [ ] **Step 3: Implement** with the camera question's rules (Stave's sheet after macOS's own prompt; held until the tab is shown; per profile and host).
- [ ] **Step 4: Run** → PASS; build.
- [ ] **Step 5: By-hand check:** a local page asking for location → Stave's sheet; macOS asks for Stave's location access the first time (Nico answers it). **Nico checks:** a real maps site.
- [ ] **Step 6: Commit** `feat: location permission per site`

### Task 18: Web notifications (waits on question 20) [Chorus] [TCC]

**Files:**
- Modify: `Packages/StaveCore/Package.swift` (the new `exact:` pin, only after the Chorus tag exists and ENGINE.md's "Engine API changes by release" was read), `Sources/StaveWeb/PageConfiguration.swift`, `Sources/StaveCore/Web/SiteSettings.swift` (`SiteSettingKey.notifications`), `Stave/App/AppDelegate.swift` (UserNotifications authorization); tests in `StaveWebTests`

- [ ] **Step 1: Confirm** the Chorus tag carries engine change 1 and that Chorus's CI is green on it. If not, stop: this task waits, and the beta ships without notifications.
- [ ] **Step 2: Write failing tests:** `notificationNeedsSitePermission`, `privateWindowNeverNotifies` (as Chrome and Firefox deny in private), `clickingANotificationShowsItsTab`.
- [ ] **Step 3: Implement.** macOS asks for Stave's notification permission the first time a site the user allowed sends one.
- [ ] **Step 4: Run** the suite and both builds → PASS; CI green on macos-15 and macos-26 with the new pin.
- [ ] **Step 5: Commit** `chore: move ChorusEngine to <tag>` then `feat: web notifications per site`

### Task 19: Passkeys (question 29) [Apple]

**Files:**
- Modify: `Sources/StaveCore/Settings/SettingsCopy.swift` (the notice), `Stave/Views/Import/FirstRunView.swift`; once granted: `Stave/Stave.entitlements`, `project.yml` (provisioning profile for Release), `release/DISTRIBUTION.md`

- [ ] **Step 1: Notice now:** the first-run screen and Settings ▸ Advanced say what works today (question 29's text). Test `passkeyNoticeIsPlain` pins the text.
- [ ] **Step 2: When Apple grants it** (not before): add `com.apple.developer.web-browser.public-key-credential`, the Developer ID provisioning profile, and remove the notice. By-hand: sign in with a passkey at a site that offers one. **Nico checks:** the provisioning profile install.
- [ ] **Step 3: Commit** `feat: passkey notice` (and later `feat: passkeys with Apple's entitlement`)

### Task 20: Part A check and outcome

**Files:**
- Modify: this plan (Part A's Outcome), `docs/superpowers/plans/2026-10-28-stave-foundation.md` (roadmap entry 5 status), `README.md` (Status: it still says web pages are "Not yet"; plan 3 built them), `CLAUDE.md` if a rule changed

- [ ] **Step 1: Run** the full package suite and both app builds; push; CI green on macos-15 and macos-26.
- [ ] **Step 2: By-hand run** over Tasks 1–19 on one throwaway folder, keyboard and accessibility only, screenshots per task.
- [ ] **Step 3: Write the Outcome** with a Nico checks list (pointer, real sites, VoiceOver, the default-browser switch) and start the two-week daily-driver clock if Nico agrees (question 1).
- [ ] **Step 4: Commit** `docs: plan 5 part A outcome`

# Part B: release

### Task 21: Version, update feed and Sparkle (questions 23–26)

**Files:**
- Create: `Stave/App/Updater.swift`
- Modify: `project.yml` (Sparkle 2.x from `https://github.com/sparkle-project/Sparkle`, app target only; `MARKETING_VERSION` per question 26), `Stave/Info.plist` (`SUFeedURL`, `SUPublicEDKey`, `SUEnableAutomaticChecks`), `Stave/App/StaveApp.swift` (Stave ▸ Check for Updates…), `Settings/SettingsCopy.swift` (Settings ▸ General ▸ "Check for updates automatically"), `THIRD_PARTY_NOTICES.md` (Sparkle, MIT), `README.md` (what the update check sends and whether it is counted)

- [ ] **Step 1: Nico** generates the Sparkle key (question 24) and keeps the private key in his Keychain and backup; only the public key goes into `Info.plist`. **[Apple account not needed; Nico's Keychain]**
- [ ] **Step 2: Implement** the updater gated so Debug builds never check (`#if !DEBUG`), the menu item and the setting. The feed URL is the final one (decision 27).
- [ ] **Step 3: Verify:** both builds; the Release build's `Info.plist` holds the feed URL and key (`plutil -p`); a Debug build makes no request to the feed (Little Snitch or `nettop`, Nico's call).
- [ ] **Step 4: Commit** `feat: Sparkle updates`

### Task 22: Signing, notarization and the release script [Apple]

**Files:**
- Create: `release/DISTRIBUTION.md` (adapted from Chorus's, Stave's values), `release/ExportOptions.plist` (Developer ID, team from Nico), `release/release.sh`, `docs/appcast.xml` (empty feed)

- [ ] **Step 1: Write `release.sh`:** archive the Release build, export with Developer ID, `xcrun notarytool submit --wait` with Nico's stored keychain profile (never a password in the script), `xcrun stapler staple`, `hdiutil create` the DMG, notarize and staple the DMG, print its SHA-256. It refuses to run with a dirty tree or a bundle ID other than `com.nicojan.Stave`.
- [ ] **Step 2: Nico runs it** for a first test build (not published). Verify: `spctl -a -vv Stave.app` says "Notarized Developer ID"; `codesign -d --entitlements - Stave.app` shows the camera, audio-input (and location, if Task 17 shipped) entitlements; the app launches on a clean user account with Gatekeeper on.
- [ ] **Step 3: Commit** `chore: release script, distribution notes and empty appcast`

### Task 23: GitHub release, appcast and the Homebrew cask

**Files:**
- Create: `release/homebrew/stave.rb`
- Modify: `release/DISTRIBUTION.md` (the release checklist), `docs/appcast.xml`

- [ ] **Step 1: Write the checklist** in `DISTRIBUTION.md`: bump versions; bump `UserAgent.chromeMajorVersion` if Chrome moved; run `release.sh`; `gh release create vX.Y.Z` with the DMG; sign and regenerate `docs/appcast.xml` with Sparkle's `generate_appcast`; put the version and SHA-256 into `release/homebrew/stave.rb`, copy it to `Casks/stave.rb` in `nicojan/homebrew-tap`, and run `brew style`, `brew livecheck` and `brew audit --cask --online`.
- [ ] **Step 2: Write the cask** (`app "Stave.app"`, `depends_on macos: ">= :sequoia"`, `zap` naming `~/Library/Application Support/Stave` and the WebKit folder for `com.nicojan.Stave`, never Stave-debug).
- [ ] **Step 3: Verify** with a test release Nico can delete: `brew install --cask nicojan/tap/stave` installs it; an older build updates through Sparkle.
- [ ] **Step 4: Commit** `chore: Homebrew cask and the release checklist`

### Task 24: The beta gate and release notes

**Files:**
- Modify: `README.md` (install, privacy: what leaves the Mac, backups and how to restore, the Arc file note), `docs/release-notes/0.1.0.md` (new), this plan (Outcome)

- [ ] **Step 1: Release notes** in plain words: what works, what doesn't yet (passkeys if not granted, notifications if the tag isn't out, containers' limits), "keep a copy of Arc's `StorableSidebar.json` before 2026-12-22" (plan 2's risk), and how to report a bug.
- [ ] **Step 2: Walk the gate** (spec, "The beta is ready when"), recording each line with a date:
  - Nico has used Stave as his default browser for two weeks with no lost tab, pinned tab or workspace.
  - The sign-in checklist: Google, Microsoft, Apple, an Okta-style SSO pop-up, GitHub; Google Docs, Google Meet with camera and mic, YouTube, and a DRM site on another FairPlay stream (result recorded even if it fails; plan 3's Bitmovin demo spun in Safari too).
  - `kill -9` mid-use and relaunch restores every window, workspace and tab (and the hourly backup exists).
  - The Arc import on every available sample, including the synthetic fixtures, with an accurate report.
  - No crash in the last week of daily use.
- [ ] **Step 3: Nico** publishes the first release with Task 23's checklist.
- [ ] **Step 4: Next steps written down:** ask Apple to add `com.nicojan.Stave` to the Passwords helper's allow-list (spec, Apple approvals 2) and find out the process **[Apple]**.
- [ ] **Step 5: Commit** `docs: beta release notes and gate results`

### Task 25: Housekeeping

- [ ] Delete `.superpowers/sdd/2026-10-31-stave-web-layer/` and this plan's ledger once the PRs merge (plan 3's Carried).
- [ ] Update the foundation roadmap: entries 3 and 4 still say "waiting on Nico's checks" and give old test counts and CI targets.
- [ ] Commit `docs: roadmap status after plan 5`

## Engine changes Stave would use (requests to Chorus, not edited here)

Each one goes to Chorus as its own change, comes back through a new tag, and Stave moves its `exact:` pin only after reading ENGINE.md's "Engine API changes by release". Stave stays on 1.5.36 until then.

1. **Notification bridge** on any `WKUserContentController`, handler name and JS globals configurable. Needed by Task 18 (question 20).
2. **A public way to make a `WebViewParking` and choose its pages.** Not needed for the beta (settled: no parking).
3. Public `DownloadCenter.begin`, `setDestination` and `fail`; `WebSurface.DataStore.nonPersistent`; a logger subsystem parameter; an option on `DataStoreManager` to keep ITP on. Not needed for the beta.

## Outcome (filled when built)

## Carried into later plans (filled when built)
