# How Zen works inside (behaviour notes)

Notes from Zen 1.24b as installed on Nico's Mac, 2026-11-04. Zen is MPL-2.0: these notes describe behaviour in our own words and copy no code. Build Stave's versions from these notes, not with Zen's code open beside them.

**Sources.** Zen's interface code ships readable inside `Zen.app/Contents/Resources/browser/omni.ja`; line numbers below point into that file (1.24b) so a later reader can find the spot. **Checked** means re-read in this session (code signature, provisioning profile, default settings). **Report** means read from Zen's code by an earlier session's investigation and not re-read; treat it as likely, not proven.

## Passkeys and Apple (checked)

- Zen's signature carries Apple's browser passkey entitlement, `com.apple.developer.web-browser.public-key-credential`, under Zen's own team (9V5K9TP787), not Mozilla's.
- Its provisioning profile ("Zen Browser Provisioning", created 2025-03-15) has `ProvisionsAllDevices = true`, the Developer ID kind. So Apple grants this entitlement to a browser distributed outside the App Store.
- Oddity: the profile's app ID is `9V5K9TP787.app.zen-browser.app`; the app's is `9V5K9TP787.app.zen-browser.zen`. Whether macOS honours the entitlement despite the mismatch is unknown.
- Still unknown: how Zen applied, what Apple asked for, how long it took, and how Zen got onto the Passwords helper's allow-list. Only people can answer these.

## Saving tabs (report)

- Zen keeps its own session file beside Firefox's, one shared record of every tab, folder, split and space (36018, 36034). Writes are batched and made a moment later (36592).
- Before each write it copies the last good file aside (36578). About ten minutes after the last change it also makes a timed backup, one per three-hour slot, newest 20 kept (36027, 36654–36672). At launch, an empty or broken main file falls back to the last good copy, then the newest timed backup (36224–36249).
- When "Open previous windows and tabs" is off, Zen discards every unpinned tab at restart and keeps only pinned ones, except after a crash or the first launch after an update (36291–36313, 36396–36411). This likely explains many "Zen lost my tabs" reports (a guess; Zen's issue tracker would confirm). Stave restores every regular tab, always.
- Only the last normal window closed is written into the shared record (36689–36703), safe only because every window holds the same tabs.

**For Stave.** SQLite already makes each write all or nothing, so the crash case is covered. A rolling timed copy of the database would still guard against Stave's own bug writing bad data. Candidate for plan 5, not built.

## Several windows, one live page (report)

- Every window keeps a copy of every tab under the same id; only one copy holds the live page. Selecting the tab in another window moves the live page there without a reload, and the other copy goes blank (23823–23876, 24243). Closing a tab in one window closes it everywhere (24207).
- When a window closes, its live pages move to the most recent other window and back/forward history is patched up afterwards. Zen's own comment admits a small chance of losing history at that moment (22788–22799, 24268–24303).
- "Unsynced" windows are an escape hatch, for example a link opened into a new window while others are open; they share nothing and are not saved into the shared record (22879–22916, 36556).

**For Stave.** Same model as "one live page, one place". Zen moves the page on click; Stave asks ("bring it here"). Add a by-hand check: close a window that holds a live page shown elsewhere, then confirm back/forward history survives.

## Pinned-tab reset (report, setting checked)

- Drifted means any change of address, ignoring the fragment (the part after `#`); leaving the site is not required (87818–87827). Essentials never show as drifted (87812).
- Reset rebuilds the tab on its pinned page alone: back/forward history, scroll position and the page's saved state are dropped (87309–87344).
- Pinned tabs don't return to their pinned page on restart (`zen.pinned-tab-manager.restore-pinned-tabs-to-pinned-url` is false; checked).

**For Stave.** Stave's drift rule now ignores the fragment too (`Tab.isSamePage`), so hash-routed sites such as Gmail don't show "back to pinned page" constantly. Stave keeps showing drift on Essentials, as the spec says.

## Compact mode (settings checked, logic from report)

- Default settings (checked): the sidebar shows on hover; the toolbar is **not** hidden by default (`hide-toolbar` false, `hide-tabbar` true); the sidebar stays 150 ms after the pointer leaves; the toolbar hides 1000 ms after hover ends; once the pointer leaves the window, the bars stay until it is 200 px past a side edge or 100 px past the top or bottom.
- No delay before the bars appear. On macOS a short extra wait applies on leave, because macOS briefly reports the pointer as gone over draggable areas (81554–81557). Compact styling is switched off for fullscreen video (style rules near 70934).
- Not found: the width of the edge strip, and what keyboard focus does while the bars are hidden.

**For Stave.** Numbers to compare against in PR #3's hover checks. Stave's spec hides both sidebar and toolbar; Zen hides only the sidebar by default.

## Arc import (report)

- Zen imports Arc's main sidebar only (little Arc windows skipped). Top Apps become Essentials per Arc profile; each space brings its name, emoji, theme colours and pinned section only; unpinned tabs are not imported; splits flatten to tabs; Easels and other kinds are skipped without a word; Arc profiles become Firefox containers (197609, 877622–877770).
- Order comes from each item's `childrenIds`, falling back to items that name the parent in `parentID` (877653–877664).

**For Stave.** Stave's parser now does the same fallback, but says so: an item that names its parent but appears in no `childrenIds` list goes at the end of that folder or space, in file order, and the import report counts it. A `childrenIds` entry that names no item is reported too. Stave already reports what it skips and offers unpinned tabs.

## Seen only as setting names (checked)

- Glance opens with Option-click (`zen.glance.activation-method` "alt").
- Split view: drag over a page to split (`enable-drag-over-split`, threshold 40), click-to-split and drop enabled. Splits are saved in the shared session record (report, 36031).
- Essentials are kept per workspace setting (`zen.workspaces.separate-essentials` true); container-specific Essentials exist as a setting (report). Logic not read.
- Sync: each save signals "sidebar data collected" for Firefox Sync (report, 36588). Not read further.

## Still unknown

⌘1–9 counting, where new tabs go, Essentials on workspace switch, Glance's cookies and sign-in popups, sync details. Readable the same way when their plans come up. The Passwords allow-list process and Zen's regretted defaults need people.
