# Stave — design

Date: 2026-10-28. Status: revised after review; Nico approved moving on to the build plan.

Stave is a calm, organized web browser for macOS, built on WebKit. It takes the organization model people love in Zen and Arc (profiles, workspaces, pinned tabs that stay put, Essentials, containers) and puts it in a native Mac app that shares its web engine with Chorus.

Background reading: `docs/research/2026-10-28-what-people-love-in-browsers.md` (what users love and leave in eleven browsers). Items marked **(my call)** were decided by Claude during design, not by Nico, and are open to change.

## Why

- Nico wants Zen's organization without Firefox, and a Chromium fork is too expensive to maintain alone. On a Mac, WebKit ships with the OS: no engine to build, security updates come from Apple, and the UI is ordinary Swift.
- Chorus already solved the hard WebKit problems (isolated data stores, popups and sign-in flows, hibernation, content blocking, downloads, camera and mic). That engine is being extracted from Chorus into a Swift package so Stave builds on it.
- Arc stops working on 2026-12-22 and its users are being sent to Dia, which many dislike. A good Arc-like browser with an Arc import has a ready audience.
- The research is clear that people come for organization and leave over unreliability. Stave's edge has to be both: Zen's organization with Safari's dependability.

## Goals

1. **Organization model:** profiles → workspaces → tabs, exactly as described below, with nothing ever silently lost.
2. **Daily-driver reliability:** sites work, sign-ins work, tabs survive crashes and restarts, memory and battery stay in check.
3. **Apple approval as a real browser:** Stave can be set as the default browser, which (as far as is known; see Open checks) is what qualifies it for Apple's browser passkey entitlement and for the iCloud Passwords helper's allow-list.
4. **Arc migration:** an Arc user can import their Spaces, pinned tabs, folders and Favorites and feel at home within minutes.
5. **A dependable public beta, ideally before Arc stops working on 2026-12-22.** Quality wins over the date (Nico is flexible on timing).

## Non-goals for the first release

Browser extensions, cross-device sync, split view, Glance, Boosts (per-site CSS/JS), Reader mode, AI features, iPhone/iPad, Windows/Linux, bookmarks as a separate system (see Bookmarks below), import from browsers other than Arc.

## Anti-goals (a failure even if it works)

- Losing a tab, a pinned tab or a workspace, ever.
- Requiring an account to use the browser.
- Telemetry, ads, or anything in the UI that sells something.
- An opinionated behaviour the user cannot switch off.
- Non-standard keyboard shortcuts for things Safari and Chrome already have shortcuts for.
- AI as the point of the product.
- Breaking or slowing down Chorus by sharing its engine.

## Constraints

- **Open source under the MIT licence** (Nico's decision), like Chorus. Public repo, public CI, the same release setup as Chorus. Test fixtures never contain anyone's real browsing data. No code is copied from Zen (MPL-2.0) or Ora (GPL-2.0); they are reference for behaviour only. Code from MIT-licensed projects (such as arc-export) may be adapted with attribution in `THIRD_PARTY_NOTICES.md`.
- **macOS 14 or later** (my call: matches Chorus and the engine; `WKWebsiteDataStore(forIdentifier:)` needs 14).
- **Bundle ID `com.nicojan.Stave`.** This identity is what Apple's Passwords allow-list and the passkey entitlement attach to, so it must never change. Debug builds use `com.nicojan.Stave.debug` and their own data folder, as Chorus does, so a development copy can never touch real data.
- **Engine:** depends on the `ChorusEngine` product of the Chorus repo by git tag, pinned `exact:`. Stave never edits engine code in its own repo; engine changes go to Chorus and come back through a tag.
- **Distribution** like Chorus: Developer ID signed, notarized, Sparkle auto-updates, Homebrew cask in `nicojan/tap`. Not sandboxed, not on the Mac App Store (my call: the App Store adds review risk and sandbox limits). This decision is revisited if the passkey entitlement turns out to be available only to App Store apps (see Open checks).
- **Swift 6, AppKit + SwiftUI**, matching Chorus's conventions, including CI on macOS 14 and 15 with Xcode 16.2's limits.
- **Privacy:** nothing leaves the Mac except page traffic, Sparkle's update check and the content blocker's list updates (if any). The update check carries no identifier. Whether it is counted (as Chorus's appcast Worker counts daily checks) is stated plainly in the README (my call: count, anonymously, like Chorus, and say so).

## The organization model (decided with Nico)

```
Profile (own cookies and website data, own history and archive)
├── Essentials: shown in every workspace of this profile
├── Workspace A
│   ├── Pinned tabs, in folders; never closed until removed; reset to their pinned page
│   └── Regular tabs; restored across restarts; archived (not deleted) when closed
├── Workspace B
│   └── …
└── Containers: tabs with their own cookies, named-and-kept or throwaway
```

- **Profile.** Its own persistent `WKWebsiteDataStore`, and its own history, archive, downloads list and settings overrides. Everything in a profile shares its cookies unless the tab is in a container. Deleting a profile removes its data store after a confirmation that names what will be lost.
- **Workspace.** A named group of tabs inside a profile, with an icon and a colour that tints the sidebar (an Arc delight). Workspaces in a profile share its cookies.
- **Essentials.** Tabs pinned for the whole profile, shown at the top of the sidebar in every workspace as an icon grid. Each Essential is one live web view that moves into whichever workspace is on screen, so it keeps its state. Like pinned tabs, an Essential can be reset to its pinned page.
- **Pinned tabs.** Belong to one workspace. Remembered by their pinned URL, title and icon even when no web view exists. Clicking one loads it. You can navigate away inside it; one action (and a visible "back to pinned page" affordance when it has drifted) resets it. Closing a pinned tab unloads it; only "Unpin" or "Remove" deletes it. Folders hold pinned tabs and nest one level (my call: Arc allows deeper nesting, but one level covers most use and keeps the sidebar calm; deeper Arc folders are flattened into their nearest allowed parent on import, and the import report says so).
- **Regular tabs.** Belong to one workspace. Every open regular tab is restored after quit or crash, including its back/forward history. Closing a tab moves it to the profile's archive, searchable from the command bar and restorable; archived tabs are trimmed after 30 days (my call). Auto-archiving of idle tabs is a setting, off by default (my call: Arc's default surprised people).
- **Where new tabs go (my call, deterministic and tested, since Vivaldi users noticed when this broke).** A new tab from the command bar goes to the top of the workspace's regular tabs. A link opened from a tab goes directly below that tab. A link from another app goes to the top of the regular tabs in the workspace that receives it. A setting can flip "top" to "bottom".
- **Containers.** A tab can live in a container instead of the profile's store. A **named container** ("Work Google") has its own persistent store and can be used by many tabs, including pinned tabs and Essentials. A **throwaway container** has a non-persistent store that disappears when its last tab closes. Containers belong to a profile. Tabs show their container's colour. Deleting a named container removes its store only after checking that no tab still uses it (the rule Chorus learned the hard way with shared stores).
- **Private window.** A window with its own throwaway store, a plain tab list and no Essentials, pinned tabs or workspaces. It records no history, no archive and no downloads list, and saves nothing to disk (my call: table stakes in any browser).
- **One live page, one place (my call).** A web view can be on screen in only one window. When a page is already showing in another window (an Essential, or a workspace open in two windows), the second window shows the page's last snapshot and "Showing in another window — bring it here". Clicking it moves the live page to this window. Focus alone never moves a page, so pages don't jump around.
- **Moving things.** A tab moves freely between workspaces of the same profile without reloading. Moving it to another profile or container means reopening it there, which reloads the page; the UI says so before doing it.

### Data model rules (decided now so later features need no migration)

- **Windows are views, not owners.** A window shows one profile and one workspace at a time and can switch either. Two windows can show the same workspace; tabs are owned by the workspace, not the window. (Zen had to retrofit this.)
- **A workspace slot holds either a tab or a split group.** First release only ever creates single tabs, but split view later is a new kind of slot, not a reshaped model.
- **Every record has a permanent UUID and a last-modified timestamp**, so CloudKit sync can be added later.
- **State is saved as it changes**, not at quit, so a crash or a power cut loses nothing. A tab's back/forward history (`WKWebView.interactionState`) is saved when it changes, throttled.
- **Restoring is lazy.** On launch only the tab on screen loads; every other tab shows its saved title, icon and snapshot until selected. Launch time must not grow with the number of tabs.

## First release

No fixed date (Nico is flexible). Aim for a public beta before 2026-12-22, while Arc users are choosing a new browser, but ship only when it is dependable: Orion lost users to bugs, not lateness. If time runs short, this is the cut line (my call): the beta carries items 1, 2, 4, 5, 6, 8 and 9; containers (part of 1), compact mode (3) and the site-compatibility tools (7) follow in updates. Then a 1.0 when the beta has held up.

Work on Stave starts before the engine tag exists: the data model, sidebar, persistence and the Arc import parser need nothing from the engine. Web views are wired to the engine once Chorus ships the extracted package.

Included:

1. **The organization model above,** with a sidebar to match: a page address field at the top (shows the current site; clicking it opens the command bar), Essentials grid, workspace switcher (click, ⌃1–9 as in Arc, two-finger swipe), pinned folders, regular tabs, archive. The ⌃1–9 shortcut can clash with macOS's "Switch to Desktop" shortcuts; the first-run screen mentions it and the setting can change it.
2. **Command bar** (⌘T for a new tab, ⌘L for the current one): URLs, search, open tabs, pinned tabs, archived tabs, history, workspaces, and actions (new container tab, switch profile, toggle compact mode, and so on).
3. **Compact mode:** sidebar and toolbar hidden, revealed on hover at the window edge; a setting and a shortcut.
4. **Arc import:** Spaces → workspaces, pinned tabs and folders → pinned tabs and folders, Favorites → Essentials, unpinned tabs → regular tabs (optional, off by default), Arc profiles → Stave profiles where Arc's data allows it. Offered on first launch when Arc's file is present, from the File menu, and from a file the user picks (for someone who copied the file before uninstalling Arc). Logins and cookies cannot be imported; the import says so plainly and points to iCloud Passwords and passkeys. It finishes with a report of everything it imported, flattened or skipped.
5. **Default browser support:** registers for `http`/`https` and HTML files; links from other apps land in a chosen profile and workspace (setting; default is the last-used one). `mailto:` and other schemes go to their own apps.
6. **Content blocking on by default** (engine's blocker), with a per-site off switch.
7. **Site compatibility tools:** per-site user-agent override, and "Open in Safari/Chrome" for a page that breaks.
8. **Browser basics:** history, downloads (engine), find in page, zoom per site, print, PDF viewing, file uploads, drag and drop of links and files, full-screen video, Picture in Picture for HTML video, Web Inspector, web notifications (engine) with per-site permission, camera/mic/location permission prompts per site, a search engine chosen at first run (Google, DuckDuckGo, Kagi, Bing, Ecosia; my call: no default picked for the user), and the full set of Safari/Chrome-standard shortcuts.
9. **Accessibility:** the sidebar, command bar and every setting work with VoiceOver and the keyboard alone. (Blind users name tab handling as a Safari pain point; an accessible sidebar is cheap to get right at the start and costly to retrofit.)
10. **Passkeys** if Apple has granted the entitlement by then; otherwise a clear notice, like Chorus's.
11. **Settings** for every opinionated behaviour.

### The beta is ready when

- Nico has used it as his default browser for two weeks with no lost tab, pinned tab or workspace.
- The by-hand sign-in checklist passes: Google, Microsoft, Apple, an Okta-style SSO popup, GitHub; plus Google Docs, Google Meet with camera and mic, YouTube and a DRM video site (result recorded even if DRM fails).
- Killing the app mid-use (`kill -9`) and relaunching restores every window, workspace and tab.
- The Arc import has run on every available sample, including the synthetic fixtures, and its report is accurate.
- No crash in the last week of daily use.

## Later releases

- **1.x:** Glance (modifier-click opens a floating preview using the opener's store; expand to a tab). Import from Safari and Chrome (bookmarks, history). iCloud Passwords once Apple adds Stave to the helper's list.
- **2.x:** Split view (two to four panes as a new slot kind; whether an Essential can join a split is decided then). Boosts. Reader mode. CloudKit sync. Rebindable shortcuts.

## Bookmarks (my call)

No separate bookmarks bar or manager in the first release. Pinned tabs and folders are Stave's bookmarks, as in Arc. Imported Arc pinned items land there. A later import from Safari/Chrome puts bookmarks into an "Imported bookmarks" pinned folder in a workspace the user picks.

## Apple approvals

0. **Name first (my call):** run the USPTO check on "Stave" before any request to Apple, since the bundle ID can never change once Apple has approved it.
1. **Passkeys:** request the `com.apple.developer.web-browser.public-key-credential` entitlement as soon as the bundle ID and a working browser build exist. It needs a provisioning profile in the build, which Chorus has never done; first confirm it is available to Developer ID apps.
2. **iCloud Passwords:** after the public release, ask Apple to add `com.nicojan.Stave` to the Passwords helper's allow-list (checked on macOS 27.0.1: Orion and Zen are on it). Nobody here knows Apple's process or timeline yet; finding it out is a task.
3. Until then, the first-run and sign-in UI say plainly what works (passkeys if granted, and the Passwords menu-bar app for copying).

## Dependencies on Chorus's engine

- The engine extraction must be released first. Stave needs from it: `WebSurface` with a `.nonPersistent` data store case (throwaway containers and private windows); the Chorus names made configurable (logger subsystem, `__chorus*` JS globals, `ChorusDarkReader` content world, rule-list prefixes, user-facing "Chorus" strings); and the notification forwarding in `UserScriptManager`.
- Those changes are made in Chorus and released as a Chorus version, never patched inside Stave.
- **How much of the engine Stave uses (my call).** The engine's pool, tabs and popup window are shaped around Chorus services (`WebViewPool` keyed by service, `ServiceTabs`, `InAppBrowserWindow`, `serviceOwnsURL`). Stave does not bend them into a browser. It uses the engine's lower layers (data stores, content blocker, user scripts and notification forwarding, downloads, network monitor, dark mode, cookie-consent handling, and the coordinator's navigation, permission and popup-inheritance logic where it is reusable) and writes its own tab model, web-view pool and window/popup handling: `target=_blank` and `window.open` open sidebar tabs, and sign-in popups stay tied to their opener tab and its store. Engine changes Stave needs are kept small and go through Chorus releases; nothing on Stave's critical path waits on a large engine refactor. The engine extraction must be tagged (1.5.32 or later) before Stave's web views depend on it.

## Left to the builder

- **Persistence technology.** SwiftData as in Chorus, or SQLite (e.g. GRDB). Weigh Chorus's documented SwiftData problems across macOS 14/15/26 (`Chorus/CLAUDE.md`) and the save-as-it-changes write rate against the cost of a second stack. The data model rules above are fixed either way.
- Sidebar visuals, animations, exact layout, icons, colour palette.
- How the archive, history and command bar index are stored and searched.
- Memory policy for background tabs (use the engine's hibernation; pick defaults).
- **The Arc import parser.** Arc keeps its sidebar in `~/Library/Application Support/Arc/StorableSidebar.json`. Arc no longer accepts new accounts, so no fresh sample can be made here. The format is known from MIT-licensed exporters, chiefly [ivnvxd/arc-export](https://github.com/ivnvxd/arc-export) (`main.py`): `sidebar.containers` alternates a `{"global":{}}` marker with a container holding `spaces` and a flat `items` list; each space's `newContainerIDs` alternates `{"pinned":{}}` / `{"unpinned":{}}` markers with container IDs; items link by `parentID`, and a tab item carries `data.tab.savedURL` and `savedTitle`. Still to confirm from other exporters or samples: Favorites, item order within a folder, and which profile a space belongs to. The parser tolerates unknown shapes. Synthetic fixtures are written from the known format; real samples can come only from existing Arc users through a structure-only export that replaces every title and URL with a placeholder before anyone shares it.
- Test strategy, beyond: the data model, restore, tab placement and Arc parsing get unit tests; the "beta is ready when" list above is the by-hand gate.

## Open checks (unverified)

- Whether the passkey entitlement is available to Developer ID (non-App Store) apps, and Apple's exact criteria for granting it.
- Apple's process and timeline for the Passwords allow-list.
- Whether DRM video (Netflix and similar) plays in a WKWebView browser outside Safari.
- Memory cost of many data stores (profiles plus containers) in one app.
- Arc's Favorites, ordering and profile fields; and whether Arc deletes its local file when it shuts down on 2026-12-22.
- A USPTO trademark check on "Stave" before the public beta.
