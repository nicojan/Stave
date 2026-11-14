# Stave Browser Basics and Release Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

> **Status: questions answered 2026-11-13; Part A is being built on `feat/browser-basics`.** Nico answered every open question on 2026-11-13 (each answer is under its question in "Open questions for Nico"). Tasks 17, 18 and 19 are not built in that session: they are marked [TCC], [Chorus] and [Apple]. Part B is not started.

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

- Rolling database backups (plan 3's Carried; question 2, answered 2026-11-13).
- One host-display rule for `DisplayText` and `SiteHost`, and the bugs found on 2026-11-10 (listed under Task 2).
- The deferred review minors from plans 1–4: store tidy-ups, missing tests, literal strings in views, app-side leftovers (staying open with no windows, and the window following a moved selected tab).
- Default-browser registration, links from other apps and opening local HTML files (spec item 5).
- History recording, the command bar's history source, and the History view on ⌘Y (Task 6, question 16).
- Favicon images in the sidebar.
- Find in page, zoom per site, print, and developer tools with no setting (Task 9, question 21).
- The full set of Safari/Chrome-standard shortcuts.
- HTTP auth prompts.
- The Settings window, with profile rename and delete, and container create, edit and delete, each deletion behind a confirmation.
- A per-site settings panel from the address field (camera, microphone, content blocking, zoom, user agent, and location and notifications once they exist).
- Downloads hardening, the downloads list kept across restarts (Task 14, question 22), and the prompt leftovers from plan 3.
- Site-compatibility tools: per-site user agent and "Open in Safari/Chrome" (spec item 7).
- Auto-archiving idle tabs, a setting that is off by default (Task 16b, question 27).
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

Closed for this plan: the `.debug` data-folder mapping only changes if a third bundle ID appears, and question 23's answer (2026-11-13) adds none for the beta. Still open from the foundation: `markActive` and split slots (out, above).

## Global Constraints

- macOS deployment target `15.0`; `SWIFT_VERSION` `6.0`; strict concurrency complete; manifests at swift-tools-version 6.0. CI runs on macos-15 and macos-26 with the newest installed Xcode that isn't a beta or release candidate. Check each new WebKit or AppKit symbol's availability against macOS 15. Never nest `try #require` inside `#expect`; hoist it to a `let`.
- `ChorusEngine` stays `exact: "1.5.36"`. Engine code is never edited here. An engine change goes to Chorus as its own work, comes back through a tag, and Stave moves its `exact:` pin only after reading ENGINE.md's "Engine API changes by release".
- Bundle ID `com.nicojan.Stave` never changes; Debug is `com.nicojan.Stave.debug` with `Application Support/Stave-debug`. No store, backup, favicon cache or history is ever opened through a framework default path. Stave never calls `WKWebsiteDataStore.default()`. WebKit's in-app inspector front end keeps its own state there, which decision 14 accepts (question 21).
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
2. **[Apple account]** After the name check, request the `com.apple.developer.web-browser.public-key-credential` entitlement for `com.nicojan.Stave` (spec, Apple approvals 1). Zen 1.24b carries it with a Developer ID provisioning profile (checked 2026-11-04), so Developer ID is possible. Apple has published the criteria and process; only the timeline is unknown. The request goes through `developer.apple.com/contact/request/macos-browsers-passkeys/` and needs the Account Holder role of an organization's Apple Developer account. The criteria: `http` and `https` in `Info.plist`; on launch, a URL field, search or curated bookmarks; direct navigation to the URL asked for. The entitlement exists from macOS 13.3, and Apple adds it as a managed capability. Nico confirms the team is an organization account (question 29).
3. **[Apple account]** Confirm the Developer ID Application certificate and notarytool credentials Chorus uses are available for Stave (same team, `3CY4DX3K45` in Chorus's `release/ExportOptions.plist`).
4. Answer the open questions below. Done 2026-11-13.

## Decisions (my call unless noted; Nico can overturn any)

Data safety:

1. **Backups are copies of the whole database made with GRDB's online backup** (`DatabaseReader.backup(to:)`), into `<data folder>/Backups/`. One at launch, one every hour while Stave runs, and one before any schema migration. Keep the 10 newest hourly copies and the newest copy of each of the last 3 days. Reason: the archive guards only against the user's own deletions, not against a Stave bug writing bad rows (plan 3's Carried). A copy is written under a temporary name (`.partial`). A copy leaves out history and (from Task 14) the downloads list, as Chrome's and Firefox's backups keep the user's organisation but never history, so Clear History is never undone by an old copy: on the `.partial` file, Stave deletes the rows of `BackupPolicy.excludedTables` that exist, runs `VACUUM`, sets `journal_mode=DELETE` and closes it, then checks it with `PRAGMA quick_check` and renames it. So a half-written copy is never kept, and each copy is one self-contained file with no `-wal` or `-shm` beside it. The newest copy made before a migration is kept until the next migration. Pruning deletes only files in `Backups/` whose names match Stave's own pattern. (question 2, answered 2026-11-13)
2. **Backups never block the main thread and never stop Stave.** A failed backup is logged and retried at the next hour; after three failures in a row the Settings window shows "Stave couldn't back up your data" with the reason. Reason: a backup failure must be visible but must not cost the user their session.

Display text (the 2026-11-10 findings):

3. **One host rule, `HostText`, for every place that shows or keys a host.** It lowercases the host, drops any port, keeps an IPv6 host in brackets, strips one leading `www.`, and keeps IDN hosts as punycode (question 4): the address field shows punycode exactly as WebKit reports it, and the monogram comes from the title when the host's first label starts with `xn--`. `DisplayText.address`, `DisplayText.monogram` and `SiteHost.normalized` all call it. Reason: plan 3's `SiteHost` and plan 4's `DisplayText` drifted apart (one lowercases, one doesn't; neither handles punycode). (question 4, answered 2026-11-13)
4. **A monogram is one character.** It comes from the trimmed source (host, else title), uppercased, and the first `Character` of the uppercased form is kept, so "ßeta" gives "S" and "ﬁsh" gives "F". Leading spaces and newlines are skipped, so "  lead" gives "L". Reason: a tile shows one letter; multi-letter uppercase and blank monograms are bugs.
5. **Unreachable guards go.** `switchWorkspace(number:)` checks `number >= 1` before subtracting, so `Int.min` can't overflow (unreachable today, but the guard is free). `deleteWorkspace`'s missing-slot guard can never fire (the tabs are fetched by those very slot IDs) and is removed, with a comment saying why.

Default browser and links:

6. **Stave declares `http`, `https` and HTML files** (`public.html`, `public.xhtml`) in `Info.plist`, and Settings ▸ General has "Make Stave your default browser", which calls `NSWorkspace.setDefaultApplication(at:toOpenURLsWithScheme:)` for `http` (macOS asks the user to confirm and sets `https` with it). Stave never sets itself as default without that button. `mailto:` and other schemes are not declared and go to their own apps (spec item 5). An HTML file opened from Finder, dropped on a window, or chosen with File ▸ Open File… (⌘O) loads through `NavigationSource.openedFile`, which allows the opened file plus user-clicked main-frame `file:` links inside its granted folder. WebKit gets read access to the file's folder, or to the file alone when that folder is `/` or the home folder. The granted folder is kept per tab, in memory, never stored, and is an input to the policy. A clicked link outside the folder shows the refused panel; a script-started `file:` navigation is refused silently. A restored `file:` tab doesn't load by itself; its panel offers "Open Again", which reloads it through the opened-file path. (question 13, answered 2026-11-13)
7. **A link from another app** goes through `NavigationPolicy.decide(_, isMainFrame: true, source: .typed)` and opens as a new selected tab at the top of the target workspace's regular tabs (`NewTabOrigin.externalApp`), with `openedByUser = true`, and Stave comes to the front. With the default "Last used", it goes to the most recently active non-private browser window, on whatever workspace that window shows. With a chosen workspace: first the most recently active window already showing it (Stave's own call); failing that, the most recently active window of that profile, switched to the workspace; failing that, a new window on it. It never goes into a private window. With no regular browser window open, a new window opens on the target (for "Last used", the last state the session knows). Links that arrive before launch completes are queued and opened after the saved windows are restored; if launch fails (the store didn't open), they are reported to the user, never dropped. A refused link opens a new tab that shows the refused panel and loads nothing, so the user sees why. (question 14, answered 2026-11-13)
8. **The Debug build shows as "Stave Debug" in the default-browser list** (`CFBundleDisplayName` for Debug only; the bundle ID is unchanged). Reason: two entries both named "Stave" would let Nico pick the Debug build by mistake. Task 5 checks that `capture-window.swift` and `ax-dump.sh` still find the app by name.

History and favicons:

9. **History is one row per visit** (`historyVisit`: profile, URL, title, visited-at), written on a main-frame commit and updated when the title arrives, never in a private window. Repeat visits to the same URL within 30 minutes update the last row rather than adding one. The command bar ranks history after open tabs and before archived tabs, newest first among equals. History ▸ Clear History… offers Safari's ranges (the last hour, today, today and yesterday, all history) and removes history rows and ended download-list rows in the range, never the archive, tabs or downloaded files. History ▸ Show All History (⌘Y) shows a History view in the front window's content area in place of the page, as Safari does. It is not a tab and is not saved in the session, and ⌘Y returns to the page. It has a focused search field and visits newest first, grouped by local day; Return or double-click opens a visit through the policy with `openedByUser = true`; Delete removes the selected visits; a Clear History… button sits beside them. A private window has no History view (Stave's choice). History is kept one year by default, as in Safari. Settings ▸ General has "Remove history items": After one day, After one week, After two weeks, After one month, After one year, Manually (never trimmed). `trimHistory` runs at launch maintenance and once a day while Stave runs, and removes only `historyVisit` rows older than the setting. (questions 15, 16 and 22, answered 2026-11-13)
10. **Favicons are fetched without cookies and cached on disk.** `FaviconLoader` in `StaveWeb` fetches the URL the page reported through an ephemeral `URLSession` (no cookies, no credentials, `https` and `http` only, redirects to other schemes refused), caps the body at 512 KB, decodes it with `NSImage` off the main thread, scales it to 32 × 32 pt @2x, and stores a PNG in `<data folder>/Favicons/<sha256 of URL>.png`. The cache keeps at most 2,000 files, oldest-used first out. Private windows keep favicons in memory only. A failure falls back to the monogram. Reason: a favicon request with the profile's cookies would tell a site the user has a tab open, which no mainstream browser does in a background fetch.

Page tools:

11. **Find** uses WKWebView's public `find(_:configuration:completionHandler:)` with a Stave find bar above the page (⌘F, ⌘G, ⇧⌘G, ⌘E, Escape). Task 8's first step is a spike: if `performTextFinderAction(_:)` gives the system find bar with a match count on macOS 15 and 26, use it instead. Either way, the bar's strings and enablement come from `StaveCore`.
12. **Zoom** is per site and per profile, through `WKWebView.pageZoom`: ⌘+ / ⌘- step through Safari's levels (50, 75, 85, 100, 115, 125, 150, 175, 200, 250, 300 %), ⌘0 resets. A non-default level is stored as a site value (Task 9's table). On every main-frame commit the page's `pageZoom` is set to the host's stored value, or 100 % when none is stored, so a zoom never leaks to another site (Safari's per-site zoom). Private windows keep zoom in memory.
13. **Print** uses `WKWebView.printOperation(with:)` with the page's title as the job name. ⌘P. A blank tab or a failure panel has nothing to print (menu disabled).
14. **Developer tools with no setting, as in Chrome and Firefox.** Every page in a normal window (private windows per the spike, below) is created with WebKit's private `developerExtrasEnabled` preference, which gives Inspect Element in the page menu and the in-app inspector. A Develop menu is always visible and uses Safari's names and keys: Show Web Inspector (⌥⌘I), Show Page Source (⌥⌘U). This is a hybrid, said plainly: Safari's names, with Chrome's and Firefox's always-on (Safari hides its menu behind a setting). `isInspectable` stays off unless Task 9's spike shows the in-app inspector needs it. A missing private piece leaves its menu item disabled. The inspector's own front end keeps its state in WebKit's default persistent store under the app's bundle ID; Stave itself never calls `WKWebsiteDataStore.default()` and no page's data goes there, so normal windows get the inspector. Private windows get it only if the spike shows that opening it writes nothing that names the page; otherwise Inspect is off there and the gap is written down. (question 21, answered 2026-11-13)
15. **HTTP auth** (Basic, Digest, NTLM) shows a sheet on the tab: "‹host› wants you to sign in", with the realm shown as the site's own words, a user name field and a password field. Cancel cancels the challenge. Stave stores nothing (no password manager). A challenge for a page not shown waits until its tab is shown, like the camera question. A challenge from a cross-site subframe names the frame's host, not the top page's. Server trust challenges keep plan 3's handling (no "proceed anyway"): once Stave answers auth challenges, ServerTrust, Negotiate and any other method get `.performDefaultHandling`, so WebKit's default trust evaluation is unchanged.

Shortcuts:

16. **Shortcuts come from one table, `StandardShortcuts`, in `StaveCore`,** with a test that no two menu items share a key. The table adds, with Safari's meaning: ⌘F, ⌘G, ⇧⌘G, ⌘E (find); ⌘+, ⌘-, ⌘0 (zoom); ⌘P (print); ⌥⌘I (Show Web Inspector); ⌘Y (Show All History, question 16); ⌘O (File ▸ Open File…, question 13); ⌥⌘L (downloads popover); ⇧⌘T (reopen the last closed tab from the archive); ⌃Tab, ⌃⇧Tab, ⇧⌘], ⇧⌘[ (next and previous tab in sidebar order); ⌘1–9 (question 17: ⌘1–⌘8 select the nth tab in sidebar order, ⌘9 the last); ⌘D (Pin Tab, standing in for Safari's Add Bookmark; disabled on a pinned tab or Essential, in a private window, on a tab with no web page, and with no tab selected; question 18); ⌥⌘U (Show Page Source, which opens Web Inspector's source view, as in Safari's Develop menu, with no setting). Existing assignments are unchanged. (questions 13, 16, 18 and 21, answered 2026-11-13)

Settings and site panel:

17. **The Settings window has six panes:** General (search engine, default browser, where links from other apps land, new tabs at top or bottom, "Remove history items", "Remove download list items"), Tabs (⌃1–9, compact mode, archive trim days shown read-only at 30, "Archive idle tabs after"), Profiles, Containers, Websites (every stored per-site answer and value, by host, with Remove and Remove All; from Task 18, the "Allow websites to ask to send notifications" switch), Advanced (backups status, "Show Backups in Finder", and the passkey notice from Task 19). Every control has a label from `SettingsCopy` and works with the keyboard alone. (questions 15, 21, 22 and 27, answered 2026-11-13)
18. **Deleting a profile** asks first, naming what goes: "Delete the profile “‹name›”? Its ‹n› workspaces, ‹n› tabs, its archive, history, downloads list and website data (cookies, sign-ins) will be deleted. This can't be undone." Delete is the destructive button, not the default. Windows showing that profile switch to the first remaining profile first. The data stores are removed with `WKWebsiteDataStore.remove(forIdentifier:)` only after the store rows are gone and no page uses them. The last profile can't be deleted (`.lastProfile`). The private session of that profile closes first.
19. **Containers:** Settings lists each profile's named containers with Create, Edit (name and colour) and Delete, as Firefox and Zen do. The colour comes from the palette workspaces already use (`WorkspaceEditorRules`), and there are no icons. Delete keeps the store's rule rather than Firefox's tab-closing: refused while any open or archived tab uses it, with "‹n› tabs still use “‹name›”. Close them or move them out first." When allowed, it asks first, naming the website data that goes, and the store is removed only after the row is gone. Throwaway containers stay post-beta. (question 28, answered 2026-11-13)
20. **The per-site panel** opens from the address field (a site button beside it) and from View ▸ Settings for This Website. It shows camera, microphone, content blocking, zoom, user agent (from Task 16), and location and notifications once those exist, each with Ask / Allow / Block (or its own values) and "Reset This Site". It edits the same rows Settings ▸ Websites shows.

Downloads and prompts (plan 3's leftovers, matching mainstream behaviour):

21. **Background-tab dialogs wait** (R15 reversed): `alert`, `confirm` and `prompt` from a tab not shown are held until it is shown, then asked, as Chrome and Firefox do with tab-modal dialogs. A navigation or close resolves them (false or nil).
22. **The external-app question becomes tab-scoped:** it hides when its tab is not shown and comes back when it is, and it is dropped when the page navigates or moves to another window ("Bring It Here"), so a stale sheet can't open a link for a page the window no longer shows.
23. **The downloads popover** sits fully inside the window with one material, and the quarantine record carries the source page URL and the download URL (Gatekeeper then names the site).

Site compatibility:

24. **Per-site user agent:** Default, Safari, or Chrome on Mac, stored as a site value and applied as `customUserAgent` before each main-frame navigation to that host. The Chrome string names the current stable major version, kept in one constant that Part B's release checklist bumps.
25. **"Open in Safari" and "Open in Chrome"** appear in the page's View menu and the site panel only when that app is installed (`NSWorkspace.urlForApplication(withBundleIdentifier:)`). They pass the current URL and nothing else.

Release (Part B):

26. **Distribution copies Chorus's setup** (spec): a notarized, stapled DMG attached to a GitHub release tagged `vX.Y.Z`, a signed `docs/appcast.xml`, Sparkle 2.x in the app target, and a cask `stave.rb` in `nicojan/tap` (repo `nicojan/homebrew-tap`). Sparkle's update check sends no identifier, and Sparkle's system profiling stays off. The feed URL is `https://updates.nicojan.com/stave/appcast.xml` from the very first signed build, served by a Cloudflare Worker built like Chorus's: it passes through `docs/appcast.xml` from GitHub Pages and counts distinct machines per day with no install ID (as Chrome counts update checks). The Worker stores only a one-way hash of address, user agent and date with a secret salt, kept 48 hours, plus daily totals by version. Automatic update checks are on by default, with a Settings switch to turn them off. The README says plainly what a check sends (the app name and version in the User-Agent, and the Mac's IP address, which Cloudflare receives), what is stored and for how long, the free tier's ceiling of roughly 1,000 a day, and that counting never blocks an update. Whether updates also download and install by themselves is not decided (written down for Nico). (question 25, answered 2026-11-13)
27. **The Sparkle feed URL chosen for the first public build is permanent.** Chorus learned that every build ever shipped asks its first feed forever. So Part B picks the final URL before the first signed build, never a temporary one.
28. **Signing and notarizing run from a local script, not CI.** No certificate or notary password goes into GitHub. CI keeps building Debug and Release unsigned.

From the answers (2026-11-13):

29. **A several-downloads question that can't be asked now is held, not refused,** as Chrome does (it queues a tab's question until the tab is shown) and as the camera question already does. It waits in the wait-until-shown queue; later downloads from the same document wait behind it and follow its answer. A new committed document, closing the page or forgetting the tab drops it and refuses its downloads, with nothing recorded. Don't Allow refuses the rest of the document; Allow lets the rest through. Task 14 first checks that WebKit lets a held download wait; if it times the download out, only that download is refused. Task 14 builds it (question 7).
30. **The window follows the selected tab to another workspace.** When the selected tab is dropped on another workspace's icon, or sent there with Move to Workspace (a new tab command Task 4 adds; no keyboard route existed before), it moves without reloading, the window switches to that workspace and the tab stays selected. Safari, Chrome and Firefox have no workspaces, so Arc and Zen decide: Zen switches the window to the target workspace, and Arc's drag into another Space ends on that Space. A non-selected tab dropped on a workspace icon keeps today's behaviour (the window stays); that half is the session's own call, flagged for Nico. Task 4 builds it (question 8).
31. **Stave stays open with no windows,** as Safari, Chrome and Firefox do. Closing the last window leaves Stave running. A Dock click opens a browser window through the ⌘N path only when no browser window, normal or private, is open: with only Settings open it opens one, and with a private window open it brings that window forward. ⌘N and a link from another app open one. The last closed window stays in the saved set only until another browser window opens, so a later quit restores what was really open. Task 4 builds it (question 10).
32. **Remember keeps Block as well as Allow.** With "Remember for this site" ticked, Don't Allow is stored as Block for that profile and host, as Allow is; a stored Block denies without a sheet; the site panel and Settings ▸ Websites show it and can set it back to Ask. Private windows keep both answers in memory only. Task 13 builds it (question 11).
33. **The downloads list is kept per profile in the database** (migration `v7` `downloadRecord`), never for a private window. Clear History removes ended download rows in the same range (Safari and Firefox). Settings ▸ General has Safari's "Remove download list items": After one day (default), When Stave quits, Upon successful download, Manually. "After one day" trims at launch and on the daily maintenance tick; "When Stave quits" trims at quit (and at launch, for a quit that didn't finish); "Upon successful download" removes a row when its download finishes. Removing a row never touches the file. A finished row whose file is gone shows "File not found" with Show in Finder disabled. A download still running at quit shows as stopped after relaunch (no resume in the beta). Backups leave the list out (decision 1). Task 14 builds it (question 22).
34. **Archiving idle tabs is a setting, off by default,** following Arc (the three mainstream browsers lack it on the Mac). Settings ▸ Tabs has "Archive idle tabs after": Never (default), 12 hours, 1 day, 7 days, 30 days. A regular tab not viewed for longer than the limit goes to the profile's archive through the same path as closing it. Pinned tabs, Essentials, a tab shown in any window, private windows, and a tab playing media, holding pop-ups or downloading are never archived. "Not viewed" counts from when the tab was last left, not when it was selected; a tab shown at quit counts from the quit. The check runs at launch, after the saved windows are restored, and every 15 minutes. Split slots stay out until split-slot archiving (2.x). Task 16b builds it (question 27).

## Open questions for Nico

Each has my recommendation first, then the alternatives. Marks: **[Apple]** needs Nico's Apple account, **[TCC]** changes what macOS asks the user, **[Chorus]** needs an engine change made in Chorus and pinned back through an exact tag (Stave stays on 1.5.36 until then).

Nico answered all 29 on 2026-11-13: "Let's go with your recommendation for all of them. Make sure your recommendations are well-informed and -researched and based on users' existing mental models. Follow the most popular browsers and what they do." Each recommendation was checked against what Safari, Chrome and Firefox do on macOS, and some answers changed as a result. The records, with sources, are in `.superpowers/sdd/2026-11-10-stave-browser-basics/research-records-2026-11-13.json`; the answers are in `answers-2026-11-13.md` beside it. Where all three browsers agree, Stave does what they do; where two agree, it follows the two; where all three differ, it follows Safari for macOS conventions and Chrome for web-platform behaviour; for features they lack, Arc and Zen are the reference.

1. **How to split plan 5.** *Recommend:* two parts in this file now, built as two branches and PRs: Part A (browser basics, Tasks 1–20) then Part B (release, Tasks 21–25). Part A is useful alone: it makes Stave a default browser Nico can live in, so the two-week daily-driver clock in the beta gate can start when Part A lands, while Part B is built. Part B moves to its own file (`2026-11-10-stave-release.md`) in Task 20, once Part A's Outcome and Carried sections are written. *Alternatives:* one plan and one PR (very large to review); three parts (A1 data safety and tidy-ups, Tasks 1–4; A2 browser basics; B release).
   - **Answered 2026-11-13:** two parts, as recommended. Part A (Tasks 1–20) is built on `feat/browser-basics` and Part B (Tasks 21–25) on `feat/release`, branched from Part A's head, each with its own PR. The two-week daily-driver clock starts the day Nico makes Stave his default browser after Part A lands. Part B moves to its own file, `2026-11-10-stave-release.md`, in Task 20, after Part A's Outcome and Carried sections are written, so the release plan picks up Part A's carried items. Nothing moved when the answers were written in.
2. **Rolling backups.** *Recommend:* yes, as in decisions 1–2 (online backup at launch, hourly and before a migration; keep 10 hourly and 3 daily). *Alternatives:* no backups (Time Machine only); more copies (Zen keeps 20); daily only.
   - **Answered 2026-11-13:** yes, as decisions 1–2 say, with two additions found in the research. A copy leaves out history and (from Task 14) the downloads list, as Chrome's and Firefox's backups keep the user's organisation but never history, so Clear History is never undone by an old copy. The newest copy made before a migration is kept until the next migration. Each copy is one self-contained file (`journal_mode=DELETE`, nothing beside it).
3. **Restoring a backup.** *Recommend:* no in-app restore for the beta; the README gives the steps (quit, move `stave.sqlite`, `stave.sqlite-wal` and `stave.sqlite-shm` aside together, copy a backup in as `stave.sqlite`), says the copy has no history or downloads list, and Settings ▸ Advanced shows the folder. *Alternatives:* a "Restore from Backup…" command that first backs up the current file, then swaps and relaunches.
   - **Answered 2026-11-13:** as recommended: no in-app restore for the beta (Safari and Chrome have none; only Firefox restores, and only bookmarks). The README gives the steps: quit Stave, move `stave.sqlite`, `stave.sqlite-wal` and `stave.sqlite-shm` aside together, copy the chosen backup in as `stave.sqlite`, relaunch. It says a restored copy has no history or downloads list, and that Stave upgrades an older copy on open after backing it up first. Settings ▸ Advanced has "Show Backups in Finder". Task 1 writes the README steps, where backups are built.
4. **IDN hosts (`xn--` punycode) in the address field and monograms.** Today `bücher.example` shows as `xn--bcher-kva.example` with monogram "X". *Recommend for the beta:* the address field keeps showing punycode (safe against look-alike hosts), and the monogram uses the title when the host's first label starts with `xn--`. Later, decode to Unicode with a same-script check, as Chrome and Safari do. *Alternatives:* write an RFC 3492 decoder now and show Unicode when every label is in one script; show Unicode always (open to look-alike spoofing).
   - **Answered 2026-11-13:** the beta keeps the safe interim, as recommended: the address field shows punycode exactly as WebKit reports it, and the monogram comes from the title when the host's first label starts with `xn--` ("?" when the title is blank too). This differs on purpose from Safari, Chrome and Firefox, which all show a safe IDN in Unicode and fall back to punycode. The reason is scope and risk, not missing API. Stave will do the same in a later plan, using the public ICU calls in the macOS SDK (`uidna_nameToUnicode`, and `u_getIntPropertyValue` with `UCHAR_SCRIPT`) for a Safari-style script check; it is carried as a gap. Stored `SiteHost` keys stay punycode.
5. **A folder with a blank or whitespace-only title** reads to VoiceOver as ", folder, open, 0 items". *Recommend:* such a folder shows and reads as "Untitled Folder" (as Finder names new folders); creating or renaming to a blank name keeps the old name (or "Untitled Folder" for a new one); an Arc import keeps the blank title stored and shows "Untitled Folder". *Alternatives:* store "Untitled Folder" in place of the blank title on import and rename; drop the title from the label and say "folder" first.
   - **Answered 2026-11-13:** as recommended for display: a folder whose stored title is blank or only whitespace (any Unicode whitespace) shows and is read as "Untitled Folder", and the stored title is never rewritten, so an Arc import stays as imported. Creating a folder with a blank name keeps today's "New Folder" (what Chrome and Firefox name new folders), and renaming to a blank name keeps the old name, as the code already does.
6. **`https://user@host` links** (plan 3 decision 9). *Recommend:* keep opening them as other browsers do, with the address field showing only the real host. *Alternatives:* refuse them; open with a warning sheet.
   - **Answered 2026-11-13:** as recommended: plan 3 decision 9 stands. Such links open, and the address field shows only the real host. Chrome loads them silently and hides the user name; Firefox asks first. Safari 5 (2010) warned, but Safari 27.2's string tables, searched on this Mac on 2026-11-13 (read-only, Safari not launched), contain no such warning, nor do its shared frameworks or WebKit's, so Safari and Chrome agree. No warning sheet is built. If Nico sees Safari warn on `https://user@example.com/`, this flips to a tab-scoped warning sheet.
7. **A several-downloads question that can't be asked** (another sheet up, tab hidden). Before this plan, the code refused only that one download, and the next download asked again. *Recommend:* hold it until the tab is shown, like the camera question. *Alternatives:* refuse the rest of the document's downloads; keep refusing just that download.
   - **Answered 2026-11-13:** hold the question instead of refusing it, as Chrome does (it queues a tab's question until the tab is shown) and as Stave's camera question already does. It waits in the wait-until-shown queue; later downloads from the same document wait behind it and follow its answer; a new committed document, closing the page or forgetting the tab drops it and refuses its downloads, with nothing recorded. Don't Allow refuses the rest of the document; Allow lets the rest through (decision 29, Task 14).
8. **Dropping the selected tab on another workspace's icon.** Before this plan, the window stayed and selected a neighbour. *Draft recommendation (reversed by the answer):* keep that. *Alternatives:* the window follows the tab to its new workspace.
   - **Answered 2026-11-13:** the window follows the selected tab. When the selected tab is dropped on another workspace's icon, or sent there with Move to Workspace, it moves without reloading, the window switches to that workspace and the tab stays selected. Safari, Chrome and Firefox have no workspaces, so Arc and Zen decide: Zen's source switches the window to the target workspace, and Arc's drag into another Space ends on that Space. A non-selected tab dropped on a workspace icon keeps today's behaviour (the window stays); that half is the session's own call, flagged for Nico (decision 30, Task 4).
9. **A drifted pinned tab or Essential that is unpinned or restored.** Today its drifted page is archived so nothing is lost. *Recommend:* keep archiving (never lose data). *Alternatives:* refuse the unpin until it's reset; ask.
   - **Answered 2026-11-13:** as recommended: keep archiving. Unpinning, or a move or restore that makes a drifted pinned tab or Essential regular, keeps the page it now shows as a normal tab, with no prompt and no refusal, and its pinned page goes to the archive.
10. **Staying open with no windows.** Before this plan, closing the last window quit Stave. Safari, Chrome and Firefox all stay open on macOS. *Recommend:* stay open, as they do; the Dock icon or ⌘N opens a window, and a link from another app opens one. This also fixes the Dock-reopen-with-only-Settings-open case. *Alternatives:* keep quitting.
    - **Answered 2026-11-13:** stay open, as Safari, Chrome and Firefox do. Closing the last window leaves Stave running. A Dock click opens a browser window only when no browser window, normal or private, is open: with only Settings open it opens one, and with a private window open it brings that window forward. ⌘N and a link from another app open one. The last closed window stays in the saved set only until another browser window opens, so a later quit restores what was really open (decision 31, Task 4).
11. **Remember for Don't Allow, once the site panel exists** (plan 3, Nico's 2026-11-04 answer). *Recommend:* yes: Remember keeps Block as well as Allow, and the panel shows and clears both, as all three browsers do. *Alternatives:* keep remembering only Allow.
    - **Answered 2026-11-13:** yes, as recommended. With "Remember for this site" ticked, Don't Allow is stored as Block for that profile and host, as Allow is; a stored Block denies without a sheet; the site panel and Settings ▸ Websites show it and can set it back to Ask. Private windows keep both answers in memory only (decision 32, Task 13).
12. **The one-frame layout change while toggling compact mode** (plan 4's "Compact mode, sidebar only"). *Waits on Nico's by-hand check.* *Recommend:* fix it only if Nico sees a flash; the fix passes the compact layout into `BrowserWindowView` so the style and the layout change in one turn (now possible, since `feat/web-layer` holds both changes). *Alternatives:* fix it anyway; leave it.
    - **Answered 2026-11-13:** as recommended: fix it only if Nico sees a flash in his by-hand check; nothing is built until he reports one.
13. **Opening a local HTML file** (spec item 5 says Stave registers for HTML files, but plan 3's policy refuses every `file:` URL). *Recommend:* a new `NavigationSource.openedFile`, used only for a file the user opened in Finder or with File ▸ Open File… (⌘O); it loads with `loadFileURL(_:allowingReadAccessTo:)` and read access to that file only; links from it to other `file:` URLs stay refused; a stored or restored `file:` tab still shows the refused panel (it doesn't reload by itself after a restart). *Alternatives:* read access to the file's folder, as Safari does (pages that load sibling images work); drop HTML files from the spec.
    - **Answered 2026-11-13:** `NavigationSource.openedFile` for a file opened from Finder, dropped on a window, or chosen with File ▸ Open File… (⌘O, as in all three browsers). WebKit gets read access to the file's folder, so the sibling images and CSS that all three browsers load also load, or to the file alone when that folder is `/` or the home folder. A clicked link to a file inside that folder opens; outside it the refused panel shows; a script-started `file:` navigation is refused silently. A restored `file:` tab doesn't load by itself; its panel offers "Open Again". The gaps are deliberate: the three browsers load and link anywhere on disk and reload file tabs on restore (decision 6, Task 5).
14. **Where a link from another app lands.** The spec says a chosen profile and workspace, default the last used. *Recommend:* the last-active browser window; if it is on another workspace of the target profile it switches there; if no window shows the target profile, a new window opens on it; the tab goes to the top of regular tabs and is selected. *Alternatives:* always a new window; a small Little-Arc-style window (post-beta).
    - **Answered 2026-11-13:** the most recently active non-private browser window gets a new selected tab at the top of its regular tabs, and Stave comes to the front. A private window never receives it, as in Chrome and Firefox. With a chosen workspace, a window already showing it is preferred, then the most recently active window of that profile, switched there, then a new window on it. With no regular window open, a new window opens. Links that arrive before launch completes are queued and opened after restore, and reported, never dropped, if launch fails (decision 7, Task 5).
15. **History retention.** Safari keeps one year, Chrome 90 days. *Recommend:* Safari's one year, with Safari's choices in Settings (one day, one week, two weeks, one month, one year, manually). *Alternatives:* 90 days; no setting.
    - **Answered 2026-11-13:** Safari's one year by default, with Safari's choices in Settings ▸ General ("Remove history items": After one day, one week, two weeks, one month, one year, Manually). History is trimmed at launch and once a day, `historyVisit` rows only (decision 9, Task 6).
16. **A history view.** *Draft recommendation (changed by the answer):* history in the command bar plus History ▸ Clear History… for the beta, with the History view later. *Alternatives:* build the History view now; no ⌘Y until later.
    - **Answered 2026-11-13:** build the History view in Part A: Safari, Chrome and Firefox all have a full, searchable history view on ⌘Y. History ▸ Show All History (⌘Y) shows it in the front window's content area in place of the page, as Safari does, with search, visits grouped by day, open, Delete and Clear History…. Clear History removes history and (question 22) the downloads list. Not built, written down for Nico: Firefox and Safari also clear cookies and website data by default, and Chrome offers it in the same dialog, but that deletes user data outside the archive, which the project's rules reserve for Nico (decision 9, Task 6).
17. **⌘1–9.** Safari and Chrome select the nth tab, and ⌘9 the last. *Recommend:* ⌘1–8 select the nth tab in sidebar order (Essentials, then visible pinned tabs, then regular tabs), ⌘9 the last. *Alternatives:* count regular tabs only; leave ⌘1–9 unassigned.
    - **Answered 2026-11-13:** as recommended (Safari, Chrome and Firefox agree). ⌘1–⌘8 select the nth tab in sidebar order: Essentials, then pinned tabs that are visible (not inside a collapsed folder), then regular tabs. ⌘9 selects the last tab in that order. When the nth tab doesn't exist, ⌘n does nothing; with fewer than nine tabs, ⌘9 still selects the last one. An unloaded pinned tab counts and loads when selected, as a click does (Task 10).
18. **⌘D** (Safari: Add Bookmark; Chrome: Bookmark This Tab). Stave's bookmarks are pinned tabs. *Draft recommendation (changed by the answer):* ⌘D toggles pinning, as Arc does. *Alternatives:* leave unassigned.
    - **Answered 2026-11-13:** ⌘D pins the selected regular tab (the "bookmark this page" meaning all three browsers give ⌘D), at the end of its workspace's pinned tabs. It is disabled on a pinned tab or Essential, in a private window, with no tab selected and on a blank tab or failure panel, because no mainstream browser removes a bookmark with ⌘D. Unpin keeps its menu items without a shortcut. This departs from Arc's toggle (decision 16, Task 10).
19. **Location permission. [TCC]** Plan 3 found that WebKit asks through private SPI on macOS. *Recommend:* Task 17 starts with a spike on macOS 15 and 26. If the only route is WebKit's private delegate method, use it behind `responds(to:)` (direct distribution allows it) with Stave's own sheet, the same per-site rules as the camera, `NSLocationUsageDescription` and the `com.apple.security.personal-information.location` entitlement (macOS will ask the user too). *Alternatives:* deny location for the beta and say so; wait for a public API.
    - **Answered 2026-11-13:** build location the way all three browsers do. Each site asks with Stave's sheet (Allow / Don't Allow, Remember for this site). Answers are kept per profile and host with the camera's rules, including a remembered Block (question 11). A question from a hidden tab waits until its tab is shown. Private windows keep answers in memory. Stave implements the public macOS 27 selector and the private origin selector (both take a `WKPermissionDecision` handler) and never answers `.prompt`, so WebKit's own alert never shows. If the spike finds neither is called, location is denied there and the release notes say so. Task 17 is marked [TCC] and is not built in the 2026-11-13 session.
20. **Web notifications. [Chorus] [TCC]** *Recommend:* ask Chorus for engine change 1 (a public way to install the notification bridge on any `WKUserContentController`, handler name and JS globals configurable), then move the pin; Stave adds per-site permission and macOS's notification permission. Until the tag exists, Task 18 waits and the beta ships without web notifications. *Alternatives:* Stave writes its own small bridge (no engine change, but two copies of the same logic); notifications after the beta.
    - **Answered 2026-11-13:** as recommended: engine change 1 first; the beta ships without web notifications until the tag exists, and the release notes say so. When it is built, it follows the mainstream rules: the question shows only after a user gesture (without one the request is denied with no sheet); Allow and Don't Allow are both remembered per profile and host; Settings ▸ Websites gets "Allow websites to ask to send notifications", on by default; private windows deny without asking; clicking a notification shows its tab; macOS asks for Stave's own permission the first time an allowed site sends one. Task 18 waits; Chorus is not touched and the pin stays at 1.5.36.
21. **How Web Inspector opens.** `isInspectable` (public) makes pages inspectable from Safari's Develop menu. An in-app inspector and "Inspect Element" in the page menu need WebKit's private `developerExtrasEnabled` preference. *Draft recommendation (changed by the answer):* set both behind a Settings switch that is off by default, as Safari does. *Alternatives:* public API only (inspect from Safari's Develop menu).
    - **Answered 2026-11-13:** Chrome and Firefox both offer developer tools with no setting, so Stave does too: `developerExtrasEnabled` on every page gives Inspect Element and the in-app inspector, and an always-visible Develop menu uses Safari's names and keys (Show Web Inspector ⌥⌘I, Show Page Source ⌥⌘U). `isInspectable` stays off unless the spike shows the in-app inspector needs it. A missing private piece leaves its menu item disabled. Ruling, flagged for Nico: the in-app inspector's own front end keeps its state in WebKit's default persistent store under the app's bundle ID; Stave itself never calls `WKWebsiteDataStore.default()` and no page's data goes there, so normal windows get the inspector. Private windows get it only if the spike shows that opening it writes nothing that names the page; otherwise Inspect is off there and the gap is written down (decision 14, Task 9).
22. **Keeping the downloads list across restarts.** Plan 3 keeps it in memory. Safari, Chrome and Firefox keep it. *Recommend:* keep it per profile in the database (never for private windows), clearing finished rows by the same ranges as history. *Alternatives:* keep it in memory.
    - **Answered 2026-11-13:** keep the downloads list per profile in the database (migration `v7` `downloadRecord`), never for a private window. Clear History removes ended download rows in the same range (Safari and Firefox). Settings ▸ General gets Safari's "Remove download list items": After one day (default), When Stave quits, Upon successful download, Manually. Removing a row never touches the file; a finished row whose file is gone shows "File not found" with Show in Finder disabled; a download still running at quit shows as stopped after relaunch (no resume in the beta) (decision 33, Task 14).
23. **A third bundle ID for betas** (foundation Carried: the `.debug` data-folder mapping). *Recommend:* no beta bundle ID; the beta is the normal `com.nicojan.Stave` app at a 0.x version, so the mapping and the passkey identity stay as they are. *Alternatives:* `com.nicojan.Stave.beta` with its own data folder (a separate identity for Apple's passkey and Passwords approvals).
    - **Answered 2026-11-13:** no beta bundle ID; the beta is `com.nicojan.Stave` at 0.x, as Safari (0.8) and Chrome (0.2) shipped their first public betas. A pre-release channel offered later next to a stable release would get `com.nicojan.Stave.beta` and `Application Support/Stave-beta`, as Chrome's side-by-side Beta does, and only then does the data-folder mapping change.
24. **The Sparkle signing key.** *Recommend:* a new EdDSA key for Stave, backed up like Chorus's, so a leak of one doesn't cover both apps. *Alternatives:* reuse the Chorus and WatchMeType key.
    - **Answered 2026-11-13:** a new EdDSA key for Stave alone, in its own Keychain account `stave`, backed up the way the existing key is. Every `generate_keys`, `sign_update` and `generate_appcast` run for Stave passes `--account stave`, because without it the tools quietly use the existing shared key (Tasks 21–23).
25. **The update feed and counting.** The spec's call: count anonymously, like Chorus, and say so. *Recommend:* `https://updates.nicojan.com/stave/appcast.xml` through the same Cloudflare Worker pattern from the very first build (decision 27), passing through `docs/appcast.xml` served by GitHub Pages; README states that daily checks are counted with no identifier. *Alternatives:* GitHub Pages only, no counting.
    - **Answered 2026-11-13:** the Worker feed URL with ID-free daily counting, as recommended (following Chrome; Firefox uses a per-profile ID). Automatic checks are on by default with a switch to turn them off; Sparkle's system profiling stays off; the README says what a check sends and what the Worker keeps (decision 26). Automatic download-and-install of updates is a separate decision the question didn't ask; it is written down for Nico, not decided.
26. **The first public version number.** *Recommend:* `0.1.0` labelled "beta" in the release notes and About box, with `CURRENT_PROJECT_VERSION` counting up for Sparkle. *Alternatives:* `0.9.0`; `1.0.0-beta.1`.
    - **Answered 2026-11-13:** `0.1.0`, labelled "beta" in the release notes and the About window; later betas go up through 0.x and the label goes away at 1.0.0, as Safari, Chrome and Firefox did. `CURRENT_PROJECT_VERSION` (`CFBundleVersion`) is a plain integer that goes up by one for every build given to anyone, because Sparkle compares it. `1.0.0-beta.1` is not a valid marketing version on Apple's platforms. The About label is built at run time from `CFBundleShortVersionString`, adding "beta" while the major version is 0, so no version number is typed by hand (Task 21).
27. **Auto-archiving idle tabs** (spec: a setting, off by default). *Draft recommendation (changed by the answer):* leave it until after the beta, since it is off by default. *Alternatives:* build it in Part A.
    - **Answered 2026-11-13:** build it in Part A as a small task after Task 16, following Arc (the three mainstream browsers lack it on the Mac), but off by default as the spec says. Settings ▸ Tabs gets "Archive idle tabs after": Never (default), 12 hours, 1 day, 7 days, 30 days. Pinned tabs, Essentials, a tab shown in any window, private windows, and a tab playing media, holding pop-ups or downloading are never archived. "Not viewed" counts from when the tab was last left, not when it was selected. The check runs at launch and every 15 minutes (decision 34, Task 16b).
28. **Containers in the beta.** The spec's cut line puts containers after the beta, but nothing in the app can create a named container yet, so deletion has nothing to delete. *Draft recommendation (refined by the answer: Edit, not Rename):* the small Settings pane in decision 19 (create, rename, delete), since "New Tab in ‹container›" already exists. *Alternatives:* hide containers until after the beta.
    - **Answered 2026-11-13:** Firefox's and Zen's model: a per-profile Containers pane with Create, Edit and Delete; a name and a colour from the workspace palette, reusing `WorkspaceEditorRules`; no icons. Delete is refused while any open or archived tab uses the container, with the count (Stave's rule; Firefox closes the tabs, which would break never-lose-data). When allowed it asks first, and the store is removed only after the row is gone. Throwaway containers stay post-beta (decision 19, Task 12).
29. **Passkeys before the entitlement arrives. [Apple]** *Recommend:* a plain notice at first run and on a passkey request: "Passkeys need Apple's approval for Stave, which hasn't arrived yet. Use the Passwords app to copy sign-ins for now." Once granted, Task 19 adds the entitlement and provisioning profile. *Alternatives:* no notice.
    - **Answered 2026-11-13:** the notice text Nico approved stays as written. It shows on the first-run screen, in Settings ▸ Advanced, and as a passive banner (not a sheet) once per document when a page asks for a passkey. A suggested rewording goes to Nico, not into the text. Task 19 is marked [Apple] and is not built in the 2026-11-13 session.

## Written down for Nico (from the answers)

Not decided here; each needs Nico's call or his own check.

- **Backups keep a deleted profile's data after it is deleted** (question 2). Its workspaces, tabs and archive stay in the hourly and daily copies for up to 3 days, until they rotate out, and in the newest pre-migration copy until the next migration, however long that is. Decision 18's "This can't be undone" question mentions neither.
- **Remember is ticked by default** (question 11), so a plain Don't Allow becomes a lasting Block. That is closer to Chrome's explicit "Never allow" than to a dismissal; the site panel and Settings ▸ Websites are the way back.
- **Clear History and cookies** (question 16). Firefox and Safari also clear cookies and website data for the chosen range by default, and Chrome offers it in the same dialog. Not built: it deletes user data outside the archive, which the project's rules reserve for Nico. It is feasible with the public `WKWebsiteDataStore.removeData(ofTypes:modifiedSince:)` across every store of the profile, containers included, and would change decision 9, Review Focus 4 and `clearHistoryLeavesArchiveAndTabs`.
- **A non-selected tab dropped on another workspace's icon** keeps today's behaviour, and the window stays (question 8). That half is the session's own call.
- **The inspector's default store** (question 21). The in-app inspector's front end keeps its state in WebKit's default persistent store under the app's bundle ID. Stave never calls `WKWebsiteDataStore.default()` and no page's data goes there; whether private windows get the inspector depends on Task 9's spike.
- **Automatic download and install of updates** (question 25). Chrome and Firefox install updates automatically. If Nico wants it (`SUAutomaticallyUpdate = YES`), it becomes a new line in decision 26 and a second Settings switch ("Download and install updates automatically"), so turning off auto-install doesn't also turn off checks.
- **The passkey notice** (question 29). The suggested rewording is "Sign in with a password for now; the Passwords app can copy it." The approved text stays until Nico chooses.
- **The Account Holder role** (question 29). Apple's entitlement page asks for the Account Holder of an organization's Apple Developer account; an individual account may not qualify.
- **Safari and `user@host` links** (question 6). Nico checks Safari once: open `https://user@example.com/` in Safari. If it warns, question 6 flips to a tab-scoped warning sheet.
- **Folder-access prompts for opened files** (question 13). Opening an HTML file in Desktop, Documents or Downloads, and "Open Again" there, may make macOS ask for folder access (TCC). The session's checks under `/private/tmp` can't show it.
- **The several-downloads answer per site** (question 7, from the research). All three browsers keep that answer per site; Stave keeps it only for the document. It is a candidate row for the site panel after the beta.
- **A typed `file:` URL** (question 13, from the research). Task 15 keeps a typed `file:` URL as a search, while all three browsers open it.
- **⌘Y in a private window** (question 16, from the research). Whether the mainstream browsers offer the history view in a private window wasn't verified; disabling it there is Stave's choice.

## Review Focus

1. **A backup never touches the live database or anything outside `Backups/`.** A failed or half-written copy leaves no file under a final name; pruning with unrelated files in `Backups/` (`notes.txt`, `stave-old.sqlite`) leaves them alone. Tests: Task 1 `pruneKeepsOnlyOwnFiles`, `failedCopyLeavesNoFinalFile`.
2. **A link from another app with a hostile scheme or a `file:` URL** (`javascript:alert(1)`, `file:///etc/hosts`, `data:text/html,x`, a 100,000-character URL) never loads as a page; a `file:` URL loads only through the opened-file path (question 13) with read access to that file's folder only (the file alone when the folder is `/` or home). Tests: Task 5 `externalLinksPassThePolicy`, `openedFileReadsItsFolder`, `openedFileInHomeGrantsOnlyItself`, `openedFileAtRootGrantsOnlyItself`.
3. **Deleting a profile or container** asks first, removes its data stores only after its rows are gone and no live page uses them, and refuses the last profile and a container still used by a tab or an archived tab. Tests: Task 12 `profileDeletionNamesWhatGoes`, `storesRemovedOnlyAfterRows`, `removeRefusedWhileAPageUsesTheStore`, `removeDropsTheCachedStoreFirst`, `containerInUseRefusedWithCount`.
4. **History is never written for a private window, and Clear History removes only history and the downloads list,** never the archive, tabs or downloaded files. Tests: Task 6 `privateVisitsNeverStored` (in `PageHostTests`, through the real commit path), `clearHistoryLeavesArchiveAndTabs`; Task 14 `clearHistoryClearsEndedDownloads` (the files on disk are still there after their rows go, and a running download's row is kept).
5. **A hostile favicon** (2 GB response, HTML instead of an image, a redirect to `file:`, a 1 × 100,000 image, a slow trickle) is capped, never fetched with cookies, and falls back to the monogram without blocking the main thread. Tests: Task 7 `faviconBodyCapped`, `faviconRedirectToFileRefused`, `faviconRequestCarriesNoCookies`.
6. **An HTTP auth challenge names the real host of the frame that asks**, never the top page's when they differ, and a cancelled sheet sends no credentials. Tests: Task 11 `authNamesTheAskingFrame`, `cancelSendsNothing`.

---

## File structure

```
Packages/StaveCore/Sources/StaveCore/
├── Database/StaveDatabase.swift            # T6 v5 historyVisit; T9 v6 siteValue; T14 v7 downloadRecord (question 22)
├── Database/BackupPolicy.swift             # T1: names, schedule, which copies to keep, excludedTables
├── Database/DatabaseBackups.swift          # T1: the online copy, off the main actor
├── Sidebar/HostText.swift                  # T2: one host rule (lowercase, port, IPv6 brackets, www., IDN)
├── Sidebar/DisplayText.swift               # T2: monogram and address through HostText
├── Sidebar/SidebarRows.swift               # T2: blank folder label (question 5)
├── Web/SiteSettings.swift                  # T2: SiteHost through HostText
├── Window/PageChromeText.swift             # T4: "Loading", "n percent", "No tab selected", content-blocking enablement
├── Links/ExternalOpen.swift                # T5: link-from-another-app routing (question 14), OpenedFile.readAccessURL
├── Links/PendingLinks.swift                # T5: links that arrive before launch completes
├── OrganizationStore+History.swift         # T6
├── History/HistoryRanking.swift            # T6: command bar source
├── History/HistoryRetention.swift          # T6: retention choices (question 15)
├── History/HistoryText.swift               # T6: History view labels, day groups (question 16)
├── Web/FindState.swift                     # T8
├── Web/ZoomLevels.swift                    # T9
├── OrganizationStore+SiteValues.swift      # T9: zoom, user agent
├── Shortcuts/StandardShortcuts.swift       # T10
├── Web/AuthChallenge.swift                 # T11
├── Settings/SettingsCopy.swift             # T12
├── Settings/DeletionCopy.swift             # T12
├── Settings/ProfileDeletion.swift          # T12: the deletion flow, stores removed after the rows
├── Web/SitePanelModel.swift                # T13 (SitePanelSource); T16 user-agent row
├── Web/DownloadList.swift                  # T14 (hardening)
├── OrganizationStore+Downloads.swift       # T14: the kept downloads list (question 22)
├── Web/UserAgent.swift                     # T16 (per-site choices)
├── Session/AutoArchivePolicy.swift         # T16b: which idle tabs to archive (question 27)
├── OrganizationStore+AutoArchive.swift     # T16b
├── Settings/VersionText.swift              # T21: About label from CFBundleShortVersionString (question 26)
Packages/StaveCore/Sources/StaveWeb/
├── FaviconLoader.swift                     # T7
├── PageTools.swift                         # T8, T9: find, zoom, print, developer tools
├── PageDelegate+Auth.swift                 # T11
├── PageDelegate+Location.swift             # T17
├── PageConfiguration.swift                 # T9 developerExtrasEnabled; T18 notification bridge; T19 passkey banner script
Stave/App/
├── AppDelegate+Links.swift                 # T5 (also moves private-window routing out of AppDelegate, T4)
├── AutoArchiveTimer.swift                  # T16b: at launch and every 15 minutes
├── Updater.swift                           # T21
Stave/Views/
├── Content/HistoryView.swift               # T6 (question 16)
├── Content/FindBar.swift                   # T8
├── Content/AuthSheet.swift                 # T11
├── Settings/SettingsView.swift             # T12 (panes)
├── Settings/ProfilesPane.swift, ContainersPane.swift, WebsitesPane.swift, AdvancedPane.swift   # T12
├── Sidebar/SitePanel.swift                 # T13
Stave/Info.plist                            # T5 URL and document types; T17 location; T21 SUFeedURL, SUPublicEDKey
release/                                    # T22–T23: DISTRIBUTION.md, ExportOptions.plist, release.sh, homebrew/stave.rb
docs/appcast.xml                            # T22
THIRD_PARTY_NOTICES.md, README.md           # T1 (README backup and restore steps), T21, T24
```

---

# Part A: browser basics

### Task 1: Rolling database backups (question 2, answered 2026-11-13)

**Files:**
- Create: `Sources/StaveCore/Database/BackupPolicy.swift`, `Sources/StaveCore/Database/DatabaseBackups.swift`; `Tests/StaveCoreTests/BackupPolicyTests.swift`, `Tests/StaveCoreTests/DatabaseBackupsTests.swift`
- Modify: `Database/StaveDatabase.swift` (a hook to copy before migrating), `Stave/App/AppEnvironment.swift`, `README.md` (backup and restore steps, question 3)

**Interfaces:**
- Consumes: `StaveDatabase.writer`, `StavePaths`.
- Produces:
  - `public enum BackupKind: Sendable, Hashable { case regular, premigration }` (`regular` is a launch or hourly copy; question 2)
  - `public struct BackupCopy: Sendable, Hashable { let fileName: String; let date: Date; let kind: BackupKind }` (one file in `Backups/`; the kind travels with the date, so two copies made in the same second stay apart)
  - `public enum BackupPolicy { static let folderName = "Backups"; static func fileName(at: Date, kind: BackupKind) -> String` (`stave-YYYYMMDD-HHMMSS.sqlite` for `.regular`, `stave-YYYYMMDD-HHMMSS-premigration.sqlite` for `.premigration`, UTC) `; static func copy(fromFileName: String) -> BackupCopy?` (nil for anything not Stave's pattern; both patterns recognised, each giving its own kind) `; static func toDelete(existing: [BackupCopy], now: Date, hourly: Int = 10, dailyDays: Int = 3) -> [BackupCopy]` (the hourly and daily rule counts `.regular` copies only; of the `.premigration` copies only the newest is kept, however old, and it never takes an hourly or daily slot; the result is a subset of `existing`, so pruning deletes by `fileName`) `; static let interval: TimeInterval = 3600; static let excludedTables: [String] }` (empty in Task 1; Task 6 adds `historyVisit`, Task 14 adds `downloadRecord`; question 2)
  - `@MainActor public final class DatabaseBackups { init(database: StaveDatabase, folder: URL, excludedTables: [String] = BackupPolicy.excludedTables, now: @escaping () -> Date); func backUpNow() async -> Result<URL, BackupError>; func start(); func stop(); private(set) var consecutiveFailures: Int }`. `BackupPolicy.excludedTables` stays a `static let`; a test passes its own list to the init, never by changing the static (Swift Testing runs tests in parallel).
  - The copy itself is one static function, `DatabaseBackups.copy(from: any DatabaseReader, to folder: URL, kind: BackupKind, excludedTables: [String], now: Date) throws -> URL`, used by both `backUpNow()` and `StaveDatabase.open(at:backupBeforeMigrating:)` (which passes `BackupPolicy.excludedTables`).
  - `StaveDatabase.open(at:backupBeforeMigrating:)`: when a migration is pending and the file already has data, copy it to `Backups/` first (a `.premigration` copy); if that copy fails, open fails with `StoreError.backupFailed` and the file is untouched.

- [ ] **Step 1: Write failing tests**
  - `fileNamesRoundTrip`: for each kind, `copy(fromFileName: fileName(at: d, kind: k))` gives date `d` to the second and kind `k`; `"notes.txt"`, `"stave-old.sqlite"`, `"stave-20261110-999999.sqlite"`, `"stave-20261110-120000-other.sqlite"` give nil.
  - `keepsTenHourlyAndThreeDaily`: 40 copies an hour apart over two days plus one copy on each of the 5 days before → `toDelete` leaves the 10 newest, plus the newest of each of the last 3 days.
  - `pruneKeepsOnlyOwnFiles` (Review Focus 1): a folder with Stave copies and `notes.txt`, `stave-old.sqlite` → after pruning both strangers remain.
  - `backupIsAReadableCopy`: write a profile, `backUpNow()`, open the copy read-only → the profile is there, `PRAGMA quick_check` is `ok`, the copy's `journal_mode` is not `wal`, and no `-wal` or `-shm` file sits beside the final name.
  - `copyOmitsExcludedTables` (question 2): create a table `backupTestRows` holding rows, build `DatabaseBackups` with `excludedTables: ["backupTestRows", "noSuchTable"]` → the copy has `backupTestRows` with no rows, the missing table is skipped without error, and `quick_check` is `ok`.
  - `newestPremigrationCopyKept` (question 2): `toDelete` never returns the newest pre-migration copy, however old; an older pre-migration copy goes once a newer one exists. Same-second pair: a `.regular` and a `.premigration` copy share one timestamp (the launch backup and the copy made by `open(at:backupBeforeMigrating:)`), at 08:00:00 UTC, then 12 newer `.regular` copies an hour apart later the same day push the regular one out of the hourly slots and the daily slot of its day → `toDelete` returns the regular copy's file name and not the pre-migration one's.
  - `failedCopyLeavesNoFinalFile` (Review Focus 1): with the folder read-only, `backUpNow()` returns a failure, no file has a final name, and `consecutiveFailures == 1`.
  - `migrationBacksUpFirst`: a file migrated with `makeMigrator()` only up to the second-newest migration (as `WebStoreTests.migrationAddsSiteSetting` builds one with `migrate(_, upTo:)`; `upTo: "v3"` while Task 1 is built, since `v4` is then the newest), holding one profile row, then opened by `StaveDatabase.open(at:backupBeforeMigrating:)`, leaves exactly one `-premigration` copy in `Backups/`; that copy's `grdb_migrations` ends at the same identifier (`v3`) and it holds the profile, and the opened file ends at the newest migration. Control: opening a file already at the newest migration leaves `Backups/` empty or absent. Written this way, the test passes at Task 1 and stays valid as Tasks 6, 9 and 14 add migrations.
- [ ] **Step 2: Run** `swift test --package-path Packages/StaveCore --filter BackupPolicyTests` and `--filter DatabaseBackupsTests` → FAIL.
- [ ] **Step 3: Implement.** Copy to `<name>.partial` in the same folder; on the `.partial` file delete the rows of `excludedTables` that exist, `VACUUM`, set `journal_mode=DELETE` and close it; then `quick_check`, then `rename`. Run the copy off the main actor. Write the README's backup and restore steps (question 3): quit Stave; move `stave.sqlite`, `stave.sqlite-wal` and `stave.sqlite-shm` aside together (a stale `-wal` beside a different main file can corrupt it); copy the chosen backup in as `stave.sqlite`; relaunch. The README says a restored copy has no history or downloads list, and that Stave upgrades an older copy on open after backing it up first. The data folder is `Application Support/Stave` (`Stave-debug` for Debug testers). `AppEnvironment` starts backups after launch maintenance. Settings shows the failure message from Task 12 once `consecutiveFailures >= 3`.
- [ ] **Step 4: Run** the full package suite → PASS.
- [ ] **Step 5: By-hand check:** launch with a throwaway folder; `ls <folder>/data/Backups` shows one copy; relaunch → two; `sqlite3 -readonly` on a copy lists the tables.
- [ ] **Step 6: Commit** `feat: rolling database backups`

### Task 2: One host rule and the display-text bugs

**Files:**
- Create: `Sources/StaveCore/Sidebar/HostText.swift`; `Tests/StaveCoreTests/HostTextTests.swift`
- Modify: `Sidebar/DisplayText.swift`, `Web/SiteSettings.swift` (`SiteHost`), `Sidebar/SidebarRows.swift` (`SidebarLabels.folder`), `Window/BrowserWindowModel.swift` (`switchWorkspace(number:)`), `OrganizationStore.swift` (`deleteWorkspace`); `Tests/StaveCoreTests/SidebarRowsTests.swift`, `WebStoreTests.swift`, `BrowserWindowModelTests.swift`

**Interfaces:**
- Produces: `public enum HostText { static func host(of url: String) -> String?` (lowercased, port dropped, IPv6 kept in brackets, `www.` stripped once, nil when empty) `; static func isPunycode(_ host: String) -> Bool` (any label starts with `xn--`) `}`. `DisplayText.monogram`, `DisplayText.address` and `SiteHost.normalized` call it. `SidebarLabels.untitledFolder = "Untitled Folder"` (question 5), used only to display and label a stored title that is blank or only whitespace; the display path trims `.whitespacesAndNewlines`, as `SidebarMenus.folderTitle` does. The stored title is never rewritten. A new folder with a blank name keeps today's "New Folder" (`SidebarMenus.folderTitle`), and a blank rename keeps the old name.

- [ ] **Step 1: Write failing tests** (each one fails on today's code):
  - `uppercaseWWWIsStripped`: `DisplayText.address(for: "https://WWW.Example.com/a") == "example.com"`; `monogram` of that URL is `"E"` (today `"W"`).
  - `monogramIsOneCharacter`: titles `"ßeta"` → `"S"` (today `"SS"`), `"ﬁsh"` → `"F"` (today `"FI"`).
  - `monogramSkipsLeadingWhitespace`: title `"  lead"` → `"L"` (today `" "`); title `"   "` with no URL → `"?"`.
  - `punycodeMonogramUsesTitle` (question 4): URL `https://xn--bcher-kva.example`, title `"Bücher"` → `"B"` (today `"X"`); `address` stays `"xn--bcher-kva.example"`; with a blank title → `"?"`.
  - `siteHostAndDisplayAgree`: for `https://WWW.Example.com:8443/a`, `http://user@Example.NET/p`, `https://example.com@example.net/x`, `http://[::1]:8080/`, `https://xn--bcher-kva.example/`, `https://www./`, `DisplayText.address(for: u)` equals `SiteHost.normalized(u) ?? u`; IPv6 hosts keep their brackets in both.
  - `blankFolderLabel` (question 5): titles `""` and `"  "` → `"Untitled Folder, folder, open, 0 items"`; so do a title holding a newline and one holding only U+3000 (ideographic space).
  - Pins (they already pass; say so in the commit body): `folderTitle(typed: "  ", action: .newFolder) == "New Folder"`, and a blank rename returns nil.
  - `switchByNumberAtIntMin`: `switchWorkspace(number: Int.min)` and `Int.max` change nothing and don't trap.
- [ ] **Step 2: Run** `--filter HostTextTests`, `--filter SidebarRowsTests`, `--filter WebStoreTests`, `--filter BrowserWindowModelTests` → the new tests FAIL.
- [ ] **Step 3: Implement** decisions 3–5. Remove the unreachable `deleteWorkspace` guard with a one-line comment (tabs are fetched by those slots' IDs). Existing `DisplayText` and `SiteHost` tests pass unedited.
- [ ] **Step 4: Run** the full package suite → PASS.
- [ ] **Step 5: Commit** `fix: one host rule for display and site keys, and one-letter monograms`

### Task 3: Store tidy-ups and missing tests from plans 1–4

**Files:**
- Modify: `OrganizationStore.swift`, `OrganizationStore+ArcImport.swift`, `OrganizationStore+Imports.swift`, `Window/BrowserWindowModel.swift`; tests across `StaveCoreTests` and `StaveWebTests`

**Interfaces:**
- Produces: one public API change (amended 2026-11-14, preflight T3 row 1): `OrganizationStore.importArc(_:expectingLastImport:)` replaces `importArc(_:)`, both `ArcImporter.run` overloads gain `expectingLastImport: Date? = nil`, and `StoreError` gains `importChanged`, because refusing the second of two concurrent imports while still allowing a confirmed repeat needs a compare-and-set input. Nothing else public is added. Removes dead `renameWorkspace` (replaced by `updateWorkspace`) and `navigateSelected` if nothing calls them (check with `command grep -rn` across `Stave/` and both packages first; keep and test any that has a caller). Moves the repeat-import check inside the import's own write transaction (plan 4's Carried). `deleteWorkspace` and `BrowserWindowModel.reload()` stop reading archived IDs and tab existence with `try?`: a read failure becomes `lastError`.

- [ ] **Step 1: Write failing tests** (plans 2, 3 and 4 listed them):
  - `repeatImportCheckedInsideTheTransaction`: two imports started together from the same file write one import and refuse the other.
  - `deleteWorkspaceWithPinnedInFolder` archives the folder's tabs.
  - `reloadReportsAReadFailure`: a store whose read throws sets `lastError` and keeps the last snapshot.
  - From plan 3's "Missing tests": the unique `(profileID, host, key)` index; a v3 file has no `siteSetting` table before migrating (control); `MAILTO:`, `ABOUT:BLANK` and typed `data:` through `NavigationPolicy`; flush resetting the recorder's throttle clock; same-state commit; the idle-plus-overflow union in `HibernationPolicy`; `#expect(ready)` gets a failure message; the `EngineLinkTests` 60 s timeout task is cancelled.
  - From plan 2's "can wait": `profile: null` → `.unrecognized`; the scheme-table cases `"foo bar:x"`, `"1http://x"`, `":"`; the store clock stamps imported records; the doubling-folders test fails by itself rather than hanging.
- [ ] **Step 2: Run** the full suite → the new tests FAIL where the code is missing, PASS where they only pin behaviour (note which in the commit body).
- [ ] **Step 3: Implement.** Remove the unused `StaveWebTests` dependency on `StaveCore` only if the build still passes. (Amended 2026-11-14: not removed. Six `StaveWebTests` files `import StaveCore`, so the dependency is in use; preflight T3 row 5.)
- [ ] **Step 4: Run** the full package suite and both app builds → PASS.
- [ ] **Step 5: Commit** `refactor: store tidy-ups and the tests deferred from plans 1-4`

### Task 4: Strings out of views and app-side leftovers

**Files:**
- Create: `Sources/StaveCore/Window/PageChromeText.swift`, `Stave/App/AppDelegate+Private.swift`; `Tests/StaveCoreTests/PageChromeTextTests.swift`
- Modify: `Stave/Views/Content/PageContentView.swift`, `TabPlaceholderView.swift`, `Stave/Views/Settings/SettingsView.swift`, `Stave/App/AppDelegate.swift`, `Stave/App/AppMenuState.swift`, `Stave/App/StaveApp.swift` (Tab ▸ Move to Workspace), `Window/BrowserWindowModel.swift`, `Window/PageMenuState.swift`, `Sidebar/SidebarMenus.swift` (`TabMoveTarget` and `SidebarMenus.moveTargets`; `SidebarAction` is not changed), `Stave/Views/Sidebar/SidebarPresenter.swift`, `Session/WindowSession.swift` (doc comment); `Tests/StaveCoreTests/BrowserWindowModelTests.swift`, `SidebarMenusTests.swift`, `WindowSessionTests.swift`

**Interfaces:**
- Produces: `PageChromeText.loadingLabel` ("Loading"), `progressValue(_ fraction: Double) -> String` ("‹n› percent", clamped 0–100, NaN → "0 percent"), `noSelection` ("No tab selected"), `dataNotOpen` ("Stave's data is not open."); `PageMenuState.contentBlockingEnabled(url:)` (false for `about:blank`, blank and non-web URLs; the rule moves out of the app).
- App leftovers: the ⌘N nested-sheet gate bypass closed (⌘N disabled while a sheet is up, like the other window commands); a failed workspace delete leaves the window on the workspace it was on; private-window routing moves into `AppDelegate+Private.swift` so `AppDelegate.swift` drops under 400 lines.
- Staying open with no windows (decision 31, question 10): `applicationShouldTerminateAfterLastWindowClosed` returns false; `applicationShouldHandleReopen(_:hasVisibleWindows:)` opens a browser window through the ⌘N path only when no browser window, normal or private, is open (Settings doesn't count; with a private window open it brings that window forward); the window kept after the last close leaves the saved set when any browser window opens, which plan 4 already does (`WindowSession.discardStates(exceptLive:)`, called by `AppDelegate.open`, pinned by `WindowRulesTests.closingTheLastWindowKeepsItUntilANewWindowOpensWithNoneLive`). The `AppDelegate` doc comment on quitting and `WindowSession.windowClosed`'s doc comment are updated to match.
- Move to Workspace is new: no tab-level command existed (the only cross-workspace move was the drop target `SidebarDropTarget.workspace(UUID)`). It is not a `SidebarAction` case: that enum is `CaseIterable` with no payloads (`SidebarMenusTests.everyActionHasATitleAndSymbol` and `KeyboardMenuTests.menuTitlesAreNonEmptyAndAskingActionsEndInAnEllipsis` loop over `allCases`), and its `title` and `symbol` could not name the workspace. `SidebarAction` stays payload-free and keeps its synthesized `allCases`. The command is a separate value: `public struct TabMoveTarget: Hashable, Sendable { public let workspaceID: UUID; public let title: String }` (`title` is "Move to ‹workspace name›"; the menu symbol is the target workspace's `icon`), built by `SidebarMenus.moveTargets(for item: SidebarItemID, currentWorkspaceID: UUID, workspaces: [Workspace]) -> [TabMoveTarget]`: one target per other workspace of the profile, in switcher order (`BrowserWindowModel.workspaces` order), and `[]` for a folder or when the profile has one workspace. The model runs it through an overload beside the existing `run(_:on:)` (`BrowserWindowModel.swift:336`): `@discardableResult public func run(_ target: TabMoveTarget, on item: SidebarItemID) -> Bool`, which returns `drop(item, onto: .workspace(target.workspaceID))`, so it performs exactly the drop's move and refuses what the drop refuses. The tab context menu lists the targets after the row's `SidebarAction`s (a "Move to Workspace" submenu in `SidebarPresenter`), and Tab ▸ Move to Workspace lists the same targets for the highlighted tab, so menu and context menu come from one list.
- The window follows the selected tab (decision 30, question 8): dropping the selected tab on another workspace's icon (`BrowserWindowModel.drop(.tab(id), onto: .workspace(w))`), or sending it there with Move to Workspace, moves it without reloading, switches the window to that workspace and keeps the tab selected. A non-selected tab dropped on a workspace icon keeps today's behaviour (the window stays). The doc comment on `BrowserWindowModel.apply(_:)`, which says a tab that leaves the workspace clears the selection, is fixed.

- [ ] **Step 1: Write failing tests:** `progressValueIsClamped` (−0.2, 0.5, 1.7, NaN), `contentBlockingDisabledOnBlank`; in `BrowserWindowModelTests` `failedDeleteKeepsTheWorkspace` and `selectedTabMovedToWorkspaceIsFollowed` (through `drop(_:onto: .workspace(_))` and through `run(_ target: TabMoveTarget, on:)` with a target taken from `SidebarMenus.moveTargets`, never a hand-built one: the window's workspace is the target, the selection is the moved tab, and the page is not reloaded), with a control that a non-selected tab moved away leaves the window where it was; in `SidebarMenusTests`, `moveTargetsListTheOtherWorkspaces` (three workspaces with the second current: the targets are the first and third in switcher order, titled "Move to ‹name›", the current one never appears; a folder gets `[]`; a profile with one workspace gets `[]`) and `everyActionHasATitleAndSymbol` still passing unchanged over the synthesized `SidebarAction.allCases`; in `WindowSessionTests`, `keptLastWindowSurvivesStayingOpen` (a pin that passes today: close the last window A with `isLast: true`, no window open, `saveNow()` → restored [A]; then `discardStates(exceptLive: [])` and update B → restored [B]). The replace-on-open fix already exists (`discardStates`, `WindowRulesTests.closingTheLastWindowKeepsItUntilANewWindowOpensWithNoneLive`); say so in the commit body.
- [ ] **Step 2: Run** → FAIL.
- [ ] **Step 3: Implement.** `command grep -rn 'Text("' Stave/Views` afterwards lists no literal user-facing string outside previews.
- [ ] **Step 4: Run** the suite and both builds → PASS.
- [ ] **Step 5: By-hand check:** ⌘N with the archive sheet up does nothing; closing the last window leaves Stave running and ⌘N opens one; a Dock click with only Settings open opens a browser window; a Dock click with only a private window open opens nothing new; close the last window, press ⌘N, quit, relaunch → exactly one window comes back. Tab ▸ Move to Workspace on the selected tab from the keyboard → the window shows the target workspace with the tab selected and not reloaded. **Nico checks:** dragging the selected tab onto another workspace's icon (drag is pointer-only), and a non-selected tab, where the window stays.
- [ ] **Step 6: Commit** `refactor: page chrome text in StaveCore and app-side leftovers`

### Task 5: Default browser and links from other apps (questions 13 and 14, answered 2026-11-13)

**Files:**
- Create: `Sources/StaveCore/Links/ExternalOpen.swift` (with `OpenedFile`), `Sources/StaveCore/Links/PendingLinks.swift`, `Stave/App/AppDelegate+Links.swift`; `Tests/StaveCoreTests/ExternalOpenTests.swift`, `Tests/StaveWebTests/OpenedFileTests.swift`
- Modify: `Stave/Info.plist`, `project.yml` (Debug display name), `Web/NavigationPolicy.swift` (`.openedFile`), `Settings/SettingKey.swift` (`externalLinkTarget`), `Sources/StaveWeb/PageHost.swift`, `Stave/App/StaveApp.swift` (File ▸ Open File… ⌘O), `Stave/App/BrowserWindowController.swift` (an HTML file dropped on the window)

**Interfaces:**
- Produces:
  - `NavigationSource.openedFile` (decision 6, question 13): allows the opened file, plus a user-clicked main-frame `file:` link inside the tab's granted folder; a link outside it gets the refused panel, and a script-started `file:` navigation is refused silently. The granted folder is the file's folder, or the file alone when that folder is `/` or the home folder. It is kept per tab, in memory, never stored, and passed to the policy as input. Other sources keep refusing `file:`. A restored `file:` tab shows the refused panel with "Open Again", which reloads it through the opened-file path.
  - `public enum OpenedFile { static func readAccessURL(for file: URL, home: URL) -> URL }` in StaveCore: the file's folder, or the file itself when that folder is `/` or `home`; paths are standardized and symlinks resolved first. The app passes `FileManager.default.homeDirectoryForCurrentUser`; tests pass synthetic paths.
  - `public enum ExternalLinkTarget: Codable, Sendable, Equatable { case lastUsed, workspace(profileID: UUID, workspaceID: UUID) }` and `SettingKeys.externalLinkTarget` (default `.lastUsed`).
  - `public struct WindowSummary: Sendable, Equatable { windowID: UUID; profileID: UUID; workspaceID: UUID }` and `public enum ExternalOpen { static func route(target: ExternalLinkTarget, windows: [WindowSummary], workspacesByProfile: [(profileID: UUID, workspaceIDs: [UUID])], lastSession: (profileID: UUID, workspaceID: UUID)?) -> ExternalRoute? }` (decision 7, question 14). `windows` holds the non-private browser windows only, most recently active first. `workspacesByProfile` lists every existing profile in sidebar order with its workspaces in sidebar order, so `route` can tell that a target was deleted and name a profile's first workspace. `lastSession` is the newest saved window state (`WindowSession.states.last`, else the first restored window). `ExternalRoute { case existing(windowID: UUID, switchTo: UUID?), newWindow(profileID: UUID, workspaceID: UUID) }`. `.lastUsed` → the first window, on whatever workspace it shows. A chosen workspace → the first window already showing it; else the first window of that profile, switched there; else a new window on it. No window → a new window: for `.lastUsed`, on `lastSession` (this relies on `WindowSession.discardStates`, plan 4), or on the first profile's first workspace when `lastSession` is nil or names something deleted. A target whose workspace was deleted falls back to its profile's first workspace; a deleted profile falls back to `.lastUsed`. The result is nil only when there is no profile at all, which the caller reports.
  - `@MainActor public final class PendingLinks` in StaveCore, the queue for links that arrive before launch completes: `func enqueue(_ urls: [URL])`, `func drain() -> [URL]` (called once the saved windows are restored; returns the queued links in arrival order and empties the queue), `func failAll() -> [URL]` (called when launch fails; returns every queued link for the report and empties the queue). `AppDelegate` calls it and holds no queue logic of its own.
  - `AppDelegate.application(_:open:)` handles each URL in order: web URLs through the policy as `.typed`, HTML files through `.openedFile`. A URL longer than 32,768 characters is refused with the refused panel. URLs that arrive before `launchCompleted` go into `PendingLinks` and are opened after the saved windows are restored (today `newWindow()` and the other entry points return silently then); if launch fails, `failAll()`'s links are reported to the user, never dropped.
  - Settings ▸ General: "Make Stave your default browser" (disabled with "Stave is your default browser" when it already is) and "Open links from other apps in" (Last used / a profile and workspace).

- [ ] **Step 1: Write failing tests**
  - `externalLinksPassThePolicy` (Review Focus 2): `javascript:alert(1)`, `file:///etc/hosts`, `data:text/html,x` as `.typed` → refused; a 100,000-character URL → refused before the policy.
  - `openedFileReadsItsFolder` (Review Focus 2, the WebKit test in `OpenedFileTests`, using a temp folder): a temp `a.html` with an `<img src="b.png">` sibling and a link to `file:///etc/hosts`: the page loads, `b.png` loads, the read-access URL passed to WebKit is the parent folder, and the link is refused.
  - `openedFileInHomeGrantsOnlyItself` and `openedFileAtRootGrantsOnlyItself` (Review Focus 2, in `ExternalOpenTests`, creating no files): `OpenedFile.readAccessURL(for: /Users/test/a.html, home: /Users/test)` and `readAccessURL(for: /a.html, home: /Users/test)` are the file itself; a control, `/Users/test/site/a.html`, gives `/Users/test/site`.
  - `linkInsideFolderOpens` (a user-clicked link to a sibling file opens) and `scriptFileNavigationRefused` (a script-started `file:` navigation is refused with no panel).
  - `routes`: last-used window on the right workspace → `.existing(switchTo: nil)`; on another workspace of the profile → `.existing(switchTo: w)`; no window on the profile → `.newWindow`; deleted workspace → its profile's first; deleted profile → as `.lastUsed`; no profile at all → nil.
  - `privateWindowsNeverReceiveLinks`, `windowAlreadyOnWorkspacePreferred`, `noWindowsOpensNew` (`.lastUsed` with no window → `.newWindow` on `lastSession`; with `lastSession` nil → the first profile's first workspace).
  - `linksBeforeLaunchAreQueued` (on `PendingLinks`: links enqueued before launch come back from `drain()` in arrival order, and the queue is then empty) and `launchFailureReportsQueuedLinks` (`failAll()` returns every queued link, none is lost, and a later `drain()` is empty).
  - `restoredFileTabIsRefused`: a stored `file:` URL restored at launch still shows the refused panel, with an "Open Again" button.
- [ ] **Step 2: Run** `--filter ExternalOpenTests`, `--filter OpenedFileTests`, `--filter NavigationPolicyTests` → FAIL.
- [ ] **Step 3: Implement** decisions 6–8. Every opened page sets `openedByUser = true`.
- [ ] **Step 4: Run** the suite and both builds → PASS.
- [ ] **Step 5: By-hand check** (Debug build): Settings ▸ General ▸ Make default → macOS asks; choose "Stave Debug". `open https://example.com` from Terminal → a new top tab in the last-used window. `open -a "Stave Debug" /private/tmp/<folder>/a.html` → the page loads with its sibling image (kept under `/private/tmp`, so macOS asks for no folder access); ⌘O opens the same file. `capture-window.swift Stave` and `ax-dump.sh Stave` still find the app (decision 8); if not, adjust the scripts, not the bundle. Afterwards Nico sets his real default browser back (his call). **Nico checks:** a link from Mail and from Slack; a link while Stave isn't running; an HTML file in `~/Downloads` and in `~/Desktop` (do its sibling images load, and does macOS ask for folder access?).
- [ ] **Step 6: Commit** `feat: Stave as the default browser, and links from other apps`

### Task 6: History and the History view (questions 15 and 16, answered 2026-11-13)

**Files:**
- Create: `Sources/StaveCore/OrganizationStore+History.swift`, `History/HistoryRanking.swift`, `History/HistoryRetention.swift`, `History/HistoryText.swift`, `Stave/Views/Content/HistoryView.swift`; `Tests/StaveCoreTests/HistoryTests.swift`
- Modify: `Tests/StaveWebTests/PageHostTests.swift` (`privateVisitsNeverStored`), `Database/StaveDatabase.swift` (migration `v5`: `historyVisit(id, profileID → cascade, url, title, visitedAt, modifiedAt)` with an index on `(profileID, visitedAt)`), `CommandBar/CommandTypes.swift`, `CommandBar/CommandBarSearch.swift`, `OrganizationStore+CommandBar.swift`, `Sources/StaveWeb/PageHost.swift` (record on commit), `Sources/StaveWeb/LivePage.swift` (`PageWriter` gains the visit call; a page with no `siteSettingsProfileID` never makes it), `Stave/App/StaveApp.swift` (History menu), `Settings/SettingKey.swift` (`historyRetention`), `Database/BackupPolicy.swift` (`excludedTables` gains `historyVisit`)

**Interfaces:**
- Produces: `recordVisit(profileID:url:title:at:) throws` (merges a repeat within 30 minutes), `updateVisitTitle(profileID:url:title:) throws`, `history(profileID:matching:limit:) throws -> [HistoryVisit]`, `historyPage(profileID:matching:before:limit:) throws -> [HistoryVisit]` (for the History view), `deleteVisits(ids:) throws -> Int`, `clearHistory(profileID:since: Date?) throws -> Int` (Task 14 extends it to ended download-list rows), `trimHistory(retention: HistoryRetention) throws -> Int` (run in `launchMaintenance` and once a day); `public enum HistoryRetention { day, week, twoWeeks, month, year, manually }` (default `.year`; `.manually` trims nothing) with Safari's labels ("After one day" … "Manually"); `CommandResult.history(HistoryVisit)` ranked after open tabs and before archived tabs; `HistoryClearRange` (lastHour, today, todayAndYesterday, all) with titles; `HistoryText` labels for the History view (title, search field, day headings, Delete, Clear History…, empty state).
- The History view (decision 9, question 16): History ▸ Show All History (⌘Y) shows it in the front window's content area in place of the page; it is not a tab and not saved in the session; ⌘Y returns to the page. A focused search field; visits newest first, grouped by local day; Return or double-click opens a visit; Delete removes the selected visits; a Clear History… button. Disabled in a private window.

- [ ] **Step 1: Write failing tests:** `visitRecordedOnce` (two commits 10 minutes apart → one row, newest time), `visitsSeparateAfterThirtyMinutes`, `titleArrivesLater`, `privateVisitsNeverStored` (Review Focus 4, in `PageHostTests`: a page made with `siteSettingsProfileID: nil` commits a local HTML string and `FakeWriter` records no visit call, with a control where the same page with a profile ID records exactly one; mutation-check it by removing the nil guard and confirming the test fails), `clearHistoryLeavesArchiveAndTabs` (Review Focus 4), `clearRanges`, `trimByRetention` (covers the one-year default and `.manually`, which trims nothing), `historyRanksAfterOpenTabs`, `nonWebURLsNotRecorded` (`about:blank`, refused URLs), `profileDeletionCascades`, `deleteVisitsLeavesArchiveAndTabs`, `historyGroupsByDay` (with a fixed time zone and calendar), `privateWindowHasNoHistoryView`, `backupLeavesOutHistory` (a backup copy has the `historyVisit` table with no rows).
- [ ] **Step 2: Run** `--filter HistoryTests`, `--filter CommandBarTests` and `--filter PageHostTests` → FAIL.
- [ ] **Step 3: Implement** decision 9. Trim at launch maintenance and once a day while Stave runs. A history result, in the command bar or the History view, opens through the policy with `openedByUser = true`. The blank "New Tab" ranking leftover from plan 4 is settled here: blank tabs rank last.
- [ ] **Step 4: Run** the suite → PASS.
- [ ] **Step 5: By-hand check:** visit three local pages, ⌘T, type part of a title → the history row appears; ⌘Y → the History view with today's visits, the search field focused; type part of a title → filtered; select one, Delete → gone; select another, Return → it opens; ⌘Y again → back to the page. History ▸ Clear History… ▸ the last hour → gone; the archive is unchanged.
- [ ] **Step 6: Commit** `feat: history recording, the History view and Clear History`

### Task 7: Favicons in the sidebar

**Files:**
- Create: `Sources/StaveWeb/FaviconLoader.swift`; `Tests/StaveWebTests/FaviconLoaderTests.swift`
- Modify: `Stave/Views/Sidebar/SidebarRowView.swift`, `EssentialsGrid.swift`, `Stave/Views/CommandBar/CommandBarView.swift`, `Stave/App/AppEnvironment.swift`

**Interfaces:**
- Produces: `@MainActor public final class FaviconLoader { init(cacheFolder: URL?, configuration: URLSessionConfiguration = FaviconLoader.configuration(), maxBytes: Int = 524_288, maxFiles: Int = 2000); static func configuration() -> URLSessionConfiguration` (`.ephemeral` with `httpCookieStorage = nil`, `httpShouldSetCookies = false`, `urlCredentialStorage = nil`, `urlCache = nil`; the loader makes its own session from it) `; func image(for faviconURL: String?) -> NSImage?` (cached only) `; func load(_ faviconURL: String) async -> NSImage?; func prune() }`. `cacheFolder == nil` means memory only (private windows).

- [ ] **Step 1: Write failing tests** with a `URLProtocol` stub (no network). Tests take `FaviconLoader.configuration()` and add only the stub to its `protocolClasses`, so they exercise the production configuration, never a session of their own: `faviconBodyCapped` (Review Focus 5: a 2 MB body → nil, the transfer is cancelled at the cap), `faviconRedirectToFileRefused`, `faviconRequestCarriesNoCookies` (the stub sees no `Cookie` header with a cookie set in the shared store; it also asserts the four properties above on `FaviconLoader.configuration()` itself), `htmlBodyIsNotAnImage`, `cachedOnDiskByHash`, `pruneKeepsNewest`, `privateLoaderWritesNoFiles`, `decodeOffMain` (the main actor keeps running during a slow decode stub).
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

### Task 9: Zoom per site, print and Web Inspector (question 21, answered 2026-11-13)

**Files:**
- Create: `Sources/StaveCore/Web/ZoomLevels.swift`, `OrganizationStore+SiteValues.swift`; `Tests/StaveCoreTests/ZoomAndSiteValueTests.swift`
- Modify: `Database/StaveDatabase.swift` (migration `v6`: `siteValue(id, profileID → cascade, host, key, value TEXT, modifiedAt)`, unique `(profileID, host, key)`), `Sources/StaveWeb/PageTools.swift`, `PageHost.swift`, `PageConfiguration.swift` (`developerExtrasEnabled`), `Stave/App/StaveApp.swift` (the Develop menu); `Tests/StaveWebTests/PageHostTests.swift` (`privateZoomNotStored`, `zoomResetsOnHostWithoutValue`)

**Interfaces:**
- Produces: `public enum SiteValueKey: String { case zoom, userAgent }`; `siteValue<V: Codable>(profileID:host:key:as:) throws -> V?`, `setSiteValue(profileID:host:key:_:) throws` (nil removes); `ZoomLevels.levels`, `next(after:)`, `previous(before:)`, `isDefault(_:)`; `PageTools.print(_ webView:, title:)`; `developerExtrasEnabled` on every page (decision 14), with no setting; an always-visible Develop menu with Show Web Inspector (⌥⌘I) and Show Page Source (⌥⌘U), each disabled when the private piece it needs is missing.

- [ ] **Step 1: Write failing tests:** `zoomStepsThroughSafariLevels` (100 → 115 → 125; at 300 stays; at 50 stays), `zoomStoredPerHostAndProfile`, `defaultZoomRemovesTheRow`, `siteValueIndexIsUnique`, `migrationAddsSiteValue`; in `PageHostTests` (StaveWebTests), `privateZoomNotStored` (a page with `siteSettingsProfileID: nil` zooms in, the fake site-value source records no write, and another private page on the same host and session gets the same zoom from memory; that memory goes with `leavePrivateSession`, as `privateMediaAnswers` does) and `zoomResetsOnHostWithoutValue` (a page at a stored 1.5 on host A commits host B with none → `pageZoom == 1.0`).
- [ ] **Step 2: Run** → FAIL.
- [ ] **Step 3: Spike, then implement.** First a spike (one attempt, decision 14) on macOS 15 and 26, answering three things, recorded in the commit body: does the in-app inspector open with `developerExtrasEnabled` alone, or does it also need `isInspectable`; what does opening it write under `~/Library/WebKit/com.nicojan.Stave.debug` (and `com.nicojan.Stave`) and in the app's defaults (WebKit's default store); and does any of it name a private window's page. If it does, Inspect is off in private windows and the gap is written down for Nico. Then implement decisions 12–14. On every main-frame commit the page's `pageZoom` is set to the host's stored value, or 1.0 when none is stored.
- [ ] **Step 4: Run** → PASS; build.
- [ ] **Step 5: By-hand check:** ⌘+ twice on a local page, open another page on the same host → same zoom; relaunch → kept; ⌘0 → 100 % and the row is gone. ⌘P shows the print panel (Cancel). Right-click ▸ Inspect Element opens the inspector; ⌥⌘I opens it; ⌥⌘U shows the page source. In a private window, the result the spike chose. **Nico checks:** printing to PDF.
- [ ] **Step 6: Commit** `feat: zoom per site, print and Web Inspector`

### Task 10: The standard shortcut set (questions 16, 17 and 18, answered 2026-11-13)

**Files:**
- Create: `Sources/StaveCore/Shortcuts/StandardShortcuts.swift`; `Tests/StaveCoreTests/StandardShortcutsTests.swift`
- Modify: `Stave/App/StaveApp.swift`, `Window/BrowserWindowModel.swift` (`selectTab(number:)`, `selectAdjacentTab(_:)`, `reopenLastClosed()`, `PageLifecycle.tabOpenedByUser(_:)`), and every `PageLifecycle` conformer (the app's page host and the test fakes)

**Interfaces:**
- Produces: `public struct ShortcutEntry { command: ShortcutCommand; key: String; modifiers: ShortcutModifiers; menu: MenuName }` and `StandardShortcuts.all`; `BrowserWindowModel.selectTab(number:)` per question 17 (⌘1–⌘8 the nth tab in sidebar order: Essentials, then pinned tabs not inside a collapsed folder, then regular tabs; ⌘9 the last; past the end, nothing; an unloaded pinned tab counts and loads when selected), `selectAdjacentTab(_ delta: Int)` (wraps, as Safari does), `reopenLastClosed()` (restores the newest archived tab of this workspace, selected; nothing when the archive is empty; the reopened tab's page is made with `openedByUser = true`: the model reports it through a new `PageLifecycle.tabOpenedByUser(_:)`, which the window controller passes into the next `PageRequest` for that tab, so the reopened page can download without waiting for a click). ⌘D is Tab ▸ Pin Tab (question 18): it pins the selected regular tab at the end of its workspace's pinned tabs and never unpins; its enablement rule (`PageMenuState`) is false on a pinned tab or Essential, in a private window, with no tab selected, and on a blank tab or failure panel. Unpin keeps its Tab menu and context menu items, with no shortcut.

- [ ] **Step 1: Write failing tests:** `noTwoCommandsShareAKey` (over the whole table, including the existing ⌘T, ⌘N, ⌘L, ⌘W, ⇧⌘W, ⌃⌘S, ⌘[, ⌘], ⌘R, ⌘., ⇧⌘N, ⌥⌘↑, ⌥⌘↓, ⌃1–9), `safariMeaningsKept` (each key in decision 16 maps to its Safari command; ⌘D is recorded as a deliberate mapping, Add Bookmark → Pin Tab; ⌘O is Open File…, ⌘Y Show All History), `selectByNumber` (⌘1 the first Essential, ⌘9 the last regular tab; ⌘n past the end does nothing; ⌘9 with three tabs selects the third; a pinned tab in a collapsed folder is skipped; ⌘9 with no regular tabs selects the last pinned tab), `adjacentWraps`, `reopenLastClosedRestoresNewest` (also asserts the `tabOpenedByUser` lifecycle call for the reopened tab), `commandDPinsRegularTab`, `commandDNeverUnpins` (disabled on a pinned tab and an Essential, in a private window, with no selection, and on a blank tab or failure panel).
- [ ] **Step 2: Run** → FAIL.
- [ ] **Step 3: Implement.** Menus are built from the table; each menu item keeps a VoiceOver label.
- [ ] **Step 4: Run** → PASS; build.
- [ ] **Step 5: By-hand check:** each new shortcut through System Events (Stave confirmed frontmost in the same osascript call); screenshot the View, History and Develop menus.
- [ ] **Step 6: Commit** `feat: the standard browser shortcuts`

### Task 11: HTTP auth prompts

**Files:**
- Create: `Sources/StaveCore/Web/AuthChallenge.swift`, `Sources/StaveWeb/PageDelegate+Auth.swift`, `Stave/Views/Content/AuthSheet.swift`; `Tests/StaveCoreTests/AuthChallengeTests.swift`, `Tests/StaveWebTests/AuthDelegateTests.swift`
- Modify: `Sources/StaveWeb/PageDelegate.swift` (`PageEvents.askAuth(tabID:challenge:) async -> AuthAnswer?`), `Stave/App/PageEventsRouter.swift`, `Stave/App/BrowserWindowController+PageEvents.swift`, `Stave/App/MediaQuestionCenter.swift` (a second `WaitingQuestions<AuthAnswer>` queue beside the media one), `Stave/App/PagePrompts.swift` (`showAuth`), `Tests/StaveWebTests/PageDelegateTests.swift` (`FakeEvents` conforms), `Tests/StaveWebTests/DelegateSelectorTests.swift`

**Interfaces:**
- Produces: `public struct AuthChallenge: Equatable, Sendable { host: String; realm: String?; isProxy: Bool; previousFailureCount: Int }` with `AuthText.title(for:)` ("‹host› wants you to sign in"), `detail(for:)` (realm in quotes, capped at 200 characters; "Your user name or password was wrong." after a failure), and `static func handling(method: String) -> AuthHandling` (`.ask` for Basic, Digest and NTLM; `.cancel` for client certificate; `.defaultHandling` for ServerTrust, Negotiate and anything else). `.defaultHandling` completes with `.performDefaultHandling, nil`, so plan 3's certificate errors (WebKit's default trust evaluation) are unchanged once Stave implements `webView(_:respondTo:)` and every challenge reaches it.

- [ ] **Step 1: Write failing tests:** `authNamesTheAskingFrame` (Review Focus 6: a subframe on `example.org` inside `example.com` → title names `example.org`), `cancelSendsNothing` (Review Focus 6), `realmIsCapped`, `failureCountShowsRetryText`, `clientCertificateCancels`, `serverTrustGetsDefaultHandling` (ServerTrust, Negotiate and an unknown method → `.defaultHandling`, never `.cancel`), the selector test lists the auth method.
- [ ] **Step 2: Run** → FAIL.
- [ ] **Step 3: Implement** decision 15, with the wait-until-shown queue the camera question uses.
- [ ] **Step 4: Run** → PASS; build.
- [ ] **Step 5: By-hand check:** a local server in the scratchpad answering 401 with `WWW-Authenticate: Basic realm="test"` → the sheet; wrong password → retry text; right one → the page. **Nico checks:** a real Basic-auth site, if he has one.
- [ ] **Step 6: Commit** `feat: HTTP sign-in prompts`

### Task 12: The Settings window, profiles and containers (question 28, answered 2026-11-13)

**Files:**
- Create: `Sources/StaveCore/Settings/SettingsCopy.swift`, `Settings/DeletionCopy.swift`, `Settings/ProfileDeletion.swift`, `Stave/Views/Settings/ProfilesPane.swift`, `ContainersPane.swift`, `WebsitesPane.swift`, `AdvancedPane.swift`; `Tests/StaveCoreTests/SettingsCopyTests.swift`, `ProfileDeletionTests.swift`, `Tests/StaveWebTests/WebDataStoresTests.swift`
- Modify: `Stave/Views/Settings/SettingsView.swift`, `OrganizationStore.swift` (`renameProfile`), `OrganizationStore+Containers.swift` (`updateContainer`, `containerUsage`), `Sidebar/WorkspaceEditorRules.swift` (its palette and colour rule shared with containers; moved to a shared palette type if needed), `Sources/StaveWeb/WebDataStores.swift` (`remove(_ id: UUID, inUse: Bool) async throws`), `Sources/StaveWeb/PageHost.swift` (`usesStore`), `Stave/App/AppDelegate.swift`

**Interfaces:**
- Produces:
  - `renameProfile(_:to:) throws` (blank names refused with a message), `updateContainer(_:name:colorHex:) throws` (blank names refused, as with `renameProfile`; the colour is checked with `WorkspaceEditorRules`' palette and its `allowingColorHex` rule, so editing only the name never refuses a container's existing off-palette colour; no second container palette), `containerUsage(_:) throws -> (open: Int, archived: Int)`, `profileSummary(_:) throws -> ProfileSummary` (workspace, tab, archived and history counts).
  - `DeletionCopy.profileQuestion(_ summary: ProfileSummary, name: String) -> String` and `containerQuestion`, `containerInUse(count:name:)` per decisions 18–19.
  - `WebDataStores.remove(_ id: UUID, inUse: Bool) async throws`: throws `.inUse` when `inUse` (the caller passes `PageHost.usesStore(id)`, true while any page, including a hibernated pop-up's, holds it); otherwise drops `cache[.persistent(id)]` first, then calls `WKWebsiteDataStore.remove(forIdentifier:)`. Without the first step, a store any page ever used stays cached and WebKit refuses the removal as "in use", leaving the deleted profile's cookies and sign-ins on disk.
  - `ProfileDeletion` in `Sources/StaveCore/Settings/ProfileDeletion.swift`: `@MainActor struct ProfileDeletion { init(store:, closePrivateSession: (UUID) -> Void, switchWindows: (UUID) -> Void, removeStores: ([UUID]) async throws -> Void); func run(profileID:) async throws }`. It closes that profile's private session, switches every window showing it, calls `deleteProfile`, then passes the returned store IDs to `removeStores`. The app's `removeStores` calls `WebDataStores.remove(id, inUse: pageHost.usesStore(id))` for each ID.

- [ ] **Step 1: Write failing tests:** `profileDeletionNamesWhatGoes` (Review Focus 3: counts in the question match the summary), `storesRemovedOnlyAfterRows` (Review Focus 3, StaveCoreTests: a recording `removeStores` closure sees the IDs only after `deleteProfile` returned and the profile row is gone); in `WebDataStoresTests` (StaveWebTests), `removeRefusedWhileAPageUsesTheStore` (Review Focus 3: while a `PageHost` page holds the store, `usesStore` is true and `remove` throws `.inUse`; once the page is gone, `usesStore` is false) and `removeDropsTheCachedStoreFirst` (a store fetched once is removed without an in-use error); `deletedTargetResetsExternalLinkSetting` (deleting the profile or workspace that `externalLinkTarget` names resets it to `.lastUsed`), `lastProfileRefused`, `containerInUseRefusedWithCount` (Review Focus 3), `blankProfileNameRefused`, `blankContainerNameRefused`, `containerColourFromPalette`, `containerKeepsItsOwnColourOnRename`, `settingsCopyIsComplete` (every pane title and control label is non-empty and unique).
- [ ] **Step 2: Run** → FAIL.
- [ ] **Step 3: Implement** decisions 17–19. Deleting the profile or workspace that `externalLinkTarget` names resets the setting to `.lastUsed` in the same flow (test `deletedTargetResetsExternalLinkSetting`). The Websites pane lists `siteSetting` and `siteValue` rows by host, with Remove and Remove All (a confirmation for Remove All). General shows "Remove history items" (Task 6, question 15). Advanced shows backup status and "Show Backups in Finder" (Task 1). Containers has Create, Edit (name and colour) and Delete (decision 19). Task 14 adds "Remove download list items" to General, and Task 16b adds "Archive idle tabs after" to Tabs.
- [ ] **Step 4: Run** → PASS; build.
- [ ] **Step 5: By-hand check** (seeded): rename a profile; create a container with a name and colour, then edit both; create a second profile with a tab, delete it → the question names its counts; afterwards `<folder>/data` and the WebKit store list no longer have it, and the window is on the first profile. Delete "Work Google" while a tab uses it → refused with the count. Keyboard only through every pane; ax-dump shows every control's label.
- [ ] **Step 6: Commit** `feat: Settings window with profiles, containers and websites`

### Task 13: The per-site panel (question 11, answered 2026-11-13)

**Files:**
- Create: `Sources/StaveCore/Web/SitePanelModel.swift`, `Stave/Views/Sidebar/SitePanel.swift`; `Tests/StaveCoreTests/SitePanelModelTests.swift`
- Modify: `Stave/Views/Sidebar/AddressField.swift`, `Stave/App/PagePrompts.swift` (Remember keeps Block as well as Allow, decision 32; `showMedia`'s doc comment, which says only an Allow is remembered, is fixed), `Sources/StaveWeb/PageDelegate+UI.swift` (`mediaDecision` stores a Block), `Sources/StaveWeb/PageDelegate.swift` (the `askMedia` doc comment, "`remember` is honoured for an Allow only", is fixed), `Sources/StaveWeb/PageHost.swift` (`privateSiteSource(for:)`), `Stave/App/MediaQuestionCenter.swift`, `Tests/StaveWebTests/PageDelegateTests.swift`, `Tests/StaveWebTests/PageHostTests.swift`

**Interfaces:**
- Produces: `@MainActor @Observable public final class SitePanelModel { init(source: SitePanelSource, host: String); var rows: [SitePanelRow]; func set(_ key: SitePanelKey, _ choice: SiteChoice); func resetSite() }`, with `SiteChoice { case ask, allow, block }` for permissions and a value picker for zoom. Rows for camera, microphone, content blocking and zoom; the user-agent row is added by Task 16.
- `@MainActor public protocol SitePanelSource: AnyObject { func choice(_ key: SitePanelKey) -> SiteChoice; func set(_ key: SitePanelKey, _ choice: SiteChoice); func value<V: Codable>(_ key: SiteValueKey, as: V.Type) -> V?; func setValue<V: Codable>(_ key: SiteValueKey, _ value: V?) }` in StaveCore, for one profile-or-private-session and host. A profile's source wraps the store. A private window's source wraps `PageHost`'s in-memory answers (`privateMediaAnswers` and Task 9's private zoom), through a new public `PageHost.privateSiteSource(for:)`, so a private panel edits memory only. Both sources apply a zoom change to the host's live pages at once.

- [ ] **Step 1: Write failing tests:** `panelShowsStoredAnswers`, `askRemovesTheRow`, `blockIsRemembered` (decision 32: a remembered Don't Allow is stored as Block, and the next request is denied without a sheet), `resetSiteClearsEveryKey`, `privatePanelEditsMemoryOnly` (in `PageHostTests`, through `privateSiteSource(for:)`: Block set in a private panel shows in the panel and is honoured by the next camera request from that host (driven as `PageDelegateTests`' `decideMedia` helper does), and the store's `siteSetting` and `siteValue` row counts are unchanged), `nonWebPageHasNoPanel`. Rewrite `mediaDontAllowIsNeverRemembered` (`PageDelegateTests.swift`) as `mediaDontAllowWithRememberStoresBlock`; it was the stopgap decision 32 ends.
- [ ] **Step 2: Run** → FAIL.
- [ ] **Step 3: Implement** decision 20 (without the user-agent row, which Task 16 adds). Changing content blocking reloads, as plan 3 does; changing zoom applies at once.
- [ ] **Step 4: Run** → PASS; build.
- [ ] **Step 5: By-hand check:** `cam.html` from plan 3: Block with Remember → reload, no sheet, camera off; the panel shows Block; Ask → the next load asks. **Nico checks:** Google Meet with Block then Ask.
- [ ] **Step 6: Commit** `feat: settings for this website`

### Task 14: Downloads hardening and the kept downloads list (questions 7 and 22, answered 2026-11-13)

**Files:**
- Create: `Sources/StaveCore/OrganizationStore+Downloads.swift`
- Modify: `Sources/StaveCore/Web/DownloadList.swift`, `Sources/StaveCore/Web/PageDialogs.swift` (`PageDownloadGate`), `Sources/StaveWeb/PageDelegate.swift`, `Sources/StaveWeb/Quarantine.swift`, `Stave/Views/Sidebar/DownloadsPopover.swift`, `Database/StaveDatabase.swift` (migration `v7`), `Database/BackupPolicy.swift` (`excludedTables` gains `downloadRecord`), `OrganizationStore+History.swift` (`clearHistory`), `Settings/SettingKey.swift` (`downloadListRetention`), `Settings/SettingsCopy.swift`, `Stave/Views/Settings/SettingsView.swift` (General), `Stave/App/PageEventsRouter.swift` (`confirmSeveralDownloads` goes through the queue), `Stave/App/MediaQuestionCenter.swift` (a `WaitingQuestions<QuestionAnswer>` queue beside the media one; `cancel(tabID:)` drops it), `Stave/App/PagePrompts.swift` (`showSeveralDownloads(tabID:host:finish:)`), `Stave/App/AppEnvironment.swift` and `Stave/App/AppDelegate.swift` (trim at launch, on the daily maintenance tick and at quit), `Tests/StaveWebTests/PageDelegateTests.swift` (`FakeEvents`); tests in `DownloadListTests.swift`, `HistoryTests.swift`, `Tests/StaveCoreTests/WaitingQuestionsTests.swift`, `DownloadQuestionQueueTests.swift` and `StaveWebTests`

**Interfaces:**
- Produces: the plan 3 Carried fixes, one test each: a finished file is never deleted when a re-mark throws after a successful first mark (check for an existing quarantine first); `failed` claims an unclaimed file so no unmarked partial is left; same-name concurrent downloads reserve their name (create the file exclusively, then write); names can't start with a combining mark; `a.tar.gz` becomes `a (2).tar.gz`; `DownloadFilename` drops U+061C, U+2028, U+2029, U+200B–U+200D, U+2060 and U+FEFF; a NaN progress is ignored; the `claimDownloadFile` test seam moves out of production code; `fileExists` in `~/Downloads` runs off the main thread; the quarantine record names the source page and the download URL (decision 23); the popover sits inside the window with one material (decision 23).
- The several-downloads question is held, not refused (decision 29, question 7): when it can't be shown it waits in the wait-until-shown queue; later downloads from the same document wait behind it and follow its answer; a new committed document, closing the page or forgetting the tab drops it and refuses its downloads, with nothing recorded; Don't Allow refuses the rest of the document; Allow lets the rest through. The doc comments that say otherwise are fixed: `PageDownloadGate` and "Refused (or not askable)" in `PageDialogs.swift`; in `PageDelegate.swift`, `QuestionAnswer.unasked`, "Asked only while the tab is shown; otherwise `unasked`", and "A question that can't be asked counts as refused".
- The kept downloads list (decision 33, question 22): migration `v7` `downloadRecord(id, profileID → cascade, filename, sourceHost, filePath, state, startedAt, endedAt)` indexed on `(profileID, startedAt)`, never written for a private window; `SettingKeys.downloadListRetention` (`day`, `onQuit`, `onSuccess`, `manually`; default `.day`) with Safari's labels ("After one day", "When Stave quits", "Upon successful download", "Manually") as Settings ▸ General ▸ "Remove download list items"; `.day` trims ended rows older than a day at launch and on the daily maintenance tick (the one that runs `trimHistory`); `.onQuit` trims ended rows at quit and at launch; `.onSuccess` removes a row when its download finishes (a failed or stopped row stays until removed by hand); Task 6's `clearHistory` also removes ended `downloadRecord` rows in its range. Removing a row never touches the file. A finished row whose file is gone shows "File not found" with Show in Finder disabled. A download still running at quit shows as stopped after relaunch (no resume in the beta).

- [ ] **Step 1: Write failing tests:** `finishedFileSurvivesARemarkFailure`, `failedClaimsThePartial`, `concurrentSameNameDownloadsDontCollide`, `leadingCombiningMarkStripped`, `multiDotExtensionNumbered`, `invisibleCodePointsRemoved`, `nanProgressIgnored`, `quarantineNamesTheSource`; for question 7, `severalFilesQuestionWaitsForHiddenTab` (a StaveCoreTests test on `WaitingQuestions`, driven the way `MediaQuestionCenter` drives it: show returns false while the tab is hidden, then a drain after the tab shows answers it; `QuestionAnswer` lives in StaveWeb, so the StaveCore test uses its own answer type, which the generic queue treats the same), with a StaveWebTests half that checks only that a held answer reaches `downloadGate`, and `heldQuestionDroppedOnNavigation`, and `severalFilesQuestionThatCouldNotBeAskedIsNotRecordedAsARefusal` rewritten to expect waiting; for question 22, `listSurvivesRelaunch`, `privateRowsNeverStored`, `clearHistoryClearsEndedDownloads` (Review Focus 4: ended rows in the range go and their files on disk are still there afterwards; a running download's row in the range is kept), `retentionRemovesOldRowsNotFiles`, `onSuccessRemovesRowKeepsFile` (with `.onSuccess`, a finished download's row goes when it finishes, its file stays, and a failed download's row stays), `dayRetentionTrimsOnDailyTick`, `missingFileShownAsNotFound`, `runningAtQuitShowsStopped`, and `backupLeavesOutDownloads`.
- [ ] **Step 2: Run** → FAIL.
- [ ] **Step 3: Implement.** First check how long WebKit lets a held download question wait (one attempt; record the answer in the commit body): a local page in a background tab starts two downloads, and the tab stays hidden for at least five minutes before it is shown. If the held download is still answerable, nothing more is needed. If WebKit times the download out (or fails it) while the question waits, the fallback refuses only that download when its load times out, with nothing recorded; the question stays held for the document's later downloads.
- [ ] **Step 4: Run** → PASS; build.
- [ ] **Step 5: By-hand check:** two downloads of the same name at once → `name.txt` and `name (2).txt`, both quarantined, `xattr -p com.apple.quarantine` shows the source host; the popover inside the window (screenshot); relaunch → both rows are still listed; move one file away → its row shows "File not found". A local page that starts two downloads in a background tab → no question until the tab is shown, then one question for both. **Nico checks:** Show in Finder selects the file (asked twice in plan 3, still unconfirmed); the Don't Allow half of the Downloads-folder prompt.
- [ ] **Step 6: Commit** `feat: downloads hardening and a downloads list kept across restarts`

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
- Modify: `Sources/StaveCore/Web/UserAgent.swift`, `Sources/StaveCore/Web/SitePanelModel.swift` (a `userAgent` row), `Sources/StaveWeb/PageHost.swift`, `Stave/Views/Sidebar/SitePanel.swift`, `Stave/App/StaveApp.swift`; `Tests/StaveCoreTests/UserAgentTests.swift`, `Tests/StaveCoreTests/SitePanelModelTests.swift` (`userAgentRowSetsAndResets`, and `resetSiteClearsEveryKey` extended to the agent)

**Interfaces:**
- Produces: `public enum SiteUserAgent: String, Codable { case standard, safari, chrome }` stored as the `userAgent` site value; `UserAgent.string(for: SiteUserAgent, safariVersion:)`; `UserAgent.chromeMajorVersion` constant; `OpenElsewhere.available(installed: Set<String>) -> [OpenElsewhereApp]` (Safari `com.apple.Safari`, Chrome `com.google.Chrome`). Also plan 3's leftover: `UserAgent` refuses a version of only dots.

- [ ] **Step 1: Write failing tests:** `chromeAgentNamesChrome`, `perSiteAgentStoredAndCleared`, `dotsOnlyVersionFallsBack`, `openElsewhereListsOnlyInstalled`, `userAgentRowSetsAndResets`, and `resetSiteClearsEveryKey` extended to the agent.
- [ ] **Step 2: Run** → FAIL.
- [ ] **Step 3: Implement** decisions 24–25.
- [ ] **Step 4: Run** → PASS; build.
- [ ] **Step 5: By-hand check:** a local page that prints `navigator.userAgent` → Chrome after the switch, back to standard after Reset; View ▸ Open in Safari opens the same URL in Safari (Stave frontmost check first; the session never clicks in Safari).
- [ ] **Step 6: Commit** `feat: per-site user agent and Open in Safari or Chrome`

### Task 16b: Archive idle tabs (question 27)

**Files:**
- Create: `Sources/StaveCore/Session/AutoArchivePolicy.swift` (with `AutoArchiveSchedule`), `Sources/StaveCore/OrganizationStore+AutoArchive.swift`, `Stave/App/AutoArchiveTimer.swift`; `Tests/StaveCoreTests/AutoArchiveTests.swift`
- Modify: `OrganizationStore+Tabs.swift` (stamp `lastActiveAt` when a tab is left), `Window/BrowserWindowModel.swift` (deselect and window close stamp the tab), `Settings/SettingKey.swift` (`autoArchiveAfter`), `Settings/SettingsCopy.swift`, `Stave/Views/Settings/SettingsView.swift` (Tabs), `Stave/App/AppEnvironment.swift`, `Stave/App/AppDelegate.swift` (the launch check after restore; stamping shown tabs at quit)

**Interfaces:**
- Consumes: `closeTab`'s archive path, `HibernationPolicy`'s busy checks (media, pop-ups), the download list.
- Produces:
  - `public enum AutoArchiveAfter: String, Codable, Sendable { case never, hours12, day1, days7, days30 }` and `SettingKeys.autoArchiveAfter` (default `.never`), with labels from `SettingsCopy` for Settings ▸ Tabs ▸ "Archive idle tabs after": Never, 12 hours, 1 day, 7 days, 30 days.
  - `public struct AutoArchiveCandidate: Sendable { tabID: UUID; section: SlotSection; slotKind: SlotKind; lastActiveAt: Date }` and `public enum AutoArchivePolicy { static func toArchive(_ candidates: [AutoArchiveCandidate], now: Date, limit: AutoArchiveAfter, shown: Set<UUID>, busy: Set<UUID>) -> [UUID] }` (pure; `SlotSection` is `essential | pinned | regular` and `SlotKind` is `tab | split`, both in `Records.swift`): only `section == .regular && slotKind == .tab` tabs whose `lastActiveAt` is older than the limit (split slots stay out until split-slot archiving, 2.x, because `closeTab` deletes the whole slot and would take the partner tab unarchived); never a pinned tab, an Essential, a tab shown in any window, or a busy tab (playing media, holding pop-ups, downloading); nothing when the limit is `.never`.
  - `archiveIdleTabs(profileID:now:limit:shown:busy:) throws -> Int`, which archives through the same path as `closeTab`, so each tab can be restored from the archive.
  - The store stamps `lastActiveAt` when a tab is deselected or its window closes, not only when it is selected (today only `markActive` on selection writes it), so "not viewed" counts from when the tab was last left. Quit doesn't run `windowWillClose`, so at quit (and whenever the window session is saved) every open window's selected tab is stamped too; a tab shown at quit counts from the quit.
  - `AutoArchiveTimer` runs the check at launch and every 15 minutes, for normal windows' profiles only; private windows are never archived. The launch check runs only after `launchCompleted`, that is, after the saved windows are restored and their selected tabs registered with `LivePageRegistry`; `shown` is every open window's selected tab plus every tab a window or pop-up owns. The ordering lives in a small StaveCore seam the timer calls (`AutoArchiveSchedule`: a check asked for before `launchCompleted()` runs nothing and is run once launch completes), so it is tested without the app.

- [ ] **Step 1: Write failing tests:** `offByDefaultArchivesNothing`, `pinnedAndEssentialsNeverArchived`, `shownTabNeverArchived`, `busyTabNeverArchived`, `idleRegularTabArchivedAndRestorable`, `importedTabsStampedNowAreNotArchived`, `idleCountsFromWhenTabWasLeft` (selected 14 hours ago, left 1 hour ago, 12-hour limit → kept), `splitSlotNeverArchived`, `launchCheckWaitsForRestoredWindows` (on `AutoArchiveSchedule`: a check asked for before `launchCompleted()` archives nothing; after it, the restored windows' selected tabs are in `shown` and kept), `shownAtQuitNotArchivedAtLaunch` (12-hour limit: a tab selected 2 days ago and still shown at quit has `lastActiveAt` at the quit time; the launch check 1 hour later keeps it even when `shown` is empty, as when its window wasn't restored).
- [ ] **Step 2: Run** `--filter AutoArchiveTests` → FAIL.
- [ ] **Step 3: Implement** decision 34. Add the Tabs pane control. If the task can't be finished, the setting stays out of the beta and is carried.
- [ ] **Step 4: Run** the suite → PASS; build.
- [ ] **Step 5: By-hand check:** set "Archive idle tabs after" to 12 hours; quit Stave, set one regular tab's `lastActiveAt` two days back with `sqlite3` on the throwaway folder's database, and relaunch → the idle regular tab is in the archive, the shown tab, pinned tabs and Essentials stay; restore it from the archive → it comes back. Set Never → nothing is archived. Settings ▸ Tabs control works with the keyboard; ax-dump shows its label.
- [ ] **Step 6: Commit** `feat: archive idle tabs, off by default`

### Task 17: Location permission (question 19, answered 2026-11-13; not built in the 2026-11-13 session) [TCC]

**Files:**
- Create: `Sources/StaveWeb/PageDelegate+Location.swift`; tests in `StaveWebTests`
- Modify: `Stave/Info.plist` (`NSLocationUsageDescription` and `NSLocationWhenInUseUsageDescription`, both "Websites you allow can use your location."), `Stave/Stave.entitlements` (`com.apple.security.personal-information.location`), `Sources/StaveCore/Web/SiteSettings.swift` (`SiteSettingKey.location`), `Tests/StaveWebTests/DelegateSelectorTests.swift`

- [ ] **Step 1: Spike** (one attempt): on macOS 15, 26 and 27 where available (CI covers only 15 and 26), find which of three delegate methods WebKit calls for `navigator.geolocation.getCurrentPosition` in a `WKWebView`, and in what order: the public `webView:requestGeolocationPermissionForOrigin:initiatedByFrame:decisionHandler:` (macOS 27), the private `_webView:requestGeolocationPermissionForOrigin:initiatedByFrame:decisionHandler:`, and the private frame-based `_webView:requestGeolocationPermissionForFrame:decisionHandler:` (BOOL). Record the answers in the commit body. If neither origin selector is called on an OS, location is denied there and the release notes say so.
- [ ] **Step 2: Write failing tests:** `locationQuestionNamesTheTopSite`, `rememberedAllowSkipsTheSheet`, `rememberedBlockSkipsTheSheet` (question 11), `privateAnswersInMemory`, `handlerNeverAnswersPrompt` (`.prompt` would make WebKit show its own alert), and both origin selectors in the selector list.
- [ ] **Step 3: Implement** both origin selectors (each takes a `WKPermissionDecision` handler, answered only `.grant` or `.deny`) with the camera question's rules: Stave's sheet (Allow / Don't Allow, Remember for this site); held until the tab is shown; per profile and host; private windows in memory. macOS's own prompt comes in whatever order WebKit enforces, as the spike recorded.
- [ ] **Step 4: Run** → PASS; build.
- [ ] **Step 5: By-hand check:** a local page asking for location → Stave's sheet; macOS asks for Stave's location access the first time (Nico answers it). **Nico checks:** a real maps site.
- [ ] **Step 6: Commit** `feat: location permission per site`

### Task 18: Web notifications (question 20, answered 2026-11-13; waits on the Chorus tag) [Chorus] [TCC]

**Files:**
- Modify: `Packages/StaveCore/Package.swift` (the new `exact:` pin, only after the Chorus tag exists and ENGINE.md's "Engine API changes by release" was read), `Sources/StaveWeb/PageConfiguration.swift`, `Sources/StaveCore/Web/SiteSettings.swift` (`SiteSettingKey.notifications`), `Stave/App/AppDelegate.swift` (UserNotifications authorization); tests in `StaveWebTests`

- [ ] **Step 1: Confirm** the Chorus tag carries engine change 1 and that Chorus's CI is green on it. If not, stop: this task waits, and the beta ships without notifications.
- [ ] **Step 2: Write failing tests:** `notificationNeedsSitePermission`, `privateWindowNeverNotifies` (as Chrome and Firefox deny in private), `clickingANotificationShowsItsTab`, `permissionNeedsAUserGesture` (without one the request is denied with no sheet), `bothAnswersRememberedWithoutCheckbox`, `globalAskSwitchSuppressesTheSheet`.
- [ ] **Step 3: Implement.** The question shows only after a user gesture; Allow and Don't Allow are both remembered per profile and host. Settings ▸ Websites gets "Allow websites to ask to send notifications", on by default (decision 17). macOS asks for Stave's notification permission the first time a site the user allowed sends one.
- [ ] **Step 4: Run** the suite and both builds → PASS; CI green on macos-15 and macos-26 with the new pin.
- [ ] **Step 5: Commit** `chore: move ChorusEngine to <tag>` then `feat: web notifications per site`

### Task 19: Passkeys (question 29, answered 2026-11-13; not built in the 2026-11-13 session) [Apple]

**Files:**
- Modify: `Sources/StaveCore/Settings/SettingsCopy.swift` (the notice), `Stave/Views/Import/FirstRunView.swift`, `Sources/StaveWeb/PageConfiguration.swift` and a page-world script (the per-request banner; Stave owns its `WKUserContentController`, so no engine change); once granted: `Stave/Stave.entitlements`, `project.yml` (provisioning profile for Release), `release/DISTRIBUTION.md`

- [ ] **Step 1: Notice now:** the first-run screen and Settings ▸ Advanced say what works today, in the text Nico approved: "Passkeys need Apple's approval for Stave, which hasn't arrived yet. Use the Passwords app to copy sign-ins for now." When a page asks for a passkey, the same text shows as a passive banner (not a sheet), once per document. Tests: `passkeyNoticeIsPlain` pins the text; `passkeyBannerOncePerDocument`.
- [ ] **Step 2: When Apple grants it** (not before): add `com.apple.developer.web-browser.public-key-credential`, the Developer ID provisioning profile, and remove the notice. By-hand: sign in with a passkey at a site that offers one. **Nico checks:** the provisioning profile install.
- [ ] **Step 3: Commit** `feat: passkey notice` (and later `feat: passkeys with Apple's entitlement`)

### Task 20: Part A check and outcome

**Files:**
- Create: `docs/superpowers/plans/2026-11-10-stave-release.md` (Part B, moved here; question 1)
- Modify: this plan (Part A's Outcome and Carried, and a one-line pointer where Part B was), `docs/superpowers/plans/2026-10-28-stave-foundation.md` (roadmap entry 5 status), `README.md` (Status: it still says web pages are "Not yet"; plan 3 built them), `CLAUDE.md` if a rule changed

- [ ] **Step 1: Run** the full package suite and both app builds; push; CI green on macos-15 and macos-26.
- [ ] **Step 2: By-hand run** over Tasks 1–16b on one throwaway folder (Tasks 17–19 only where built), keyboard and accessibility only, screenshots per task. Developer tools follow decision 14: Inspect Element, ⌥⌘I and ⌥⌘U with no setting.
- [ ] **Step 3: Write the Outcome** with a Nico checks list. The default-browser switch comes first, then pointer, real sites and VoiceOver, and the checks named in "Written down for Nico (from the answers)". Record that the two-week daily-driver clock starts the day Nico sets Stave as his default browser (question 1). Write Part A's Carried section, including the items already known (listed under "Carried into later plans").
- [ ] **Step 4: Move Part B and commit.** Move Part B into `2026-11-10-stave-release.md`: Tasks 21–25, decisions 26–28, questions 23–26 with their answers, and the File structure entries tagged T21–T24 (such as `Stave/Info.plist`'s "T21 SUFeedURL, SUPublicEDKey"). Leave a one-line pointer here. The branch note under "Stacks on PR #4" (`feat/release`) stays. Commit `docs: plan 5 part A outcome, and Part B in its own plan`.

# Part B: release

### Task 21: Version, update feed and Sparkle (questions 23–26, answered 2026-11-13)

**Files:**
- Create: `Stave/App/Updater.swift`, `Sources/StaveCore/Settings/VersionText.swift`; `Tests/StaveCoreTests/VersionTextTests.swift`
- Modify: `project.yml` (Sparkle 2.x from `https://github.com/sparkle-project/Sparkle`, app target only; `MARKETING_VERSION` stays `0.1.0` (already set); `CURRENT_PROJECT_VERSION` goes up by one for every build given out, question 26), `Stave/Info.plist` (`SUFeedURL` = `https://updates.nicojan.com/stave/appcast.xml`, `SUPublicEDKey`, `SUEnableAutomaticChecks` = YES, no `SUEnableSystemProfiling`; question 25), `Stave/App/StaveApp.swift` (Stave ▸ Check for Updates…; Stave ▸ About Stave calls `orderFrontStandardAboutPanel(options:)` with `.applicationVersion` from `VersionText`), `Settings/SettingsCopy.swift` (Settings ▸ General ▸ "Check for updates automatically"), `THIRD_PARTY_NOTICES.md` (Sparkle, MIT), `README.md` (what the update check sends and what is counted, per decision 26)

**Interfaces:**
- Produces: `VersionText.aboutVersion(shortVersion: String) -> String`, built from `CFBundleShortVersionString` at run time, adding " beta" while the major version is 0 (question 26). No literal "0.1.0 beta" anywhere.

- [ ] **Step 1: Nico** runs `generate_keys --account stave` (question 24; never the default account, which already holds the shared key and would only print it), exports a backup with `generate_keys --account stave -x <file>` and keeps it safe, and gives only the public key (`generate_keys --account stave -p`) for `Info.plist`. **[Apple account not needed; Nico's Keychain]**
- [ ] **Step 2: Implement** the updater gated so Debug builds never check (`#if !DEBUG`), the menu item, the setting and the About version. Test `aboutVersionAddsBeta` (`0.1.0` → "0.1.0 beta", `1.0.0` → "1.0.0"). The feed URL is the final one (decision 27).
- [ ] **Step 3: Verify:** both builds; the Release build's `Info.plist` holds the final feed URL and the key, and has no `SUEnableSystemProfiling` (`plutil -p`); its `SUPublicEDKey` differs from Chorus's; a Debug build makes no request to the feed (Little Snitch or `nettop`, Nico's call).
- [ ] **Step 4: Commit** `feat: Sparkle updates`

### Task 22: Signing, notarization and the release script [Apple]

**Files:**
- Create: `release/DISTRIBUTION.md` (adapted from Chorus's, Stave's values; Chorus's default-account `sign_update` line is not carried over), `release/ExportOptions.plist` (Developer ID, team from Nico), `release/release.sh`, `docs/appcast.xml` (empty feed)

- [ ] **Step 1: Write `release.sh`:** archive the Release build, export with Developer ID, `xcrun notarytool submit --wait` with Nico's stored keychain profile (never a password in the script), `xcrun stapler staple`, `hdiutil create` the DMG, notarize and staple the DMG, print its SHA-256. It refuses to run with a dirty tree or a bundle ID other than `com.nicojan.Stave`.
- [ ] **Step 2: Nico runs it** for a first test build (not published). Verify: `spctl -a -vv Stave.app` says "Notarized Developer ID"; `codesign -d --entitlements - Stave.app` shows the camera, audio-input (and location, if Task 17 shipped) entitlements; the app launches on a clean user account with Gatekeeper on.
- [ ] **Step 3: Nico** (Cloudflare account) deploys the Stave Worker route before the first signed build, since the URL is permanent (decision 27). Verify with `curl -sI https://updates.nicojan.com/stave/appcast.xml`, and after deploy confirm the real Sparkle User-Agent shape the Worker sees, as Chorus's README warns. Commit `chore: release script, distribution notes and empty appcast`

### Task 23: GitHub release, appcast and the Homebrew cask

**Files:**
- Create: `release/homebrew/stave.rb`
- Modify: `release/DISTRIBUTION.md` (the release checklist), `docs/appcast.xml`

- [ ] **Step 1: Write the checklist** in `DISTRIBUTION.md`: bump both versions (`MARKETING_VERSION` when it changes, and `CURRENT_PROJECT_VERSION` always; `CFBundleVersion` never repeats); bump `UserAgent.chromeMajorVersion` if Chrome moved; run `release.sh`; `gh release create vX.Y.Z` with the DMG; sign and regenerate `docs/appcast.xml` with Sparkle's `generate_appcast`; every `sign_update` and `generate_appcast` call passes `--account stave`, because without it they quietly use the shared key (question 24); if `gh release create` marks the release as a GitHub pre-release, check that the cask's livecheck still sees it, since GitHub's "latest release" leaves pre-releases out; put the version and SHA-256 into `release/homebrew/stave.rb`, copy it to `Casks/stave.rb` in `nicojan/homebrew-tap`, and run `brew style`, `brew livecheck` and `brew audit --cask --online`.
- [ ] **Step 2: Write the cask** (`app "Stave.app"`, `depends_on macos: ">= :sequoia"`, `zap` naming `~/Library/Application Support/Stave` and the WebKit folder for `com.nicojan.Stave`, never Stave-debug).
- [ ] **Step 3: Verify** with a test release Nico can delete: `brew install --cask nicojan/tap/stave` installs it; an older build updates through Sparkle.
- [ ] **Step 4: Commit** `chore: Homebrew cask and the release checklist`

### Task 24: The beta gate and release notes

**Files:**
- Modify: `README.md` (install; privacy: what leaves the Mac, including what an update check sends, what the Worker stores and for how long, that Cloudflare sees the address, the free tier's ceiling of roughly 1,000 a day, and that counting never blocks an update (question 25); the backup and restore steps from Task 1, checked; the Arc file note), `docs/release-notes/0.1.0.md` (new), this plan (Outcome)

- [ ] **Step 1: Release notes** in plain words: what works, what doesn't yet (passkeys if not granted, notifications if the tag isn't out, location where Task 17 found no route, IDN hosts shown as punycode, containers' limits), "keep a copy of Arc's `StorableSidebar.json` before 2026-12-22" (plan 2's risk), and how to report a bug.
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

Already known from the answers (2026-11-13), for Task 20 to carry:

- **IDN Unicode display** (question 4), post-beta: decode with the public ICU calls in the macOS SDK (`uidna_nameToUnicode`, and `u_getIntPropertyValue` with `UCHAR_SCRIPT`) through a small C module that links `icucore`, with a Firefox-style Moderately Restrictive or WebKit allowed-script check and punycode as the fallback. Chrome's confusable check needs `uspoof`, which the SDK doesn't expose. `SiteHost` keys stay punycode.
- **`user@host` links** (question 6): Chrome loads them silently and hides the user name; Firefox asks first; Safari 5 (2010) warned, but Safari 27.2's string tables, searched on this Mac on 2026-11-13 (read-only, Safari not launched), contain no such warning, nor do its shared frameworks or WebKit's. Nico checks Safari once; if it warns, a tab-scoped warning sheet follows.
- **Opened-file gaps** (question 13): resources and links outside the opened file's folder are refused, and a restored `file:` tab doesn't reload by itself; the three browsers do both.
