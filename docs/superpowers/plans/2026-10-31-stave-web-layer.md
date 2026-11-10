# Stave Web Layer Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Tabs show real web pages. Each tab gets a lazily created, restorable `WKWebView` on its profile's or container's own data store. Private windows use a throwaway store. Links and pop-ups stay tied to their opener, content blocking is on, and downloads and camera/mic permissions work. Nothing is written for a closed tab, and a stored URL never loads without a scheme check.

**Architecture:** Rules stay in `StaveCore`, tested with `swift test` and free of WebKit. They cover navigation policy, the page-event recorder, hibernation, downloads, site settings and failure text. A new library target `StaveWeb`, in the same package, holds the `@MainActor` WebKit glue: data stores, the page host (Stave's own pool, keyed by tab ID), and the navigation, UI and download delegates. It depends on `StaveCore` and on `ChorusEngine`, which supplies only the content blocker. The app target hosts each live page through the engine's `WebViewContainer`. `LivePageRegistry` still decides which single window shows each page.

**Tech Stack:** Swift 6 (must compile on Swift 6.0.3 / Xcode 16.2), Swift Testing, GRDB 7 (capped `<7.9`), WebKit (macOS 14 API only), `ChorusEngine` from `https://github.com/nicojan/Chorus.git` pinned `exact: "1.5.32"`, SwiftUI in AppKit windows, XcodeGen.

**Spec:** `docs/superpowers/specs/2026-10-28-stave-design.md`: "The organization model" (profiles, containers, private window, one live page per window, moving things), "Data model rules" (state saved as it changes, lazy restore), "First release" items 6 and 8 (only the parts listed under Scope), "Dependencies on Chorus's engine". Also read: roadmap entry 3 in `2026-10-28-stave-foundation.md`, and the "Carried into later plans" sections of plans 1, 2 and 4.

**Stacks on PR #3.** This branch, `feat/web-layer`, starts from `feat/window-sidebar` at `1d30da9`, because PR #3 (plan 4) is not merged yet. Once Nico merges PR #3, rebase onto `main` (`git rebase --onto main 1d30da9 feat/web-layer`) before opening this plan's PR. If PR #3 changes before merging, rebase onto the new head first.

## The engine at v1.5.32 (read 2026-10-31)

- The tag exists on `origin` (`c50c809`). Chorus CI ("Test") passed on that commit.
- The root `Package.swift` declares `swift-tools-version: 6.0`, `platforms: [.macOS(.v14)]` and no dependencies. It has one library, `ChorusEngine`, and the package's name is `Chorus`. Both match Stave's macOS 14 / Swift 6.0.3 limits.
- What Stave can use as published: `ContentBlockerManager` (`init(adResource:annoyanceResource:isEnabled:annoyanceEnabled:)`, `start()`, `onReady`, `enabledLists()`, `isEnabled`, `annoyanceEnabled`; `@MainActor @Observable`), `WebViewContainer(webView:cornerRadius:)`, `UserAgentProvider`, and the `WebViewCoordinator` statics.
- What Stave can't use as published, and why:
  - `WebSurface.DataStore` has only `.persistent`, so it can't build throwaway stores.
  - `UserScriptManager.configureScripts` and `NotificationMessageHandler.init` are internal, so notification forwarding can't be installed outside `WebViewPool`.
  - `DownloadCenter.begin`, `setDestination` and `fail` are internal, so only the engine's own coordinator can feed it.
  - `WebViewPool`, `ServiceTabs` and `InAppBrowserWindow` are shaped around services, and they show "Chorus" in user-facing strings.
  - `DataStoreManager` switches off Intelligent Tracking Prevention on every store it builds. That trade-off suits Chorus, where a store serves one service. A Stave profile store holds a person's whole browsing, so it doesn't suit Stave (decision 1).
- The logger subsystem is `com.nicojan.Chorus`, so the content blocker's few log lines land under Chorus. Accepted for now.
- The Chorus handoff's open WhatsApp database error is in Chorus's app model (SwiftData). It isn't in `ChorusEngine/`, which holds no database code.
- Resources: the engine bundle `ChorusEngine_ChorusEngine.bundle` ships `hagezi-light.json` and `fanboy-annoyance.json` (the ad and annoyance lists), `darkreader.js`, and the licence texts for GPL-3.0, CC BY 3.0, Dark Reader's MIT and Chorus's MIT. Stave's `THIRD_PARTY_NOTICES.md` must name them (Task 1).

This follows the spec's "How much of the engine Stave uses (my call)": Stave writes its own tab model, pool and pop-up handling, and nothing on its critical path waits on an engine change. The engine changes Stave would use later are listed at the end. They go to Chorus as their own work and come back through a new tag.

## Scope

In: the roadmap's web layer (tab page pool, `interactionState` restore, pop-ups tied to their opener, data stores per profile, named container and private window, content blocking with a per-site off switch, downloads, camera and microphone permission per site). Also:

- the navigation every page needs: Back, Forward, Reload, Stop, a load progress bar, and error and crash states
- JavaScript alerts, confirms and prompts, plus file upload, without which sign-ins and forms silently break
- the private window
- the carry-forwards from plans 1 and 4 listed under "Carried in"

Out, each with its reason:

- Web notifications (needs the engine change above).
- Location permission (WebKit asks through SPI on macOS).
- Throwaway containers (post-beta per the spec's cut line).
- History recording and the command bar's history source, favicon images in the sidebar, find, zoom, print, Web Inspector, and HTTP auth prompts (plan 5, browser basics).
- Default-browser registration and links from other apps (plan 5).
- Passkeys (waiting on Apple's entitlement).
- Profile and container deletion UI, which removes data stores (plan 5, with the confirmation UI).

Carried in:

- From plan 4: the scheme check before loading a stored URL. An unloaded pinned tab or Essential releases its page, and a waiting window gets a closed Essential's page. Compact mode's Tab must not be swallowed inside a page. The cross-window reload moves out of the SwiftUI `.onChange`. The `https://user@host` ruling (decision 9). The remaining `LivePageRegistry` edge cases.
- From plan 1: adopt a favicon that arrives late as `pinnedFaviconURL`.
- From the spec's Open checks: DRM video gets a recorded by-hand result.

## Global Constraints

- macOS deployment target `14.0`; `SWIFT_VERSION` `6.0`; strict concurrency complete. No Swift 6.1+ features and no WebKit or AppKit API newer than macOS 14 (check each new WebKit symbol's availability; no `Synchronization.Mutex`). Never nest `try #require` inside `#expect`; hoist it to a `let`.
- `ChorusEngine` is pinned `exact: "1.5.32"`, product `ChorusEngine`, package `Chorus`. Engine code is never edited here.
- Bundle ID `com.nicojan.Stave`, Debug `com.nicojan.Stave.debug`. WebKit puts `WKWebsiteDataStore(forIdentifier:)` folders under `~/Library/WebKit/<bundle id>/`, which keeps Debug apart. **`WKWebsiteDataStore.default()` is never used**: every page's store comes from `WebDataStores` (Task 6).
- Logic goes in `StaveCore` with tests; WebKit code goes in `StaveWeb`; views hold layout, focus and animation state only. Every label, message and menu enablement rule is a `StaveCore` function.
- Nothing is deleted without passing through the archive. A page write for a tab that no longer exists is dropped, never re-creates the tab and never shows an error.
- The private window writes nothing to disk: no store rows, no window state, no downloads list after it closes, and a non-persistent data store.
- Test fixtures and by-hand checks use `example.com`, `example.org` and `example.net`, or local HTML strings. Package tests never touch the network. By-hand checks use a throwaway data folder and `-StaveArcHome`, as in plan 4's "The by-hand check", which this plan reuses unchanged, with screenshots named `plan3-task<N>-<what>.png`.
- Shortcuts keep Safari's meaning: ⌘R Reload, ⌘. Stop, ⌘[ Back, ⌘] Forward, ⇧⌘N New Private Window.
- Licence MIT. Copy no code from Zen (MPL-2.0), Ora (GPL-2.0) or Nook (GPL-3.0). Chorus code is MIT. Adapting an engine pattern is fine with attribution in `THIRD_PARTY_NOTICES.md`, but this plan depends on the engine and doesn't copy from it.
- Commits: `<type>: <description>`. Stage named paths only, never `git add -A`. Never `--no-verify`, never force-push. Markdown is never hard-wrapped. After adding or removing app files, run `xcodegen generate` and commit `Stave.xcodeproj/project.pbxproj` with the task.

## Decisions (my call unless noted; Nico can overturn any)

1. **Intelligent Tracking Prevention stays on (WebKit's default, as in Safari).** Stave builds its stores with `WKWebsiteDataStore(forIdentifier:)` itself and doesn't use the engine's `DataStoreManager`, which turns ITP off. Reason: a profile store holds all of a person's browsing, so ITP off would let trackers keep cross-site cookies across everything. The risk is enterprise SSO that refreshes through a third-party frame, such as Teams, which Chorus hit. It goes on the sign-in checklist, and a per-site exception can follow if a real site loops. **Flag for Nico.**
2. **Web views are made lazily.** On launch only each window's selected tab loads. A tab gets a web view when it is shown, or when a page opens it as a linked tab. A blank tab (empty stored URL) has no web view until it navigates; its content area shows "New Tab" with a hint to press ⌘L.
3. **Restore:** a tab with stored `interactionState` gets it set on a fresh web view (back/forward history comes back). Without it, the stored URL loads, after the navigation policy allows it.
4. **When writes happen:** URL, title and favicon are written when they change, with identical repeats skipped, and bump `StoreRevision`. `interactionState` is written at most once every 2 s per tab while the page changes, and flushed when the tab is unloaded, closed or deselected, and at quit. Those writes don't bump `StoreRevision`, because the sidebar doesn't show the state.
5. **Main-frame navigation policy:**
   - Allowed: `http`/`https` with a non-empty host, `about:blank`, and `blob:` (for page-made navigations).
   - Refused: `file:`, `data:`, `javascript:` and every other scheme from a stored or restored URL. A `data:` main frame is refused even when a page makes it.
   - Subframes may use `about:`, `data:` and `blob:` too.
   - A user-initiated page link (or a typed address) to any other scheme (`mailto:`, `tel:`, `zoommtg:`) asks "Open this link in ‹App›?" and then hands it to that app. Without a user gesture it is refused silently. With no app for the scheme, it is refused with the "No app can open this link" message.
6. **Opening links:**
   - `target=_blank` and `window.open` without size features become a sidebar tab directly below the opener, selected in the opener's window.
   - ⌘-click opens a background tab below the opener. ⇧⌘-click opens it and selects it.
   - `window.open` with `width`, `height` or `popup` features opens a pop-up window. It is never saved, it closes when the page calls `window.close()` or when its opener tab closes, and links opened from it go below its opener tab.
   - Both kinds use the configuration WebKit passes in, so `window.opener` and the opener's store carry over.
   - Pop-ups without a user gesture stay blocked (`javaScriptCanOpenWindowsAutomatically = false`).
7. **User agent:** WebKit's own agent plus `applicationNameForUserAgent = "Version/<v> Safari/605.1.15"`, where `<v>` is the system Safari's `CFBundleShortVersionString`, or `17.0` when that can't be read. Reason: claiming a newer Safari than the system's WebKit, as the engine's fixed `Version/26.0` would on macOS 14, invites features the engine lacks.
8. **Hibernation:** every 60 s, a page that isn't shown in any window is unloaded once it has been unshown for 30 minutes. Live pages are capped at 24, least recently shown first. Pages playing media or using the camera or mic are never unloaded. Unloading flushes the recorder first.
9. **`https://user@host` links** open as other browsers open them. The address field already shows only the real host (`DisplayText.address`), so `https://example.com@example.net` reads `example.net`. A test pins that. **Flag for Nico:** this settles plan 4's open question unless Nico prefers to refuse such links.
10. **Content blocking:** the ad list is on and the annoyance list off (the engine's defaults). A per-site switch, keyed by lowercased host per profile, is set from View ▸ Content Blocking on This Site and from a command bar action. Changing it reloads the page. Rule lists that compile after a page loaded are attached to it once `onReady` fires, taking effect from that page's next load.
11. **Camera and microphone:** the first request from a host asks with a sheet ("Allow example.com to use your camera?", Allow / Don't Allow, plus "Remember for this site", on by default). A remembered answer is stored per profile and host. In a private window answers are kept in memory only. Corrected 2026-11-03: WebKit runs macOS's own permission check first, so on first use the macOS prompt comes before Stave's sheet, and if macOS refuses Stave the site never asks Stave (nothing is stored then).
12. **Downloads:**
    - They go to `~/Downloads`. The name is the suggested filename, sanitized and made unique ("name (2).ext").
    - The finished file gets a quarantine attribute naming Stave and the source URL, so Gatekeeper checks it.
    - The list lives in memory per owner (profile or private window). It shows in a popover from a sidebar bottom-bar button that appears while the list has rows. Cancel, Show in Finder and Clear are offered.
    - A private window's rows disappear when it closes. The files stay.
13. **Errors:** a failed load, a refused URL, a TLS failure and a crashed page show a native panel over the content area with plain words and a Reload button (Back too, when possible). A crash never reloads by itself. There's no "proceed anyway" for TLS errors.
14. **Focus:**
    - After a navigation started from the command bar or address field, keyboard focus moves into the page, as in Safari.
    - Selecting a tab from the sidebar leaves focus in the sidebar, and Tab moves into the page.
    - In compact mode, Tab is never intercepted while focus is inside a page.
15. **The private window** (⇧⌘N):
    - It has its own sidebar: a plain tab list, and no Essentials, pinned tabs, workspaces or archive.
    - ⌘T and ⌘L open the command bar with only the typed row (URL or search).
    - Revised 2026-11-04 (Nico, matching Chrome and Firefox): the private windows of one profile share one non-persistent store, and the camera and microphone answers kept in memory, while any of them is open, so a sign-in carries to a second private window. Closing the last one drops the store and the answers, and the next private window starts fresh. ⇧⌘N takes the profile of the key private window, else the front browser window's, else the default profile. Before this, each private window had its own store. The window is never saved or restored.
    - Closing it closes its pop-ups and drops its download rows.
16. **"Showing in another window"** shows the page's last snapshot, taken when its owner window last shows a different tab or the window resigns key. Snapshots are kept in memory only.
17. **Pages survive moves:** a tab moved between workspaces of one profile keeps its live page (the host is keyed by tab ID).

## Review Focus

1. **A stored URL with a hostile scheme** (an Arc-imported `javascript:alert(1)`, `file:///etc/hosts`, `data:text/html,x`, `arc://x`, or `chrome://settings`) is selected. It never loads, the content area shows "Stave won't open this address" with the text, and nothing is written. Tests: Task 2 `storedHostileSchemesRefused`, Task 6 `hostileStoredURLNeverLoads`.
2. **Stores are isolated.** A tab in profile B, a tab in a named container and a private-window tab each get a different store: profile B's `identifier` is its `dataStoreID`, and a private store has `isPersistent == false`. A private store is never shared with a persistent profile or container store (since 2026-11-04 the private windows of one profile share theirs while any is open, decision 15), and no page ever gets `WKWebsiteDataStore.default()`. Tests: Task 6 `storesFollowProfileContainerAndPrivate`; `privateSessionNeverSharesAPersistentProfileOrContainerStore` and the other private-session tests replace `twoPrivateWindowsNeverShare`.
3. **A page write lands after its tab closed.** A late title or `interactionState` arrives after the tab was archived, in this window or another. It is dropped without re-creating the tab, without an error message, and without a revision bump. Tests: Task 4 `closedRecorderEmitsNothing`, Task 6 `writeAfterCloseIsDropped`.
4. **A download with a hostile or colliding name** (`../../.zshrc`, `.hidden`, `a/b.txt`, an empty name, control characters, 300 characters, an existing `report.pdf`) is saved inside `~/Downloads` under a visible, unique, length-capped name, and quarantined. Tests: Task 5 `filenamesAreSanitized`, `collisionsGetNumbered`; Task 6 `finishedDownloadIsQuarantined`.
5. **A page's web content process crashes.** The page shows "This page stopped working" with Reload, doesn't reload by itself, its stored state is kept, and other tabs are untouched. Tests: Task 7 `processTerminationShowsCrashedNotReload`; by hand in Task 9.

---

## File structure

```
Packages/StaveCore/Package.swift                          # T1: Chorus exact 1.5.32; StaveWeb + StaveWebTests targets
Packages/StaveCore/Sources/StaveCore/
├── Web/URLScheme.swift                                   # T2: RFC 3986 scheme reader (moved from ArcImportPlanner)
├── Web/NavigationPolicy.swift                            # T2: NavigationSource, NavigationDecision, LinkDisposition, OpenRoute
├── Web/UserAgent.swift                                   # T2
├── Web/PageFailure.swift                                 # T2: PageFailure + PageText (all page-area copy)
├── Web/SiteSettings.swift                                # T3: SiteSettingKey, SiteDecision, SiteSetting record
├── OrganizationStore+Web.swift                           # T3: site settings, updateInteractionState, dataStoreID(forTab:)
├── Database/StaveDatabase.swift                          # T3: migration v4 (siteSetting)
├── Web/PageRecorder.swift                                # T4
├── Web/HibernationPolicy.swift                           # T4
├── Web/DownloadList.swift                                # T5: DownloadOwner, DownloadItem, DownloadList, DownloadFilename
├── Web/PageMenuState.swift                               # T8: enablement for Back/Forward/Reload/Stop/blocking
├── Window/PrivateWindowModel.swift                       # T11
├── Window/BrowserWindowModel.swift                       # T8: PageLifecycle hooks
└── Window/CompactReveal.swift                            # T8: shouldInterceptTab
Packages/StaveCore/Sources/StaveWeb/
├── WebDataStores.swift                                   # T6
├── PageConfiguration.swift                               # T6
├── LivePage.swift                                        # T6: web view + KVO → PageStatus + recorder
├── PageHost.swift                                        # T6
├── Quarantine.swift                                      # T6
├── PageDelegate.swift                                    # T7: WKNavigationDelegate + WKDownloadDelegate
└── PageDelegate+UI.swift                                 # T7: WKUIDelegate
Packages/StaveCore/Tests/StaveWebTests/                   # T1, T6, T7
Stave/App/                                                # T9–T11: AppEnvironment, BrowserWindowController, AppDelegate menus,
                                                          #         PopupWindowController, PrivateWindowController, PagePrompts
Stave/Views/Content/PageContentView.swift                 # T9 (TabPlaceholderView keeps only the blank and empty states)
Stave/Views/Content/PageFailureView.swift                 # T9
Stave/Views/Sidebar/DownloadsPopover.swift                # T10
Stave/Views/Private/PrivateWindowView.swift               # T11
THIRD_PARTY_NOTICES.md                                    # T1
.github/workflows/test.yml                                # T1
```

---

### Task 1: Engine dependency and the StaveWeb target

**Files:**
- Modify: `Packages/StaveCore/Package.swift`, `project.yml`, `.github/workflows/test.yml`
- Create: `Packages/StaveCore/Sources/StaveWeb/StaveWeb.swift` (temporary; deleted in Task 6), `Packages/StaveCore/Tests/StaveWebTests/EngineLinkTests.swift`, `THIRD_PARTY_NOTICES.md`

**Interfaces:**
- Produces: library product `StaveWeb` (target `StaveWeb`, dependencies `StaveCore` and `.product(name: "ChorusEngine", package: "Chorus")`); test target `StaveWebTests`; the dependency `.package(url: "https://github.com/nicojan/Chorus.git", exact: "1.5.32")`; app target `Stave` depends on products `StaveCore` and `StaveWeb`.

- [ ] **Step 1: Write the failing tests** in `EngineLinkTests` (all `@MainActor`):
  - `contentBlockerBuilds`: `ContentBlockerManager()` has `isEnabled == true`, `annoyanceEnabled == false`, `enabledLists().isEmpty`.
  - `contentBlockerCompiles`: call `start()`, await `onReady` (bridged with a continuation, 60 s deadline); `enabledLists()` is non-empty. This proves the engine bundle loads from `swift test`.
  - `webViewLoadsLocalHTML` (the spike): a `WKWebView` on `WKWebsiteDataStore.nonPersistent()` loads `"<title>t</title>"` via `loadHTMLString(_:baseURL: nil)`. Its `title` becomes `"t"` within 10 s, polled on the main actor.
- [ ] **Step 2: Run** `swift test --package-path Packages/StaveCore --filter EngineLinkTests` → FAIL (no `StaveWeb` target).
- [ ] **Step 3: Implement.** Add the dependency and targets. `StaveWeb.swift` holds `import ChorusEngine` and nothing else. In `project.yml`, add the `StaveWeb` product to the app's dependencies, then run `xcodegen generate`.
  - **If `webViewLoadsLocalHTML` can't pass under `swift test`** (locally or on CI's macOS 14), mark it `.disabled("WebKit can't load pages in swift test here")`, record that in the commit body, and from then on read every "loads" test in Tasks 6–7 as construct-only. The behaviour moves to that task's by-hand check. Don't spend more than one attempt on making it pass.
- [ ] **Step 4: Write `THIRD_PARTY_NOTICES.md`.** It covers ChorusEngine (MIT, Nico Jan) and the files its bundle ships inside Stave.app: the HaGezi Light list (GPL-3.0), the Fanboy annoyance list (CC BY 3.0) and Dark Reader (MIT, bundled but unused). Point to the licence texts in `Stave.app/Contents/Resources/ChorusEngine_ChorusEngine.bundle/…/licenses/`. Also cover GRDB (MIT), plus the MIT sources plan 2 adapted, if they aren't credited elsewhere. Check `git log` for an existing credits file before writing.
- [ ] **Step 5: Add a CI step** after the Release build, "Release build carries the engine bundle". It runs `test -d` on `…/Release/Stave.app/Contents/Resources/ChorusEngine_ChorusEngine.bundle` and on that bundle's `hagezi-light.json`. Find the path through `-derivedDataPath build/DD`, and add that flag to both build steps.
- [ ] **Step 6: Verify.** Run `swift test --package-path Packages/StaveCore` → all pass (519 + new). Build Debug and Release with `xcodebuild` → succeeded. Run `xcodegen generate` again → `git status --porcelain Stave.xcodeproj` is empty.
- [ ] **Step 7: Commit** `chore: depend on ChorusEngine 1.5.32 and add the StaveWeb target` (stage `Packages/StaveCore/Package.swift Packages/StaveCore/Package.resolved Packages/StaveCore/Sources/StaveWeb Packages/StaveCore/Tests/StaveWebTests project.yml Stave.xcodeproj/project.pbxproj .github/workflows/test.yml THIRD_PARTY_NOTICES.md`, and the app's `Package.resolved` if xcodebuild wrote one).

### Task 2: Navigation rules, user agent and page text

**Files:**
- Create: `Sources/StaveCore/Web/URLScheme.swift`, `Web/NavigationPolicy.swift`, `Web/UserAgent.swift`, `Web/PageFailure.swift`; `Tests/StaveCoreTests/NavigationPolicyTests.swift`
- Modify: `ArcImport/ArcImportPlanner.swift` (call `URLScheme.scheme(of:)` instead of its private copy; behaviour unchanged)

**Interfaces:**
- Produces:
  - `public enum URLScheme { static func scheme(of text: String) -> String? }` (lowercased RFC 3986 scheme, or nil) and `static func hasWebAuthority(_ text: String) -> Bool` (`http`/`https` with a non-empty authority after `//`).
  - `public enum NavigationSource: Sendable, Equatable { case stored, restored, typed, page(userGesture: Bool) }`
  - `public enum NavigationDecision: Sendable, Equatable { case allow, askToOpenExternally(String), refuse(PageFailure?) }`. `refuse(nil)` is silent.
  - `public enum NavigationPolicy { static func decide(_ url: String, isMainFrame: Bool, source: NavigationSource) -> NavigationDecision }`
  - `public enum LinkDisposition: Sendable, Equatable { case current, newTab(select: Bool) }` with `static func decide(command: Bool, shift: Bool, targetsNewWindow: Bool) -> LinkDisposition`
  - `public enum OpenRoute: Sendable, Equatable { case sidebarTab, popupWindow }` with `static func route(width: Double?, height: Double?, popupRequested: Bool) -> OpenRoute`
  - `public enum UserAgent { static func applicationName(safariVersion: String?) -> String }`
  - `public enum PageFailure: Sendable, Equatable { case refused(url: String), noAppForLink(url: String), loadFailed(host: String, message: String), insecure(host: String), crashed }`
  - `public enum PageText` with `static func title(_ f: PageFailure) -> String`, `static func detail(_ f: PageFailure) -> String`, `static let newTabHint`, `static func externalAppQuestion(appName: String) -> String`, `static func mediaQuestion(host: String, camera: Bool, microphone: Bool) -> String`, `static let elsewhereTitle`.

- [ ] **Step 1: Write failing tests** (`NavigationPolicyTests`):
  - `storedHostileSchemesRefused` (Review Focus 1): for each of `javascript:alert(1)`, `JavaScript:void(0)`, `file:///etc/hosts`, `data:text/html,x`, `arc://x`, `chrome://settings`, `mailto:a@example.com`, `decide(_, isMainFrame: true, source: .stored)` is `.refuse(.refused(url: <same text>))`. The same holds with `.restored`.
  - `webSchemesAllowed`: `https://example.com`, `HTTP://example.com/x` and `about:blank` give `.allow` from every source. `https://` (empty host) and `http:example.com` give `.refuse(.refused(url:))`.
  - `pageDataMainFrameRefused`: `data:text/html,x` as main frame from `.page(userGesture: true)` → `.refuse(nil)`. As a subframe → `.allow`. `blob:https://example.com/u` main frame from a page → `.allow`.
  - `externalSchemesNeedAGesture`: `mailto:a@example.com` from `.page(userGesture: true)` → `.askToOpenExternally("mailto:a@example.com")`. From `.page(userGesture: false)` → `.refuse(nil)`. From `.typed` → `.askToOpenExternally`. As a subframe from anything → `.refuse(nil)`.
  - `fileNeverOpens`: `file:///x` → `.refuse` from every source, main frame or not.
  - `linkDispositions`: `(false,false,false)` → `.current`; `(true,false,false)` → `.newTab(select: false)`; `(true,true,false)` → `.newTab(select: true)`; `(false,false,true)` → `.newTab(select: true)`.
  - `openRoutes`: `(nil,nil,false)` → `.sidebarTab`; `(500,nil,false)` → `.popupWindow`; `(nil,nil,true)` → `.popupWindow`.
  - `userAgentNamesSystemSafari`: `"18.3"` → `"Version/18.3 Safari/605.1.15"`; `nil` and `""` → `"Version/17.0 Safari/605.1.15"`; `"18.3 beta<script>"` → only the leading `[0-9.]` run is kept: `"Version/18.3 Safari/605.1.15"`.
  - `userInfoShowsRealHost` (decision 9): `DisplayText.address(for: "https://example.com@example.net/x")` is `"example.net"`.
  - `pageTextIsPlain`: `PageText.title(.crashed)` is `"This page stopped working"`. `PageText.title(.refused(url: "file:///x"))` is `"Stave won't open this address"`, and its `detail` contains `"file:///x"`. `PageText.title(.insecure(host: "example.com"))` is `"This connection isn't private"`. `PageText.newTabHint` is `"Press ⌘L to enter an address or search."`.
- [ ] **Step 2: Run** `--filter NavigationPolicyTests` → FAIL.
- [ ] **Step 3: Implement.** The decision table is decision 5. `URLScheme` is the existing `ArcImportPlanner.scheme(of:)` logic, moved and made public. Run `--filter ArcImport` afterwards to prove plan 2 is unchanged. `PageText` holds every page-area string in this plan. Write the other titles in the same voice ("No app can open this link", "Stave couldn't open this page") with the server message in `detail`.
- [ ] **Step 4: Run** `--filter NavigationPolicyTests` and `--filter ArcImport` → PASS.
- [ ] **Step 5: Commit** `feat: navigation policy, link routing, user agent and page text`

### Task 3: Site settings and the store's web writes

**Files:**
- Create: `Sources/StaveCore/Web/SiteSettings.swift`, `OrganizationStore+Web.swift`; `Tests/StaveCoreTests/WebStoreTests.swift`
- Modify: `Database/StaveDatabase.swift` (migration `"v4"`), `OrganizationStore+Tabs.swift` (`updateNavigation` adopts a late pinned favicon), `Tests/StaveCoreTests/PathsAndDatabaseTests.swift` (table list)

**Interfaces:**
- Produces:
  - `public enum SiteSettingKey: String, Codable, Sendable { case camera, microphone, contentBlocking }`
  - `public enum SiteDecision: String, Codable, Sendable { case allow, deny }` (for `contentBlocking`, `.deny` means blocking is off for the site)
  - `public struct SiteSetting` (GRDB record: `id`, `profileID`, `host`, `key`, `decision`, `modifiedAt`), with table `siteSetting`, unique `(profileID, host, key)`, and `profileID` cascading on profile delete.
  - `public enum SiteHost { static func normalized(_ urlOrHost: String) -> String? }`: lowercased host with no port and no `www.`. Nil for a non-web URL.
  - `siteDecision(profileID: UUID, host: String, key: SiteSettingKey) throws -> SiteDecision?`
  - `setSiteDecision(profileID: UUID, host: String, key: SiteSettingKey, _ decision: SiteDecision?) throws`. Nil removes the row. Saving a setting isn't user data, so removing one needs no archive.
  - `updateInteractionState(tabID: UUID, _ state: Data?) throws`: update-only, throws `.notFound` for a missing tab, sets `modifiedAt`.
  - `dataStoreID(forTab id: UUID) throws -> UUID`: the container's `dataStoreID` when the tab has one, else its profile's. An Essential's profile comes from its slot.

- [ ] **Step 1: Write failing tests** (`WebStoreTests`):
  - `siteDecisionRoundTrips`: set camera `.allow` for `example.com` in profile P. Reading it gives `.allow`, and profile Q reads `nil`. Setting `nil` removes it.
  - `hostsNormalize`: `SiteHost.normalized("https://WWW.Example.com:8443/x")` is `"example.com"`. `"file:///x"` and `""` give nil.
  - `interactionStateOnlyTouchesState`: after `updateInteractionState(tab, Data([1,2]))` the tab's `url`, `title` and `faviconURL` are unchanged and its `interactionState` is `[1,2]`. On a closed tab it throws `.notFound` and nothing reappears.
  - `dataStoreFollowsContainer`: a plain tab gives its profile's `dataStoreID`, a tab opened with `containerID: c` gives `c`'s `dataStoreID`, and an Essential gives its profile's.
  - `latePinnedFaviconAdopted`: pin a tab at `https://example.com` with no favicon, then call `updateNavigation` with the same URL and `faviconURL: "https://example.com/f.ico"`. `pinnedFaviconURL` becomes that value. A second update with another favicon doesn't replace it, and an update while drifted (different URL) doesn't set it.
  - `migrationAddsSiteSetting`: the `PathsAndDatabaseTests` table list includes `siteSetting`, and a v3 file opens and migrates.
- [ ] **Step 2: Run** `--filter WebStoreTests` → FAIL.
- [ ] **Step 3: Implement.** One write transaction per mutating method; `modifiedAt = now()`.
- [ ] **Step 4: Run** the full package suite → PASS.
- [ ] **Step 5: Commit** `feat: site settings, interaction-state writes and per-tab data store lookup`

### Task 4: Page recorder and hibernation policy

**Files:**
- Create: `Sources/StaveCore/Web/PageRecorder.swift`, `Web/HibernationPolicy.swift`; `Tests/StaveCoreTests/PageRecorderTests.swift`, `HibernationPolicyTests.swift`

**Interfaces:**
- Produces:
  - `public enum PageEvent: Sendable, Equatable { case committed(url: String), title(String), favicon(String?), finished, stateChanged }`
  - `public enum PageWrite: Sendable, Equatable { case navigation(url: String, title: String, faviconURL: String?), interactionState }` (`.interactionState` tells the caller to read `webView.interactionState` now and write it)
  - `public struct PageRecorder: Sendable` with `init(url: String, title: String, faviconURL: String?, stateInterval: TimeInterval = 2)`, `mutating func record(_ e: PageEvent, at now: Date) -> [PageWrite]`, `mutating func flush(at now: Date) -> [PageWrite]` and `mutating func close()`
  - `public struct LivePageInfo: Sendable, Equatable { id: UUID; isShown: Bool; lastShownAt: Date; isBusyWithMedia: Bool }`
  - `public enum HibernationPolicy { static let idleLimit: TimeInterval = 1800; static let liveLimit = 24; static let interval: TimeInterval = 60; static func pagesToUnload(_ pages: [LivePageInfo], now: Date) -> [UUID] }`

- [ ] **Step 1: Write failing tests:**
  - `commitClearsTitleAndWritesOnce`: starting from `("https://example.com","A",nil)`, `committed("https://example.org")` → `[.navigation(url: "https://example.org", title: "", faviconURL: nil)]`. Then `title("B")` → one `.navigation` with title `"B"`, and `title("B")` again → `[]`.
  - `faviconWritesWithPage`: `favicon("https://example.org/f.ico")` → `.navigation` carrying it, and repeating it → `[]`.
  - `stateIsThrottled`: `stateChanged` at t=0 → `[.interactionState]`, at t=1 → `[]`, at t=2.5 → `[.interactionState]`.
  - `finishedFlushesPendingState`: `stateChanged` at t=0 and t=1, then `finished` at t=1.2 → `[.interactionState]`.
  - `flushEmitsOnlyPending`: `flush` with nothing pending → `[]`. After a throttled `stateChanged` → `[.interactionState]`.
  - `closedRecorderEmitsNothing` (Review Focus 3): after `close()`, every event and `flush` returns `[]`.
  - `hibernationSkipsShownAndBusy`: with pages shown, busy-with-media, idle 31 min and idle 10 min at `now`, only the 31-min page is returned.
  - `hibernationCapsLivePages`: 30 unshown pages idle 1–30 min → the 6 least recently shown are returned, oldest first. Shown and busy pages are never counted for removal, even when that leaves more than 24 live.
- [ ] **Step 2: Run** `--filter PageRecorderTests` and `--filter HibernationPolicyTests` → FAIL.
- [ ] **Step 3: Implement** with immutable inputs. Inside the recorder, use `mutating` methods on its value fields only; it holds no references.
- [ ] **Step 4: Run** → PASS.
- [ ] **Step 5: Commit** `feat: page write recorder and hibernation policy`

### Task 5: Downloads list and file names

**Files:**
- Create: `Sources/StaveCore/Web/DownloadList.swift`; `Tests/StaveCoreTests/DownloadListTests.swift`

**Interfaces:**
- Produces:
  - `public enum DownloadOwner: Hashable, Sendable { case profile(UUID), privateWindow(UUID) }`
  - `public enum DownloadState: Equatable, Sendable { case running(fraction: Double?), finished(URL), failed(String), cancelled }`
  - `public struct DownloadItem: Identifiable, Equatable, Sendable { id: UUID; owner: DownloadOwner; filename: String; sourceHost: String?; state: DownloadState }`
  - `@MainActor @Observable public final class DownloadList`, with:
    - `items(for: DownloadOwner) -> [DownloadItem]` (newest first)
    - `begin(owner:filename:sourceHost:) -> UUID`
    - `progress(_:fraction:)`, `finish(_:at:)`, `fail(_:message:)`, `cancel(_:)`
    - `clearFinished(owner:)`, `dropOwner(_:)`
    - `var onCancel: ((UUID) -> Void)?`
    - A row ends once, and a late report for an ended row is ignored.
  - `public enum DownloadFilename { static func sanitized(_ suggested: String) -> String; static func unique(_ name: String, in directory: URL, exists: (URL) -> Bool) -> URL }`

- [ ] **Step 1: Write failing tests:**
  - `filenamesAreSanitized` (Review Focus 4): `"../../.zshrc"` → `"zshrc"`; `".hidden"` → `"hidden"`; `"a/b.txt"` → `"a-b.txt"`; `""` and `"..."` → `"download"`; `"x\u{0}\u{7}y.pdf"` → `"xy.pdf"`; a 300-character name ending `.pdf` → at most 200 UTF-8 bytes and still ending `.pdf`; `"rapport été.pdf"` is unchanged.
  - `collisionsGetNumbered`: with `report.pdf` and `report (2).pdf` existing, the result is `report (3).pdf`. A name with no extension becomes `name (2)`. The result's parent is always `directory`.
  - `listOrdersAndSeparatesOwners`: two profile rows and one private row. `items(for: .profile(p))` gives the two newest first, and `dropOwner(.privateWindow(w))` removes only the private row.
  - `rowEndsOnce`: `finish` after `cancel` leaves `.cancelled`, and `progress` after `finish` changes nothing. `cancel` calls `onCancel` once.
- [ ] **Step 2: Run** `--filter DownloadListTests` → FAIL.
- [ ] **Step 3: Implement.** Sanitizing removes control characters, replaces `/` and `:` with `-`, and strips leading dots and spaces. It then caps the UTF-8 length at 200 bytes while keeping the extension, and falls back to `"download"`.
- [ ] **Step 4: Run** → PASS.
- [ ] **Step 5: Commit** `feat: downloads list and safe download file names`

### Task 6: StaveWeb: data stores, configuration, live pages and the page host

**Files:**
- Create: `Sources/StaveWeb/WebDataStores.swift`, `PageConfiguration.swift`, `LivePage.swift`, `PageHost.swift`, `Quarantine.swift`; `Tests/StaveWebTests/PageHostTests.swift`
- Delete: `Sources/StaveWeb/StaveWeb.swift`

**Interfaces:**
- Consumes: `NavigationPolicy`, `UserAgent`, `PageRecorder`, `HibernationPolicy`, `SiteHost`, `PageFailure` (Tasks 2–4); `ContentBlockerManager` (engine).
- Produces (all `@MainActor`):
  - `public enum DataStoreKey: Hashable, Sendable { case persistent(UUID), privateWindow(UUID) }`
  - `public final class WebDataStores` with `init()`, `func store(for key: DataStoreKey) -> WKWebsiteDataStore` (cached per key; `.persistent` uses `WKWebsiteDataStore(forIdentifier:)`, `.privateWindow` uses `.nonPersistent()`), and `func releasePrivate(_ windowID: UUID)`.
  - `public enum PageConfiguration { static func make(store: WKWebsiteDataStore, ruleLists: [WKContentRuleList], applicationName: String, messageHandler: WKScriptMessageHandler) -> WKWebViewConfiguration }`: element fullscreen on, `javaScriptCanOpenWindowsAutomatically = false`, and the favicon script below in the content world `WKContentWorld.world(name: "StaveFavicon")` with handler name `staveFavicon`, added for that world only.
  - Favicon script (exact, document end, main frame only): `(() => { const l = document.querySelector('link[rel~="icon"]'); window.webkit.messageHandlers.staveFavicon.postMessage(l ? l.href : new URL('/favicon.ico', location.href).href); })();`
  - `public struct PageRequest: Sendable, Equatable { tabID: UUID; store: DataStoreKey; siteSettingsProfileID: UUID?; url: String; title: String; faviconURL: String?; interactionState: Data? }` (`siteSettingsProfileID` is nil in a private window)
  - `@Observable public final class LivePage` with `tabID`, `webView: WKWebView`, and `status: PageStatus`. `PageStatus` is an `Equatable` struct holding `isLoading`, `progress: Double`, `canGoBack`, `canGoForward`, `url: String`, `title: String` and `failure: PageFailure?`.
  - `public protocol PageWriter: AnyObject { @MainActor func writeNavigation(tabID: UUID, url: String, title: String, faviconURL: String?); @MainActor func writeInteractionState(tabID: UUID, _ state: Data?) }`. The writer drops `StoreError.notFound` silently.
  - `public protocol SiteSettingsSource: AnyObject { @MainActor func decision(profileID: UUID, host: String, key: SiteSettingKey) -> SiteDecision?; @MainActor func setDecision(profileID: UUID, host: String, key: SiteSettingKey, _ d: SiteDecision?) }`
  - `@Observable public final class PageHost`, which has:
    - `init(stores: WebDataStores, contentBlocker: ContentBlockerManager, siteSettings: SiteSettingsSource, applicationName: String, now: @escaping () -> Date = Date.init)`
    - `func page(for request: PageRequest, writer: PageWriter) -> LivePage`: returns the existing page, or creates one by restoring `interactionState` or loading `url` after `NavigationPolicy.decide(url, isMainFrame: true, source: .stored)`. A refusal sets `status.failure` and loads nothing. An empty `url` makes no load.
    - `func existingPage(_ tabID: UUID) -> LivePage?`
    - `func adopt(_ webView: WKWebView, as request: PageRequest, writer: PageWriter) -> LivePage`, for pages WebKit created
    - `func markShown(_ tabID: UUID, _ shown: Bool)`
    - `func unload(_ tabID: UUID)` (flush, snapshot, tear down) and `func close(_ tabID: UUID)` (recorder `close()`, then tear down, with no flush)
    - `func snapshot(for tabID: UUID) -> NSImage?`
    - `func flushAll()`
    - `func hibernateIdle() async`: asks each candidate's `requestMediaPlaybackState()` and camera/mic capture state before unloading
    - `func setContentBlocking(_ on: Bool, for tabID: UUID)` (swaps the rule lists, then reloads)
    - `func reattachRuleLists()`
    - Task 7 adds `public weak var events: PageEvents?` and installs a `PageDelegate` on each page it makes or adopts. Until then, pages have no delegate.
  - `public enum Quarantine { static func mark(_ file: URL, source: URL?) throws }`

- [ ] **Step 1: Write failing tests** (`PageHostTests`, `@MainActor`, a fake `PageWriter` that records calls, and a fake `SiteSettingsSource`):
  - `storesFollowProfileContainerAndPrivate` (Review Focus 2): `.persistent(a)` gives `isPersistent == true` and `identifier == a`. `.persistent(b)` gives a different store, and asking for `.persistent(a)` again gives the identical instance. `.privateWindow(w)` gives `isPersistent == false`.
  - `twoPrivateWindowsNeverShare`: `.privateWindow(w1)` and `.privateWindow(w2)` give different instances. After `releasePrivate(w1)`, `.privateWindow(w1)` gives a new instance.
  - `noDefaultStoreEver`: no store from either key is `WKWebsiteDataStore.default()`. Compare identity, and check `isPersistent && identifier == nil` is never true.
  - `hostileStoredURLNeverLoads` (Review Focus 1): a page for a request with `url: "javascript:alert(1)"` has `status.failure == .refused(url: "javascript:alert(1)")` and `webView.url == nil` after 0.5 s.
  - `blankTabMakesNoLoad`: `url: ""` → `webView.url == nil` and `failure == nil`.
  - `restoreUsesInteractionState`: load local HTML in page A until finished, read its `interactionState` as `Data`. A new page for a new tab ID with that state and `url: "https://example.invalid"` comes back with A's URL, not `example.invalid`. Construct-only fallback: assert the state was assigned before any `load`, using a test hook `LivePage.didRestoreState`.
  - `writeAfterCloseIsDropped` (Review Focus 3): close a page, then push a title through its KVO path (set via `loadHTMLString` before `close`). The writer records no call after `close`.
  - `unloadFlushesThenTearsDown`: a page with pending throttled state gets `unload`. The writer got exactly one `writeInteractionState`, `existingPage` is nil, and `snapshot(for:)` isn't nil when the page had drawn (otherwise skip that assert in construct-only mode).
  - `finishedDownloadIsQuarantined` (Review Focus 4, part): write a temp file, call `Quarantine.mark(file, source: URL(string: "https://example.com/f")!)`, and read back `resourceValues(forKeys: [.quarantinePropertiesKey]).quarantineProperties`. It isn't nil, and its `kLSQuarantineAgentNameKey` is `"Stave"`.
- [ ] **Step 2: Run** `--filter PageHostTests` → FAIL.
- [ ] **Step 3: Implement.**
  - `LivePage` observes `url`, `title`, `isLoading`, `estimatedProgress`, `canGoBack` and `canGoForward` with KVO. It turns them into `PageEvent`s, feeds the `PageRecorder`, and passes the resulting `PageWrite`s to the writer. For `.interactionState` it reads `webView.interactionState as? Data`.
  - Favicon messages arrive through the configuration's handler and become `.favicon`.
  - The rule lists at creation are `contentBlocker.enabledLists()`, unless the site setting for the URL's host says `contentBlocking == .deny`.
  - The hibernation timer runs every `HibernationPolicy.interval` while any page is live. It feeds `LivePageInfo` from `markShown` times and the media checks.
  - Quarantine uses `URLResourceValues.quarantineProperties` with `kLSQuarantineAgentNameKey: "Stave"`, `kLSQuarantineTypeKey: kLSQuarantineTypeWebDownload` and `kLSQuarantineDataURLKey: source`.
- [ ] **Step 4: Run** `--filter PageHostTests` and the full suite → PASS.
- [ ] **Step 5: Commit** `feat: page host with per-profile stores, lazy restore and hibernation`

### Task 7: StaveWeb: page delegate

**Files:**
- Create: `Sources/StaveWeb/PageDelegate.swift`, `PageDelegate+UI.swift`; `Tests/StaveWebTests/PageDelegateTests.swift`
- Modify: `PageHost.swift` (adds `public weak var events: PageEvents?`, and installs a `PageDelegate(page:host:events:)` on every page it makes or adopts. The host keeps the delegate alive, because WebKit holds delegates weakly.)

**Interfaces:**
- Consumes: Task 2's policy types, Task 5's `DownloadList` and `DownloadFilename`, Task 6's host types and `Quarantine`.
- Produces: `public final class PageDelegate: NSObject, WKNavigationDelegate, WKUIDelegate, WKDownloadDelegate` (`@MainActor`), with `init(page: LivePage, host: PageHost, events: PageEvents)` and the protocol:

```swift
@MainActor public protocol PageEvents: AnyObject {
    func openLinkedTab(opener: UUID, url: String, select: Bool, webView: WKWebView?) -> UUID?   // nil: refused (opener gone)
    func openPopup(opener: UUID, webView: WKWebView, features: WKWindowFeatures)
    func closePage(_ tabID: UUID)                                                                // window.close() from a page Stave opened
    func confirmExternalApp(url: URL, appName: String) async -> Bool
    func askMedia(tabID: UUID, host: String, camera: Bool, microphone: Bool) async -> (allow: Bool, remember: Bool)
    func alert(tabID: UUID, message: String) async
    func confirm(tabID: UUID, message: String) async -> Bool
    func prompt(tabID: UUID, message: String, defaultText: String?) async -> String?
    func chooseFiles(tabID: UUID, allowsMultiple: Bool, allowsDirectories: Bool) async -> [URL]?
    func downloadOwner(tabID: UUID) -> DownloadOwner
    var downloads: DownloadList { get }
    var downloadsDirectory: URL { get }
}
```

- [ ] **Step 1: Write failing tests** (`PageDelegateTests`, `@MainActor`, a fake `PageEvents`; call the delegate methods directly with values WebKit can build in tests where possible, otherwise test the pure helper each method calls):
  - `mainFramePolicyFollowsNavigationPolicy`: `decidePolicy` for a main-frame `https://example.com` action gives `.allow`. For `file:///x` it gives `.cancel` and sets `status.failure`. Keep the policy call in an internal static `PageDelegate.decision(for url: String, isMainFrame: Bool, userGesture: Bool, modifiers: NSEvent.ModifierFlags, targetsNewWindow: Bool) -> (NavigationDecision, LinkDisposition)` and test that if `WKNavigationAction` can't be built in a test.
  - `commandClickOpensBackgroundTabBelowOpener`: `decision(… modifiers: .command …)` → `.newTab(select: false)`. The delegate calls `openLinkedTab(opener:, url:, select: false, webView: nil)` and cancels the original navigation.
  - `blankTargetBecomesLinkedTab`: `createWebViewWith` with no size features calls `openLinkedTab` with a non-nil `webView`, and returns the same web view, built from the passed configuration.
  - `sizedWindowOpenBecomesPopup`: features `width = 500` call `openPopup` and return its web view.
  - `processTerminationShowsCrashedNotReload` (Review Focus 5): `webViewWebContentProcessDidTerminate` sets `status.failure = .crashed` and starts no load (`isLoading` stays false after 0.5 s). The writer gets no call.
  - `tlsFailureIsInsecure`: `didFailProvisionalNavigation` with `NSURLErrorServerCertificateUntrusted` sets `.insecure(host:)`. `NSURLErrorCancelled` (-999) sets nothing.
  - `mediaUsesRememberedDecision`: with the site setting camera `.allow` for `example.com`, the media decision for a camera request from `https://example.com` is `.grant`, and `askMedia` isn't called. With nothing stored, `askMedia` is called, and an answer `(true, true)` stores `.allow`. In a private window (`siteSettingsProfileID == nil`), the answer is kept in an in-memory dictionary on the host, never stored.
  - `downloadNamesAreSafe`: `decideDestinationUsing response:suggestedFilename: "../../.zshrc"` returns a URL whose parent is `downloadsDirectory` and whose name is `zshrc`, unique against existing files. Use a temp directory as `downloadsDirectory`.
- [ ] **Step 2: Run** `--filter PageDelegateTests` → FAIL.
- [ ] **Step 3: Implement.**
  - **Navigation:**
    - `decidePolicyFor navigationAction` handles policy, link disposition and external apps. The app name comes from `NSWorkspace.urlForApplication(toOpen:)`. With none, it sets `.noAppForLink`.
    - Before a main-frame navigation to a new host, apply the content-blocking site setting.
    - `decidePolicyFor navigationResponse` turns a response WebKit can't show (`!canShowMIMEType`) into `.download`.
    - The failure callbacks fill in `PageFailure`.
  - **UI:** `createWebViewWith` follows `OpenRoute`. `webViewDidClose` calls `closePage`. The JavaScript panels and `runOpenPanelWith` go to `events`.
  - **Media:** `requestMediaCapturePermissionFor` (superseded 2026-11-03: the Swift method must be `webView(_:decideMediaCapturePermissionsFor:initiatedBy:type:)`, see fix 1) uses `SiteHost.normalized(origin.host)` and the stored decision, otherwise `askMedia`.
  - **Downloads:**
    - `begin` the row in `events.downloads`.
    - Observe `download.progress`.
    - On finish, quarantine the file and `finish`.
    - On failure, `fail` with `error.localizedDescription`.
    - `onCancel` cancels the `WKDownload`.
- [ ] **Step 4: Run** the full suite → PASS.
- [ ] **Step 5: Commit** `feat: page delegate for navigation, pop-ups, prompts, permissions and downloads`

### Task 8: Window model hooks, menu state, compact Tab, registry edge cases

**Files:**
- Create: `Sources/StaveCore/Web/PageMenuState.swift`; `Tests/StaveCoreTests/PageLifecycleTests.swift`
- Modify: `Window/BrowserWindowModel.swift`, `Window/CompactReveal.swift`, `Tests/StaveCoreTests/LivePageRegistryTests.swift`, `CompactRevealTests.swift`

**Interfaces:**
- Produces:
  - `@MainActor public protocol PageLifecycle: AnyObject { func tabClosed(_ id: UUID); func tabUnloaded(_ id: UUID); func tabDeselected(_ id: UUID) }`, and `public weak var pages: PageLifecycle?` on `BrowserWindowModel`.
  - `BrowserWindowModel` calls:
    - `tabClosed` for every tab its action archives or removes: `close` → `.archived`, `removePinned`, `removeEssential` (archived), `deleteWorkspace` (each archived tab).
    - `tabUnloaded` for `close` → `.unloaded`, only when after the selection moves `livePages` has no owner for that tab. If a waiting window took it, the page stays live.
    - `tabDeselected` for the previous selection whenever the selection changes.
  - `public func openLinkedTab(url: String, opener: UUID, select: Bool) -> UUID?` on `BrowserWindowModel`. It uses the existing `openTab` path with `.link(openerTabID:)` and returns the new tab's ID (nil if the opener is gone), selecting it only when `select`.
  - `LivePageRegistry.owner(of tabID: UUID) -> UUID?`, public (read-only).
  - `public struct PageMenuState: Equatable, Sendable { canGoBack, canGoForward, canReload, canStop, blockingOn: Bool?; static func from(status: PageStatusSummary?, sheetOpen: Bool) -> PageMenuState }` with `public struct PageStatusSummary: Equatable, Sendable { isLoading, canGoBack, canGoForward, hasPage, blockingOn: Bool? }`. StaveCore must not see `PageStatus` from StaveWeb, so the app maps one onto the other.
  - `CompactReveal.shouldInterceptTab(focusInPage: Bool, isRevealed: Bool, menuOpen: Bool, sheetOpen: Bool, commandBarOpen: Bool) -> Bool` (static). `CompactDriver`'s current guard moves into it, plus `!focusInPage`.

- [ ] **Step 1: Write failing tests:**
  - `closingRegularTabReportsClosed`: a fake `PageLifecycle` gets `tabClosed(id)` once.
  - `closingSelectedEssentialHandsPageToWaiter`: windows W1 (owner) and W2 (waiting) on the same Essential E. W1 closes E, and W1's selection moves on. The registry owner of E is W2, and the fake gets no `tabUnloaded(E)`.
  - `closingUnwatchedPinnedUnloads`: closing a pinned tab no other window wants gives `tabUnloaded`.
  - `selectionChangeReportsDeselected`.
  - `linkedTabOpensBelowOpenerAndSelects`: `openLinkedTab(url:opener:select: true)` returns an ID placed directly below the opener in `rows`, and it is selected. With `select: false` the selection is unchanged. With a closed opener → nil.
  - Registry edge cases in `LivePageRegistryTests`:
    - `bringHereUnwantedTab`: W1 brings T, which no one wanted. W1 owns it, and W2 showing T reads `.elsewhere(W1)`.
    - `tabRemovedWithWaiters`: after removal, neither window wants T, and a later `show` makes the shower owner.
    - `closedWaiterLosesItsPlace`: W2 and W3 wait on T, W2 closes, and W1 releasing hands T to W3.
    - `showSameTabTwiceKeepsPlace`: W2 calls `show(T)` twice while waiting, and W3 asks after. W1 releasing hands T to W2.
  - `pageMenuState`: no page → everything false and `blockingOn == nil`. Loading → `canStop`. A sheet open → everything false.
  - `tabNotInterceptedInPage`: `shouldInterceptTab(focusInPage: true, isRevealed: false, …false)` is false. The same with `focusInPage: false` is true.
- [ ] **Step 2: Run** `--filter PageLifecycleTests`, `--filter LivePageRegistryTests` and `--filter CompactRevealTests` → FAIL.
- [ ] **Step 3: Implement.** Keep every existing `BrowserWindowModelTests` passing.
- [ ] **Step 4: Run** the full suite → PASS.
- [ ] **Step 5: Commit** `feat: page lifecycle hooks, page menu state and compact Tab inside pages`

### Task 9: App: live pages in browser windows

**Files:**
- Create: `Stave/Views/Content/PageContentView.swift`, `PageFailureView.swift`; `Stave/App/StorePageWriter.swift` (the `PageWriter` and `SiteSettingsSource` over `OrganizationStore`; navigation writes bump `StoreRevision`)
- Modify: `Stave/App/AppEnvironment.swift` (owns `WebDataStores`, `ContentBlockerManager`, `PageHost`, `DownloadList`; calls `contentBlocker.start()` with `onReady = pageHost.reattachRuleLists`), `BrowserWindowController.swift`, `BrowserWindowView.swift`, `Stave/Views/Content/TabPlaceholderView.swift` (blank and empty states only), `AppDelegate.swift` (menus; `flushAll()` in `quit()` before windows close), `Stave/Views/Compact/CompactDriver.swift`

**Interfaces:**
- Consumes: Tasks 6–8.
- Produces: `BrowserWindowController` conforms to `PageLifecycle` and `PageEvents`. One app-wide `PageEventsRouter` sends each page's events to the window that owns the opener (`livePages.owner(of:)`). If no window owns it, they go to the front window of the same profile.

- [ ] **Step 1: Implement.**
  - **Revision reload:** move it from `BrowserWindowView`'s `.onChange(of: revision.value)` into `BrowserWindowController`, through `withObservationTracking`, re-armed after each change, like `observeModel()`. This is plan 4's carry-forward.
  - **Showing the selected tab:**
    - When the placement is `.here`, the controller asks `pageHost.page(for:writer:)`. The request's store is `.persistent(store.dataStoreID(forTab:))`, and its `siteSettingsProfileID` is the profile.
    - It calls `markShown` and `store.markActive`.
    - `PageContentView` shows `WebViewContainer(webView:)` with a 2 pt progress bar while `isLoading`, and `PageFailureView` over it when `failure != nil`.
  - **Elsewhere:** `.elsewhere` shows `pageHost.snapshot(for:)` dimmed under `PageText.elsewhereTitle` and the existing "Bring it here" button.
  - **A blank tab** shows the placeholder's "New Tab" state with `PageText.newTabHint`.
  - **Lifecycle:**
    - `tabDeselected` takes a snapshot and flushes.
    - `tabClosed` calls `pageHost.close`.
    - `tabUnloaded` calls `pageHost.unload`.
    - `windowDidResignKey` snapshots the shown page.
  - **Address field and command bar:** the address field shows `status.url` live. A command-bar or address navigation calls the page's `load(URLRequest)` after `NavigationPolicy.decide(_, isMainFrame: true, source: .typed)`, then makes the web view first responder (decision 14).
  - **View menu:** Back ⌘[, Forward ⌘], Reload ⌘R and Stop ⌘. are enabled by `PageMenuState`. They act on the key window's selected page.
  - **Compact mode:** `CompactDriver` computes `focusInPage`, which is true when the first responder is a `WKWebView` or a descendant of one, and calls `CompactReveal.shouldInterceptTab`.
- [ ] **Step 2: Verify the build** (plan 4's by-hand check, step 1), and run the full package suite → PASS.
- [ ] **Step 3: By-hand check** (throwaway folder `/private/tmp/stave-check-p3t9`, `-StaveSeedSample`), with a screenshot for each:
  1. ⌘T, type `example.com`, Return: the page renders, the sidebar row's title becomes "Example Domain", and focus is in the page.
  2. Click the page's link, then ⌘[ and ⌘]: back and forward work, and the menu enablement follows.
  3. Quit with ⌘Q and relaunch with the same arguments: the tab is selected and loads, and ⌘[ goes back (history restored).
  4. `kill -9` the app while a second tab is loaded, then relaunch: both tabs are listed, only the selected one loads, and the other loads when selected.
  5. A seeded Arc-style stored URL `javascript:alert(1)` (add it with a Debug-only seed entry in `SampleOrganization`) shows "Stave won't open this address".
  6. A Debug-only menu item, Debug ▸ Crash Page Process, calls WebKit's `_killWebContentProcess` on the shown page. The selector is probed with `responds(to:)` first, and the item is disabled if it's missing. The page shows "This page stopped working", and Reload brings it back. Never kill `com.apple.WebKit.WebContent` processes from the shell: Safari's are indistinguishable from Stave's.
  7. In compact mode with focus in a page form field, Tab moves between the page's fields and doesn't reveal the sidebar.
  8. Two windows on the same tab: the second shows the snapshot with "Bring it here", and bringing it moves the live page.
- [ ] **Step 4: Commit** `feat: browser windows show live pages` (stage the named app files and `Stave.xcodeproj/project.pbxproj`).

### Task 10: App: pop-ups, dialogs, permissions, downloads and per-site blocking

**Files:**
- Create: `Stave/App/PopupWindowController.swift`, `Stave/App/PagePrompts.swift` (sheets for external app, media, alert, confirm and prompt, plus `NSOpenPanel`), `Stave/Views/Sidebar/DownloadsPopover.swift`
- Modify: `BrowserWindowController.swift` (`PageEvents`), `AppDelegate.swift` (View ▸ Content Blocking on This Site; downloads button wiring), `Stave/Views/Sidebar/SidebarView.swift` (bottom-bar downloads button), `Packages/StaveCore/Sources/StaveCore/CommandBar/*` (action "Turn Content Blocking Off/On for ‹host›"), and its tests

- [ ] **Step 1: Write failing tests** (StaveCore, in the existing command bar tests). `CommandCandidates` gains `pageSite: PageSite?` with `public struct PageSite: Equatable, Sendable { host: String; blockingOn: Bool }`, filled by the app from the selected page. Test `blockingActionNamesHost`: With a selected page on `example.com` and blocking on, the actions include `"Turn Off Content Blocking for example.com"`. With it off, they include `"Turn On Content Blocking for example.com"`. With no page, there's no such action.
- [ ] **Step 2: Run** `--filter CommandBar` → FAIL; implement the action; run → PASS.
- [ ] **Step 3: Implement the app side.**
  - **Pop-up windows:** 480 × 640 by default, or the features' size clamped to the screen. Titled with the page title or its host. Not restorable and not in `WindowSession`. The controller keeps `[openerTabID: [PopupWindowController]]`, and closing the opener's page (`tabClosed` or `tabUnloaded`) closes its pop-ups.
  - **Prompts:**
    - Prompts are sheets on the owning window. A page's dialog never blocks another window.
    - Media prompt text comes from `PageText.mediaQuestion`.
    - Add `NSCameraUsageDescription` and `NSMicrophoneUsageDescription` to `Info.plist` ("Websites you allow can use your camera." / "…microphone."). Add `com.apple.security.device.camera` and `com.apple.security.device.audio-input` to `Stave.entitlements`, which hardened runtime needs.
  - **Downloads:** the button shows while `downloads.items(for: owner)` is non-empty. The popover lists rows with progress, Cancel, Show in Finder and Clear, and every control is labelled for VoiceOver.
- [ ] **Step 4: By-hand check** (`/private/tmp/stave-check-p3t10`), with screenshots:
  1. A local test page served from `python3 -m http.server` in the scratchpad (never the repo) with `<a target=_blank>`, `window.open(u,'x','width=500')`, `alert`, `confirm` and a download link. Check: the `_blank` link opens below the opener, selected; ⌘-click opens it unselected; the sized pop-up is a window; closing the opener tab closes the pop-up; the alert and confirm sheets work; the download lands in `~/Downloads` and `xattr -p com.apple.quarantine` on it prints a value. Delete the test file afterwards.
  2. Content Blocking on This Site toggles and reloads, and the menu checkmark follows.
  3. A `mailto:` link asks "Open this link in Mail?". Cancel leaves the page where it was.
  4. Camera on `https://webrtc.github.io/samples/src/content/getusermedia/gum/`: Stave's sheet first, then macOS's prompt, and a reload with "Remember" on doesn't ask again. If the terminal session can't grant the camera, move this to the Nico checks.
- [ ] **Step 5: Commit** `feat: pop-up windows, page dialogs, camera and mic permission, downloads and per-site blocking`

### Task 11: The private window

**Files:**
- Create: `Packages/StaveCore/Sources/StaveCore/Window/PrivateWindowModel.swift`, `Tests/StaveCoreTests/PrivateWindowModelTests.swift`, `Stave/App/PrivateWindowController.swift`, `Stave/Views/Private/PrivateWindowView.swift`
- Modify: `AppDelegate.swift` (File ▸ New Private Window ⇧⌘N), `CommandBar/CommandBarModel.swift` (a typed-row-only mode, if it doesn't already accept empty candidates)

**Interfaces:**
- Produces: `@MainActor @Observable public final class PrivateWindowModel`, with:
  - `windowID: UUID`
  - `tabs: [PrivateTab]` and `selectedTabID: UUID?`
  - `open(url: String, below opener: UUID?, select: Bool) -> UUID`
  - `close(_ id: UUID)` (selects the row below, else above, else nothing)
  - `select(_ id: UUID?)`
  - `update(_ id: UUID, url: String, title: String)`
  - `PrivateTab { id: UUID; url: String; title: String }`
  - It has no store and no archive.

- [ ] **Step 1: Write failing tests:**
  - `privateTabsLiveInMemoryOnly`: opening three tabs, closing the middle one, and updating a title leave a store (from `makeTempStore()`), created beside the model and never handed to it, with zero tabs and zero archive rows.
  - `linkOpensBelowOpener`.
  - `closeSelectsBelowThenAbove`.
  - `privateCommandBarHasOnlyTypedRow`: for the input `"exam"`, the private bar's results are exactly one typed row.
- [ ] **Step 2: Run** `--filter PrivateWindowModelTests` → FAIL; implement; run → PASS.
- [ ] **Step 3: Implement the app side.**
  - The window uses a dark-tinted sidebar with "Private" at the top, the tab list, and the same `PageContentView`.
  - Page requests use `.privateWindow(windowID)`, `siteSettingsProfileID: nil`, and a `PageWriter` that updates the model only.
  - Download owner is `.privateWindow(windowID)`.
  - On close: every page goes through `pageHost.close`, pop-ups close, then `stores.releasePrivate(windowID)` and `downloads.dropOwner`.
  - The window is never passed to `WindowSession`.
- [ ] **Step 4: By-hand check** (`/private/tmp/stave-check-p3t11`):
  1. ⇧⌘N, then open `example.com`.
  2. Quit and relaunch: no private window comes back.
  3. `sqlite3 <folder>/data/stave.sqlite 'select count(*) from tab'` is unchanged by the private session.
  4. A local scratchpad page (served as in Task 10) that sets `document.cookie = "p=1"` and prints `document.cookie`: after it runs in a private window, the same page shows no `p=1` in a normal window or in a second private window.
- [ ] **Step 5: Commit** `feat: private windows on throwaway stores`

### Task 12: Whole-layer check and outcome notes

**Files:**
- Modify: this plan (append "Outcome" and "Carried into later plans"), `docs/superpowers/plans/2026-10-28-stave-foundation.md` (roadmap entry 3 status)

- [ ] **Step 1: Run** the full package suite, both app builds, and confirm CI is green on macOS 14 and 15 after pushing.
- [ ] **Step 2: By-hand run** of the spec's sign-in checklist sites that need no account (YouTube playback with fullscreen and Picture in Picture; a DRM test page such as `https://bitmovin.com/demos/drm`, **recording the result even if it fails**). Leave the account sign-ins to Nico.
- [ ] **Step 3: Write the Outcome**, including the Nico checks: sign-ins at Google, Microsoft (watch for an SSO loop, decision 1), Apple, an Okta-style SSO pop-up and GitHub; Google Docs; Google Meet with camera and mic; every pointer-driven step from Tasks 9–11 that wasn't seen; and a live VoiceOver pass over the downloads popover and the prompts.
- [ ] **Step 4: Commit** `docs: plan 3 outcome and carry-forward`

---

## Engine changes Stave would use later (requests to Chorus, not on this plan's path)

Each one goes to Chorus as its own change and comes back through a new tag. Then Stave moves its `exact:` pin after reading ENGINE.md's "Engine API changes by release".

1. A public way to install the notification bridge on any `WKUserContentController`, with the handler name and JS globals configurable (web notifications, plan 5).
2. Public `DownloadCenter.begin`, `setDestination` and `fail`, if Stave wants one shared downloads model with Chorus.
3. `WebSurface.DataStore.nonPersistent`, if Stave ever moves onto the engine pool.
4. A logger subsystem parameter.
5. An option on `DataStoreManager` to keep ITP on.

None is needed for the beta.

## Outcome (2026-10-31)

Built on `feat/web-layer` (`c64fa45..464a795`, 23 commits, stacked on PR #3): Tasks 1–11 reviewed (spec and quality, with fix rounds), then the final whole-branch review and one fix wave; Task 12 is this write-up. There are 679 package tests (66 + 613 across the two test runners), and CI is green on macOS 14 (Xcode 16.2, Swift 6.0.3) and macOS 15 on the last code commit (`464a795`, run 41273837903). Debug and Release both build, with no new warnings. Review Focus 1–5 are addressed in code (Focus 4 only after the final fix wave); by-hand confirmation is on the Nico checks. By-hand checks ran on localhost pages and throwaway data only, except the Task 12 DRM page load, which reached the network; everything that needs a signed build, a pointer, an account or a live VoiceOver is on the "Nico checks" list below and has not been seen working.

What was built, by area:

- **Engine and package layout:** `ChorusEngine` pinned `exact: "1.5.32"` (content blocker and `WebViewContainer` only); a new `StaveWeb` target for WebKit code. The Task 1 spike (a `WKWebView` loads local HTML) passed on CI macOS 14 and 15, so the load tests run for real.
- **Navigation rules (StaveCore):** `NavigationPolicy` (scheme checks per source: stored, restored, typed, page), `PageFailure`, the Safari-based user agent, page text, `AddressInput` normalising typed `localhost:port` before the policy.
- **Store and writes:** per-site settings (content blocking, camera and microphone answers) keyed by profile and lowercase host (migration v4), `interactionState` writes, `dataStoreID(forTab:)`, `PageRecorder` (deduped URL, title and favicon writes, `interactionState` at most every 2 s, flushed on unload, close, deselect and quit) and `HibernationPolicy` (30 minutes unshown, cap 24, never media, camera or tabs with open pop-ups).
- **Downloads model:** `DownloadList`, `DownloadFilename` (sanitised at the scalar level, 200-byte cap, unique names), `DownloadOwner`.
- **StaveWeb:** per-profile `WKWebsiteDataStore(forIdentifier:)` stores (never the default store; ITP left on), one non-persistent store per private window, `PageHost` and `LivePage` (lazy restore through the navigation policy, hibernation, snapshots, favicon relay), and `PageDelegate` (navigation, pop-ups, JS dialogs, file upload, media permission, downloads with quarantine from the first byte, external-app prompts, crash and error states).
- **Window model hooks:** page lifecycle events (`tabClosed`, `tabDeselected`, `tabUnloaded`), `PageMenuState`, linked tabs, compact Tab that passes through inside a page, and the plan 4 carry-forwards (unload releases pinned pages, cross-window reload moved out of `.onChange`).
- **App:** browser windows show live pages (progress bar, error and crash panels, Back/Forward/Reload/Stop, "showing in another window" snapshots, cross-window ownership); pop-up windows tied to their opener; JS alert, confirm and prompt sheets naming the asking origin and capped in length; the camera and microphone sheet with "Remember"; the downloads popover; the per-site blocking switch (menu and command bar action); the private window (⇧⌘N) on a non-persistent store that writes nothing to disk, cancels its downloads and forgets its pages and answers when it closes.

Rulings made during execution (the controller's calls; Nico can overturn any, with the cost if wrong):

- **R1:** `blob:` main frames load only from a page-made navigation; from stored, restored or typed sources they are refused with the panel. Cost if wrong: a restored blob tab shows the refused panel instead of loading a dead URL.
- **R2:** `file:` and other refused schemes from a page are silently ignored; from a stored, restored or typed main frame they show the refused panel. Cost if wrong: a page link to `file:` does nothing instead of showing a panel.
- **R3:** the download-name sanitiser strips the leading run of `.`, space, `/` and `:` then replaces the rest (the plan's order contradicted its own test). Cost if wrong: a name like `/a` loses its leading separator.
- **R4:** a page feeds its title to the recorder when a load finishes, so a same-URL reload that blanked the title heals. Cost if wrong: one redundant (deduped) recorder call per load.
- **R5:** `.committed` comes from `didCommit`, not URL KVO, so a failed load never blanks the stored title. Cost if wrong: none seen.
- **R6:** content blocking is re-evaluated per main-frame navigation to a new host, before the load. Cost if wrong: a tab that crosses sites keeps the first site's blocking setting.
- **R7:** `PageDelegate` takes over the restore gate rather than being replaced by it. Cost if wrong: none seen.
- **R8:** back, forward and reload count as user-initiated page navigations; an external scheme with no installed app shows "No app can open this link" only for a typed address and is silent for page links. The typed path is currently unreachable (see Carried), so there is nothing to check by hand for it. Cost if wrong: a page link to an unknown scheme does nothing visible.
- **R9:** TLS errors (-1201 to -1206) and secure-connection failures set the insecure state; -999 and WebKit 102 set nothing; a combined camera and microphone request skips asking only when both stored answers are Allow, and any Deny denies. Cost if wrong: an extra prompt or a denied combined request.
- **R10:** pop-ups adopt the opener's content controller, so they share the opener's rule lists; documented, no copy workaround. Cost if wrong: toggling blocking on a pop-up also changes its opener's lists.
- **R11:** `<a download href="data:…">` becomes a download even though `data:` main frames are refused. Cost if wrong: a page can push a sanitised, quarantined `data:` file into `~/Downloads`.
- **R12:** page prompts resolve false or nil when their tab or window closes, and `window.open` runs the navigation policy on its URL before a tab is stored. Cost if wrong: a `window.open` to an odd scheme opens nothing.
- **R13:** JS panels show the origin host, cap page text at about 1,000 characters, and after three panels in a short window offer to suppress more until the page navigates; a download with no owner fails rather than inventing a profile. Cost if wrong: an extra checkbox on the third dialog.
- **R14:** an opener with open pop-ups is not hibernated (instead of closing a sign-in pop-up mid-flow). Cost if wrong: a few extra live pages while pop-ups are open.
- **R15:** dialogs from a background tab resolve at once (alert dismissed, confirm false, prompt nil); queueing until the tab is shown is carried forward. Cost if wrong: a timer `confirm()` in a background tab gets false.
- **R16:** private pages, and links and pop-ups from them, stay in their private window; a hibernated private page reloads from its model URL without history. Cost if wrong: a re-shown private tab loses its back/forward history.
- **R17:** closing a private window cancels its running downloads (finished files stay) and clears its snapshots and in-memory media answers. Cost if wrong: a large private download is lost when its window closes.
- **R18:** the final whole-branch review and its fix wave ran before this task, so this Outcome describes the final code. Cost if wrong: none beyond ordering.
- **R19:** the final fix wave took the critical (an unmarked download on failure; quarantine now starts with the first byte and names the real source), the six important items (external-app question names the site and shows on its own window; pop-up title leads with the host; closing a window frees its pages, so a camera page goes dark; snapshot memory is bounded; a hung snapshot no longer pins an unloaded page; several downloads from one document ask once) and three minors. Title-write coalescing and the decision 5 plan text were left. Cost if wrong: extra sidebar reloads on pages that flip their title.

Decision 1 was settled by Nico on 2026-11-03: **ITP stays on** (no sign-in looped in the walkthrough). Still flagged for Nico: **decision 9** (`https://user@host` links open as other browsers do, with the address field showing only the real host; Nico may prefer to refuse them).

By-hand run, Step 2 (DRM and YouTube): the unsigned Debug build reached the network this time. `https://bitmovin.com/demos/drm` loaded and rendered the "DRM Stream Test" page, but a marketing overlay and then a cookie consent panel sat over the player, and clearing them needs a pointer click that this session did not send. So playback, fullscreen and Picture in Picture were **not exercised**, and a DRM stream was never played. YouTube was not tried. Both move to the Nico checks. (Screenshots stayed in the session scratchpad.)

Nico checks (not seen by the build sessions):

Walkthrough, first pass (2026-11-01, unattended session): the Debug app was built signed with Nico's Apple Development identity (team passed on the `xcodebuild` command line only: `CODE_SIGN_STYLE=Manual CODE_SIGN_IDENTITY=<Apple Development SHA-1> DEVELOPMENT_TEAM=<team>`; bundle ID stays `com.nicojan.Stave.debug`; nothing committed) and run on `/private/tmp/stave-nico-checks`. Little Snitch held every internet connection at an alert ("Stave has been modified", because the signature changed), so this pass used local pages served from `127.0.0.1:8765` and keyboard, accessibility and in-window pointer events only. Items marked "not run" still need Nico.

Walkthrough, second pass (2026-11-02, with Nico): same signed build at the same path (`build/DD`, binary unchanged), after Nico allowed the Downloads-folder prompt and accepted the modified binary in Little Snitch. Paused after the double-download check, then finished on 2026-11-03 with the same binary (relaunched; no code change since `464a795`). Nico did all clicking and signing in; no screenshots were taken of signed-in pages by the session.

- [x] Sign in at Google, then open Google Docs and edit a document. *Not run (account, network).* **Second pass: pass.** Sign-in finished with no "browser may not be secure" refusal or loop; Docs opened, typing showed and saved; still signed in after reload.
- [x] Sign in at Microsoft; watch for an SSO redirect loop (decision 1, ITP on). *Not run.* **Second pass: pass.** No SSO loop; a new Office tab picked up the sign-in and kept it after reload. (Account type, work or personal, not stated.)
- [x] Sign in with Apple. *Not run.* **Second pass: pass** at appleid.apple.com.
- [x] An Okta-style SSO sign-in that uses a pop-up window; the pop-up title should lead with the host. *Not run; the local pop-up check below passed.* **Second pass: pass** with Figma → "Continue with Google": a separate small pop-up titled "accounts.google.com — Sign in - Google Accounts", which closed by itself and left Figma signed in. Observation: the account chooser listed the Google account as "Signed out" although Google had been signed into earlier; not yet known whether the Figma tab was in another workspace/profile or the pop-up didn't see the session.
- [x] Sign in at GitHub. *Not run.* **Second pass: pass**, including the settings page in a new tab and a reload.
- [ ] Google Meet with camera and microphone: the macOS prompt (first use only), then Stave's sheet, then "Remember for this site" honoured on reload. *Not run. On a local `getUserMedia` page, WebKit asked macOS first (`TCCAccessRequest` in the log) and Stave's sheet never appeared. The macOS camera prompt was probably queued behind the pending Downloads-folder prompt. Recheck once that prompt is answered; the expected order (Stave's sheet first) may be wrong.* **Second pass: partial fail.** Meet video, mic meter and the camera light going off on leaving all pass. **Fail:** the sheet ("Allow “meet.google.com” to use your camera and microphone?") has only Don't Allow and Allow, with no "Remember for this site" (decision 11 says it is on by default), and no answer is ever stored: `siteSetting` stayed empty after both `cam.html` and Meet, so every reload asks again. Order of Stave's sheet vs the macOS prompt on `cam.html` not confirmed.
- [ ] DRM playback on `https://bitmovin.com/demos/drm` (dismiss the overlays by hand), YouTube playback with fullscreen and Picture in Picture. *Not run (network).* **Second pass:** YouTube playback, fullscreen (Esc returns intact) and Picture in Picture **pass**; Bitmovin overlays dismissed. DRM **not confirmed**: the demo detects FairPlay but spins forever, and it does the same in Safari, so the demo page is the likely cause; try another FairPlay stream later.
- [ ] Debug ▸ Crash Page Process on a signed build (the unsigned build was refused by libxpc): the crash panel shows, and Reload recovers. **Fail (menu item):** also refused on the Apple Development-signed build (`Could not signal service com.apple.WebKit.WebContent: 1: Operation not permitted`), so nothing happens. Crash panel and Reload **pass** when the page's WebContent process is ended from the terminal (`kill -9 <pid>`). The panel reads "This page stopped working / Reload the tab to try again." and Reload brings the page back. AX note: the subtitle appears twice in the accessibility tree.
- [x] Downloads on a signed build: the popover (Cancel, Show in Finder, Clear), `xattr -p com.apple.quarantine ~/Downloads/<file>` while a slow download is still running, and whether the first download freezes the UI (the unsigned build hung on the Downloads-folder privacy prompt). **Fail:** the first download freezes the whole app. `sample` shows the main thread blocked in `PageDelegate.download(_:decideDestinationUsing:)` → WebKit `SandboxExtension::createHandle` → `sandbox_extension_issue` for the `~/Downloads` path while macOS shows "“Stave.app” would like to access files in your Downloads folder." Stave stays hung until the prompt is answered. Reproduced twice (once from a private window). The popover, quarantine attribute and Clear were not reached. **Second pass: pass.** With the Downloads prompt answered, the first download no longer freezes the app. The partial file carries `com.apple.quarantine` at about 1 MB of 7.8 MB, and the finished file keeps it; the popover shows progress and Cancel; Cancel stops the download and deletes the partial; Clear removes only finished rows and leaves the file on disk. The freeze is still a failure for a first-ever download (see the failures list). Minor fails: the quarantine event records agent Stave / `com.nicojan.Stave.debug` but empty data and origin URLs, so Gatekeeper can't name the source site; the popover hangs below the window's bottom edge, and its material splits at the sidebar edge (dark over the sidebar, light over the page), with a drawing glitch over the lower row. Show in Finder not confirmed. (Still not confirmed after the 2026-11-03 session; asked twice, unanswered.)
- [x] A private download end to end; closing that private window cancels it; and a real example.com page in a private window. *Not reached (download freeze; network). A private window loads a local page, and no private window comes back after relaunch.* **Second pass: pass.** The popover showed the slow download in the private window; closing the window mid-download didn't hang, the server saw the connection cut (`BrokenPipeError`), and no partial was left in Downloads; example.com loaded in a private window. **New fail (found at relaunch):** a restored `double.html` tab re-ran its script at launch and saved `small1.txt` with no click (12:39:59), then asked the several-files question for `small2.txt`. A restored tab can download without a user action.
- [x] example.com over the real network (the earlier by-hand runs used localhost because the unsigned Debug build was blocked, likely Little Snitch). *Blocked by the Little Snitch alert; needs Nico to accept the modified binary.* **Second pass: pass** once the modified binary was accepted.
- [x] Compact mode: Tab past a page's last field currently reveals the sidebar (product choice: keep or change). *Seen: Tab from the last field reveals the sidebar with focus in the tab list. **Decided 2026-11-03: keep it** (keyboard and VoiceOver reach the sidebar without a pointer). Also seen: in compact mode the traffic lights overlap the page's top-left content.*
- [x] The one ⌘Q that didn't quit after the failed crash attempt (not reproduced). *After a refused Crash Page Process, a crash and Reload, ⌘Q quit within 4 s.*
- [x] Camera and microphone sheet in a window, then close that window with another open: the camera light goes off and the tab reloads when shown again. *Not reached (camera prompt pending, see Meet).* **Second pass: pass.** The camera light went off about 5 s after the window closed; showing the tab again reloaded it and the sheet asked again.
- [ ] Click a `mailto:` link: the sheet reads "Allow ‹site› to open this link in Mail?" and shows only on that site's window; switching tabs closes it and clicking again asks again. **Partial fail.** The text is right ("Allow localhost to open this link in Mail?" with the address below), it shows only on the clicking window, and after Cancel a second click asks again. But the sheet is window-modal, so tabs can't be switched in that window while it's up. When a second window takes the page ("Bring It Here"), the first window keeps the sheet up for a page it no longer shows, and its Open button still works.
- [x] A page that downloads twice by script: the first saves, the second asks "wants to download several files". *Not reached (download freeze).* **Second pass: pass.** The sheet asked; after Allow both `small1.txt` and `small2.txt` saved, each quarantined.
- [x] An OAuth-style pop-up: the title reads "‹host› — ‹title›" and follows redirects to other hosts. *Local chain `localhost` → 302 → `localhost` → 302 → `127.0.0.1`: the pop-up window title ended as "127.0.0.1 — Landing".*
- [x] A live VoiceOver pass over the downloads popover and every prompt sheet (external app, JS panels, camera and microphone, several downloads). *Live VoiceOver not run. AX tree read: JS alert, confirm and prompt sheets read "localhost says" plus the text, the prompt field is labelled with its question, and the external-app sheet reads as above. After three dialogs in 10 s the "Don't show more dialogs from this page" box appears, and ticking it stops the next dialog (R13).* **Second pass: pass (Nico listening).** The session couldn't read VoiceOver (its AppleScript bridge returned -1728 or hung with the setting on), so Nico listened to VoiceOver on the alert, confirm and prompt sheets, the mail sheet, the camera sheet, the several-downloads sheet and the downloads popover, and reported all read correctly.
- [x] Pointer-driven steps from Tasks 9–11 that were driven by keyboard only: right-click and menu items on pages, ⌘-click and ⇧⌘-click links, the downloads button and popover, the cookie and consent style overlays on real sites. *Partly seen. ⌘-click opens a background tab below the opener, and ⇧⌘-click opens and selects one there. Right-click on a link shows WebKit's default menu (Open Link, Open Link in New Window, Download Linked File, Copy Link, Share…, Services), with no "Open Link in New Tab". Downloads button, popover and real-site overlays not reached.* **Second pass: pass.** Right-click on text, an image and a link each showed a page menu; the downloads button opened the popover by mouse and Cancel worked; real-site overlays (Bitmovin) dismissed by click. The missing "Open Link in New Tab" stays a failure.

Results of the walkthrough (2026-11-03, Nico): ITP stays on and compact-mode Tab keeps revealing the sidebar. **Fix before PR #4 merges** (Nico, all five; all fixed, see below): (1) the camera and microphone sheet has no "Remember for this site" box and no answer is stored (`04104c2`); (2) a tab restored at launch re-runs its page and downloads without a click (`767efec`); (3) the first-ever download freezes the app while the macOS Downloads-folder prompt is up (`2b343d4`, `d1cf1d6`); (4) no "Open Link in New Tab" in the link menu (`786a83f`); (5) the crash panel subtitle appears twice in the accessibility tree (`aebca47`). **Carried:** compact-mode traffic lights overlapping page content; downloads popover placement, split material and drawing glitch; empty quarantine source URLs; the window-modal and stale-after-"Bring It Here" mailto sheet (with R15); Debug ▸ Crash Page Process refused; DRM recheck on another FairPlay stream. **Unconfirmed:** Show in Finder selecting the file; the order of Stave's camera sheet vs the macOS prompt; why the Figma pop-up's Google chooser listed the account as "Signed out".

Fixes before merge (2026-11-03, unattended session): all five done, one commit each (fix 3 has a test-timing follow-up), in the order Nico gave; each had its root cause named first, a failing test before the change (except fix 5, see there), the full package suite and Debug and Release builds green, and a qa-reviewer pass whose findings were taken or written down below. There are 701 package tests (88 + 613); CI is green on macOS 14 and 15 on the last code commit `378c0b5` (run 41780190335). That commit is test-only: since the Nov 1 runner images, three page-host tests that checked state at fixed wall-clock points failed on most runs of this branch, docs-only commits included; the cause was reproduced locally with a 6 s main-thread stall and the tests now wait for the state they check.

- **(5) Crash subtitle twice in the AX tree: fixed in `aebca47`.** Cause: a SwiftUI `Text` with `.textSelection(.enabled)` exposes two `AXStaticText` elements (seen in a throwaway harness on macOS 27: plain text one, selectable text two). The detail now has `.accessibilityRepresentation { Text(detail) }`: one element for VoiceOver, still selectable on screen. No automated test: the view is in the app target, which has no test target, and CI has no Accessibility permission. The check is an AX dump of the signed Debug build with the panel up (WebContent process ended with `kill -9`): before, two "Reload the tab to try again." rows; after, one, with the title and Reload button still there, and Reload brings the page back.
- **(4) "Open Link in New Tab": fixed in `786a83f`.** Cause: pages were plain `WKWebView`s and Stave never edited WebKit's menu. Pages (and the linked tabs and pop-ups WebKit makes) are now a `PageWebView`, which puts "Open Link in New Tab" before WebKit's "Open Link in New Window". WebKit doesn't say which link the menu is for, so the item forwards WebKit's own new-window item (sent from WebKit's item, which WebKit reads) and records the choice; the delegate takes it once, within 2 s, only for WebKit's `.other` request, and opens the link through the navigation policy as a background tab the way ⌘-click does (a fresh page with its own content blocking; WebKit gets no view). By hand (AX `AXShowMenu` on a link in the signed Debug build): the item shows between Open Link and Open Link in New Window; choosing it opened "Alert check" in the background under the opener; Open Link in New Window still opens a selected tab.
- **(1) Camera sheet with no "Remember" box, nothing stored: fixed in `04104c2`.** Cause: the sheet Nico saw (host in curly quotes) was WebKit's own fallback prompt, not Stave's. Stave's method was an async method with the Objective-C selector's labels (`requestMediaCapturePermissionFor:initiatedByFrame:`), which matches no WebKit selector; the header's async name is `webView(_:decideMediaCapturePermissionsFor:initiatedBy:type:)`. WebKit never asked Stave, so Stave's sheet (which has the box) never showed and nothing was stored. Renamed; a new test checks that the delegate answers all 18 selectors WebKit calls (it failed before, naming the media one). The storage per profile and host, and in memory for private windows, was already there and tested. By hand: blocked. On `cam.html` the rebuilt Debug binary got macOS's own "Allow “Stave.app” to access your camera?" first (it seems to have lost the earlier grant); answering it is Nico's, so the session quit Stave and left it. That prompt coming first matches WebKit's order (corrected in decision 11 above).
- **(2) A restored tab downloads with no click: fixed in `767efec`.** Cause: a document's first download needed no user action, and a page Stave loads by itself (a tab restored at launch, or a stored tab shown again) is a fresh document, so its script's first download went through. Such a page now waits for the user: a click or key press in the page, Reload, Back or Forward, or a typed address. Until then its downloads are refused without a question, and the refused one counts as the document's first, so the next asks. A link opened in a new tab by ⌘-click or "Open Link in New Tab" may download at once, but only if the user has acted on its opener (a script can fake a ⌘-click). Checked in a harness: a page's own `location.reload()` and `history.back()` don't call the web view's `reload()`/`goBack()`, so a page can't clear the wait itself. By hand (signed Debug build, the stored tab pointed at a copy of `double.html` on a logging server in the scratchpad, title changed by the page after its two clicks): after relaunch the page showed "Clicked both links", nothing was saved to `~/Downloads` and no sheet came up. On one relaunch (restored from `interactionState`) the server saw the two files requested twice each, still with nothing saved: WebKit fetches before it asks Stave for a destination. Second by-hand pass (accessibility only, Stave kept in the background so another session's Chorus window kept focus): typing `http://127.0.0.1:8765/double.html` into the command bar (AX value + `AXConfirm`) saved `small1 (2).txt`, quarantined, then asked "127.0.0.1 wants to download several files" (answered Don't Allow, nothing more saved). After a relaunch the restored page saved nothing and asked nothing; ending its WebContent process and pressing the crash panel's Reload (a user command) let it save `small1 (3).txt` and ask again. The downloads popover listed the row with "Show small1 (3).txt in Finder" and "Clear finished downloads". View ▸ Reload Page is disabled while Stave isn't the active app, so the menu path wasn't used.
- **(3) The first download freezes the app at the Downloads-folder prompt: fixed in `2b343d4`, test timing fixed in `d1cf1d6`.** (The rebuilt Debug binary still has the Downloads grant: the session's downloads above saved with no macOS prompt, so the prompt can't come up here by itself.) Cause (from the `sample` trace): the async `download(_:decideDestinationUsing:)` returned the `~/Downloads` path to WebKit's completion handler, which runs on the main thread in that frame and makes the folder's sandbox extension (`SandboxExtension::createHandle` → `sandbox_extension_issue`); that was the process's first touch of the folder, so macOS's privacy check ran there and blocked the main thread until the prompt was answered. Stave now opens the folder first (`opendir` + one `readdir`, every download, no cache) on its own queue, shared by downloads that arrive meanwhile, and gives WebKit a path only after that returns. A refused folder (EPERM) fails the row with "Allow Downloads for Stave in Privacy & Security ▸ Files and Folders."; any other folder problem says "Stave can’t open your Downloads folder."; the prompt has a purpose string (`NSDownloadsFolderUsageDescription`). Tests use a blocking stand-in for the prompt and show the check runs off the main thread while the main actor keeps going. **Not seen end to end:** that `opendir` makes macOS ask (as `ls ~/Downloads` does for Terminal) and that WebKit's sandbox extension then returns at once both need the prompt shown again, which is Nico's call; Chorus was in front (another session was using it) whenever the session could have tried it, so it wasn't.

By-hand checks for Nico after these fixes (signed Debug build from `build/DD`, `-StaveArcHome` to a throwaway folder):

- [x] Camera (fix 1): answer macOS's camera (and microphone) prompt for the rebuilt Debug binary if it is still up or comes back. Then on `http://127.0.0.1:8765/cam.html`: Stave's sheet "Allow 127.0.0.1 to use your camera and microphone?" with "Remember for this site" ticked. Allow, then `sqlite3 -readonly <data>/stave.sqlite "select host, key, decision from siteSetting"` shows camera and microphone rows; reload: no sheet, the camera comes on. Same on Google Meet. In a private window: answer, reload (no sheet), nothing new in `siteSetting`, close the window, a new private window asks again. **Session, 2026-11-04 (after a restart, fresh `/private/tmp/stave-nico-checks`, accessibility only): pass for `cam.html`.** No macOS camera prompt (the Debug binary still had the grant); Stave's sheet read "Allow 127.0.0.1 to use your camera and microphone?" with "Remember for this site" ticked, Don't Allow and Allow. After Allow the page showed live video and `siteSetting` held `127.0.0.1|camera|allow` and `127.0.0.1|microphone|allow`; loading the page again (typed address, not ⌘R) showed no sheet and the camera came on. Meet and the private-window half are still Nico's. **Nico, 2026-11-09 (signed Debug build on ChorusEngine 1.5.36):** pass for the private-window half (on `localhost`: Allow with Remember ticked turned the camera on, ⌘R showed no sheet, a new private window after closing the last asked again, `siteSetting` gained no row) and for Remember storing Allow on `127.0.0.1`. Google Meet not tried.
- [x] Downloads prompt (fix 3): with the Debug binary not yet allowed the Downloads folder (the rebuilt binary may ask by itself; otherwise `tccutil reset SystemPolicyDownloadsFolder com.nicojan.Stave.debug` resets only the Debug app, your call), start a download: while macOS asks, Stave stays usable (switch tabs, type in the address field), and the prompt shows "Stave saves the files you download in your Downloads folder." Allow: the download finishes. In a second try with Don't Allow (or after turning it off in System Settings): the row reads "Failed: Allow Downloads for Stave in Privacy & Security ▸ Files and Folders." and fits in the popover. **Session, 2026-11-04: still not seen.** A slow download typed into the command bar saved to `~/Downloads` at once, quarantined, with no macOS question: the Debug binary still has the Downloads grant, so the prompt can only come back after Nico resets it. **Nico, 2026-11-09 (signed Debug build on ChorusEngine 1.5.36):** pass. After Nico reset the grant himself, `slow.txt` brought up macOS's prompt with the purpose string; while it was up (left about 10 s) an accessibility probe got Stave's window title every half second in 0.31–0.60 s, from the click through the prompt and the 30 s download, so the main thread never stalled; Allow saved all 30 lines, quarantined. The Don't Allow half (the failure row's wording) was not tried.
- [x] Restored tab (fix 2): the session saw both halves through accessibility (nothing on relaunch; after a typed address or the crash panel's Reload, the first file saves and the second asks). Left for Nico: a real mouse click in a restored page, then ⌘R, does the same; with VoiceOver, press Tab into the page first (a VoiceOver activation alone doesn't count as acting on the page, see Carried). **Nico, 2026-11-09 (signed Debug build on ChorusEngine 1.5.36):** pass with a real click: after a quit and relaunch the reopened `double.html` asked "127.0.0.1 wants to download a file" (the behaviour from Nico's 2026-11-04 answer) when its tab was shown, and Don't Allow saved nothing; a click in the page and ⌘R saved the first file without asking and asked about the second (Don't Allow, not saved). The VoiceOver Tab variant was not tried.
- [x] Link menu (fix 4) with the mouse: right-click a real link, Open Link in New Tab: a background tab below the opener with the right address. **Nico, 2026-11-09 (signed Debug build on ChorusEngine 1.5.36):** pass: Open Link in New Tab sits above Open Link in New Window and opened the link as a background tab below the opener.
- [x] VoiceOver (fix 5): on the crash panel (`kill -9` the page's WebContent process), VoiceOver reads "Reload the tab to try again." once. **Nico, 2026-11-09 (signed Debug build on ChorusEngine 1.5.36):** pass: the page processes ended with `kill -9`, the panel read "Reload the tab to try again." once, and Reload brought the page back.

Questions for Nico from the reviews (behaviour unchanged, not decided by the session):

- Now that Stave's camera sheet really answers, a remembered **Don't Allow** (Remember is ticked by default) is permanent: nothing in the app shows or clears a site's camera or microphone answer. Remember only Allow by default, add a way to clear it, or keep it?
- A camera question that can't be shown (another sheet up, the tab not shown, or the user switches tabs while it is up) denies at once and remembers nothing, but WebKit keeps that deny for the page until a click or reload, so a page that retries by itself gets no sheet. Hold the question until the tab is shown instead?
- A reopened page's downloads are refused silently until the user acts on it. Ask instead ("‹host› wants to download a file") while the tab is shown? That would also cover VoiceOver and Voice Control activations, which don't count as acting on the page.
- "Open Link in New Window" opens a selected tab, not a window (unchanged); next to the new item the label reads wrong.

Nico's answers (2026-11-04): anything Stave shares with other browsers acts the way Chrome, Safari and Firefox do (now an anti-goal in the design spec). All four go in on this branch before PR #4 merges:

- **Remembered Don't Allow:** all three browsers can remember a block and let you see and clear it from the address bar (Chrome's site settings and Reset permissions, Firefox's permissions panel, Safari's Websites ▸ Camera). Stave has no such place yet, so for now Remember keeps only Allow; a Don't Allow is never stored. A per-site camera and microphone panel reached from the address button is for a later plan, and Remember can keep Don't Allow once it exists.
- **A camera question that can't be shown:** held until the tab is shown and no other sheet is up, as Chrome and Firefox do, instead of denied.
- **A reopened page's downloads:** asked ("‹host› wants to download a file"), as Safari asks per site, instead of refused silently.
- **Open Link in New Window:** opens a real new window, as every browser does, on the opener tab's workspace, with the link selected there.

Later the same day Nico also approved, again to match Chrome: downloads that arrive while a download question is up wait for its answer (they had been refused with no question), and the private windows of a profile share one session (decision 15, revised above; Safari keeps private tabs apart, Chrome and Firefox share).

Built after the answers (2026-11-04, builder agent, two qa-reviewer passes):

- `e05e019` Remember keeps only Allow. `a56b8e6` a camera question that can't be shown waits. `8619d34` a reopened page asks "‹host› wants to download a file". `90daf65` Open Link in New Window opens a window.
- First review: two must-fixes in `a56b8e6`. (A) A waiting question outlived its page (hibernation, same-tab navigation, crash and reload), and Allow with Remember could store an allow for the old host. (B) Per-window queues could strand a question for a tab shown in another window. Fixed in `7d8fa7d`: each question is tied to the asking page and its commit count, is dropped on unload, close or a main-frame commit (as Chrome does), and is shown in whichever window shows the tab (one app-wide `MediaQuestionCenter`). `mediaDecision` grants or remembers only if the page is unchanged after the await. A sheet sent back because its tab was hidden is marked by a flag, not the `.cancel` code `quit()` uses. `84d6fd2` takes the new window's workspace from the opener tab's stored record and falls back to a tab rather than dropping the link. `aaa6383` makes a Don't Allow on a reopened page's download stick until the user acts.
- `5f5c053` downloads wait behind a download question and follow its answer; after a first-download Allow, the waiting ones get one "several files" question; after a Don't Allow they are refused; a navigation or close refuses them.
- `386466c` private windows of a profile share one non-persistent store and in-memory camera answers while any is open; ⇧⌘N takes the key private window's profile, else the front browser window's, else the default.
- Second review (of `7d8fa7d`..`386466c`): nothing must-fix; four should-fixes, fixed. `180fe42`: on a main-frame commit the tab's download sheets come down too (a leftover sheet had made the new page's later downloads fail silently); a question that couldn't be asked (`QuestionAnswer.unasked`) is never recorded as Don't Allow; the hand-off after a first-download Allow refuses if the page changed meanwhile; a camera question is denied unless the page's current top site is the asking site, checked on entry and after the answer (closes a gap where a page asking while navigating to another site could get its own host remembered over the new site). `39d8dfc`: ⇧⌘N from a key pop-up uses its opener's profile. `ab0d06f`: a private session's store is asked for only while the session is joined (debug assertion), and leaving the last window drops its in-memory answers through `forgetPrivate`.
- Package tests 742 (114 + 628), Debug (signed) and Release builds green locally on Swift 6.4.2; pushed `db29b0f..ab0d06f`; CI green on macOS 14 and 15 (Swift 6.0.3) for `ab0d06f` (run 41911120693).

By the session in the rebuilt signed Debug app (accessibility only, no pointer or keys): on `localhost/cam.html`, switching tabs while the camera sheet was up took it down and it came back on returning; Don't Allow with Remember ticked stored nothing and the next load asked again. A relaunched `double.html` asked "127.0.0.1 wants to download a file" and saved nothing until Allow; then its waiting second file got the "several files" question and Allow saved `small2.txt`, quarantined. Open Link in New Window opened a second window with the link; Open Link in New Tab still opens a background tab. A cookie set in a private window was seen by a second private window opened with Open Link in New Window; after both closed, a new private window had none, and a normal window never saw it.

By-hand checks for Nico after the answers:

- [x] A camera question in a background tab: open a page that asks for the camera with ⌘-click, stay on the opener, then switch to the new tab: Stave's sheet appears then, not before. Also with the tab moved to another window first. **Nico, 2026-11-09 (signed Debug build on ChorusEngine 1.5.36):** pass for the same window (no sheet until the tab was shown). The moved-to-another-window variant was not reported.
- [x] Open Link in New Window from a pop-up, and from a tab in a second workspace: the window opens on that tab's workspace. **Nico, 2026-11-09 (signed Debug build on ChorusEngine 1.5.36):** pass for both, on the briefcase workspace.
- [x] Private windows: sign in to a real site in one private window, open a second private window (⇧⌘N): still signed in; close both, open one: signed out. Check the profile it uses when the front window is on a non-default profile. **Nico, 2026-11-09 (signed Debug build on ChorusEngine 1.5.36):** pass (signed in on a real site, still signed in in a second private window, signed out after closing both). The non-default-profile half was not tried. **Claude, 2026-11-10 (accessibility only, merged Debug build `6b187db`, throwaway data, local cookie page):** pass. With the front browser window on a second profile ("Second"), ⇧⌘N opened a private window that set a cookie; with the window switched to the default profile ("Personal"), a new private window did not see it; switched back to "Second", a third private window did. So a private window takes the front browser window's profile, and the private windows of one profile share their session while those of another don't.
- [x] Quit with a camera sheet up: no sheet comes back, and Stave quits. **Nico, 2026-11-09 (signed Debug build on ChorusEngine 1.5.36):** pass (Stave quit with the sheet up on `localhost`; nothing was stored).

Also on this branch, from reading Zen 1.24b's behaviour (2026-11-04 evening; notes in `docs/research/2026-11-04-zen-internals.md`): `742e483` a pinned tab whose address changes only after `#` is not drifted (`Tab.isSamePage`, also used for pinned-icon adoption and the archive-on-unpin checks); `66e592e` the Arc import places an item that names its parent but is in no `childrenIds` list at the end of that folder or space and reports the count, and reports `childrenIds` entries that name no item; `875ea93` the notes, and the spec's drift rule and passkey open check. Package tests 751 (114 + 637), Debug build green locally.

- [x] Close a window whose live page is shown in another window: the page keeps its back/forward history (Zen admits losing it here). **Nico, 2026-11-09 (signed Debug build on ChorusEngine 1.5.36):** pass: Back and Forward still worked in the remaining window.

Engine move (2026-11-09, one commit and one green CI run per step): `6fad402` raises the minimum to macOS 15 (package platform, `project.yml`, generated project); `07907df` moves CI to macos-15 and macos-26 with the newest stable Xcode (26.3 and 26.6 on the runners), since GitHub retired macos-14 on 2026-11-02; `e0ae533` drops the GRDB cap (`from: "7.0.0"`, resolves 7.12.0); `22d90cc` pins ChorusEngine `exact: "1.5.36"`. Stave needed no code change: it never called the removed memory watch (`memoryReadings(now:)`, `MemoryReading`, `wouldRebuild`), it doesn't use `UserScriptManager`, so the 1.5.33 storage events don't reach it, and it passes no `parking` (see Carried). Package tests 751 (114 + 637), Debug and Release builds green locally on Xcode 27.2. The constraints above that say macOS 14, Swift 6.0.3 or Xcode 16.2 describe the plan as it was built; they no longer apply.

## Carried into later plans

- **Engine parking (from the 1.5.36 move):** WebKit suspends a page that is out of a window within seconds, and a page caught mid-write can lose IndexedDB data (Chorus measured this). ChorusEngine 1.5.35 added `WebViewParking` to keep chosen pages running off screen, but an instance comes only from the engine's `WebViewPool`, and which pages it keeps is internal. Stave has its own pool, so its background tabs are suspended as before. Using parking needs a public way to make one and choose the pages, which is a Chorus change and a new tag.
- **From reading Zen (2026-11-04):** compact mode in Zen hides only the sidebar by default (toolbar stays); Stave hides both, so Nico decides whether to keep that. A rolling timed copy of the database (Zen keeps up to 20 timed session backups) guards against Stave's own bug writing bad data; candidate for plan 5, not built. **Answered 2026-11-09:** compact mode hides only the sidebar, like Zen; the toolbar stays. Built 2026-11-10 on PR #3 (`a87bc94`, merged here in `6b187db`): Stave has no toolbar, so in compact mode the window keeps its title bar as a bar of its own and the page starts below it, which also ends the traffic lights overlapping the page (seen 2026-11-03). Details and new Nico checks in plan 4's Outcome, "Compact mode, sidebar only". Rolling backups: Nico asked for a recommendation; recommended yes for plan 5, kept small (GRDB's online `backup(to:)`, a copy at launch and hourly, keeping about 10 hourly and 3 daily), because the archive guards only against the user's own deletions, not against a Stave bug writing bad rows. Nico confirms when plan 5 is written.
- **From Nico's answers (2026-11-04):**
  - A per-site camera and microphone panel reached from the address button (Chrome's site settings, Safari's "Settings for This Website"); once it exists, Remember may keep Don't Allow again.
  - App-only code with no automated test: `MediaQuestionCenter`'s window choice, sending a sheet back and showing it again, the download-sheet takedown on commit, the `unasked` mapping in `PagePrompts`, `AppDelegate.openWindow(forLink:)` and its fallbacks, the ⇧⌘N profile choice. Seen by hand only as listed above.
  - A camera question for a tab whose window closed while its page stays live (a page playing media isn't hibernated) waits until the tab is shown somewhere.
  - After an Allow on a reopened page's first-download question, a page that keeps reloading itself is asked again on each load (the Allow isn't kept).
  - Download rows of private windows are still per window, though the session is shared.
  - `handoffAfterAFirstDownloadAllowChecksThePageStillMatches` relies on the main actor running queued tasks in order.

- **From the five fixes before merge (2026-11-03):**
  - Camera and microphone: the questions for Nico above (permanent remembered deny with no way to clear it; a question that can't be shown denies and WebKit keeps the deny). The answer is keyed by host only, so one Allow on `localhost:8000` covers every local port. An embedded frame is asked about and remembered under the top page's host (as Chrome does), unlike JavaScript dialogs, which name the frame.
  - Reopened pages: a VoiceOver, Voice Control or Full Keyboard Access activation, a ⌘-key shortcut and the first click into an inactive window don't count as the user acting on the page; Back to Pinned Page, restoring from the archive and an address typed for a tab shown in another window make pages that wait too (safe direction, but the user did ask). Every new way for the user to open a page (default-browser opening later) must set `PageRequest.openedByUser`. The content-blocking toggle's reload counts as acting on the page, on purpose.
  - Downloads folder: if the window closes while macOS's folder question is up, the download is dropped with no row; if only the tab closes, it goes ahead. After Don't Allow, a page's later downloads still ask "several files" first, then fail on the folder. Untested against the real prompt (see fix 3).
  - Link menu: the menu choice is matched to WebKit's request by time (2 s) and type, not by URL; a page `window.open` arriving first in that window could swap places with the link (tab vs tab, nothing lost).
  - Fix 5 has no automated test (no app test target); an app test target would also cover the app-side wiring of `openedByUser`.
  - `DelegateSelectorTests` lists the WebKit selectors by hand: a new delegate method must be added there.
  - CI: the three flaky page-host tests are fixed in `378c0b5` (the wait helper yields once before its last look). Other tests that sleep a fixed time and then check WebKit state may flake the same way on a loaded runner.
- **Downloads (plan 5 or a hardening pass):**
  - A complete download is deleted if the finish-time re-mark throws after a successful first mark; check for an existing quarantine before deleting.
  - `failed` doesn't claim an unclaimed file, so a narrow KVO-hop window can leave an unmarked partial.
  - Same-name concurrent downloads can collide (unique name is check-then-use); a name can start with a combining mark; a multi-dot extension such as `a.tar (2).gz` is renamed oddly; `isControl` misses a few invisible code points (U+061C, U+2028, U+2029, U+200B–U+200D, U+2060, U+FEFF); progress NaN is unguarded.
  - Address-bar-started downloads count toward the several-downloads gate; a question that can't be asked refuses further downloads until the page navigates (accepted).
  - The partial-delete KVO-to-claim path is untested; the `claimDownloadFile` test seam is in production code; main-thread `fileExists` in `~/Downloads`.
- **Prompts and dialogs:**
  - R15: background-tab dialogs resolve at once; queue them until the tab is shown.
  - The external-app heading names the top page, not the frame that clicked (`NavigationRequest` has no source frame); dialog headings show the host only, no scheme or port.
  - Stale dialog-gate entries remain until forgotten; the gate counts unseen dialogs.
  - Hibernation unload doesn't forget prompts in either window kind; `hibernateIdle` snapshots `hasOpenPopups` before awaiting the media checks (narrow race).
- **Pages, hibernation and snapshots:**
  - R10: pop-ups share the opener's content controller, so per-site blocking on a pop-up also changes its opener's lists; adopted pages' `isContentBlockingOn` and request store can disagree.
  - Snapshot LRU can evict a snapshot of an owned tab that is shown elsewhere (needs 24 newer snapshots); elsewhere snapshots are polled on timers.
  - Title-only writes are uncoalesced (a title-flipping page reloads the sidebar often); `tabDeselected` flushes everything on every deselect; the menu snapshot is recomputed on every progress tick.
  - After a refused-restore hold, the first allowed navigation doesn't call `updateNavigationState`; the hibernation loop exits up to 60 s after the last page closes.
  - Same-address cross-window reset has code but no by-hand run or test; `tabClosed` or `tabUnloaded` from another window's view reconcile path is unconfirmed.
- **Navigation:**
  - Decision 5's typed external scheme is unreachable: `AddressInput` turns a typed `mailto:x` into a search, so `.typed` never reaches `askToOpenExternally` or the "No app can open this link" panel. Fix decision 5's text or the path in a later plan.
  - Content-blocking lists swap at decide time even if the navigation then becomes a download or fails.
- **Windows and routing:**
  - A linked tab from a container tab gets the opener's store; the opener's container is assumed to be in the workspace's profile; an adopted `dataStoreID` throw leaves a stored row with no page; the router doc promises a frontmost-window fallback that returns nil.
  - Typing for a tab shown elsewhere navigates the other window's page and `focusPage` gives up silently; `PageArea` stays blank if `request(for:)` fails.
  - `AppDelegate` is about 490 lines (move private-window routing to an extension); the private window has no drag reorder, compact mode or resizable sidebar; its search-engine pick is per window; a no-op New Tab on a private blank placeholder; private settings are read once at open.
  - `deleteWorkspace` and `reload()` read archived IDs and tab existence with `try?`, so a read failure reports nothing; no pinned-in-folder `deleteWorkspace` test; `tabDeselected` ordering and the host tolerating `tabClosed` then `tabDeselected` are undocumented.
- **Strings and small tidy-ups:** literal strings left in views ("Loading", "n percent", "No tab selected"); the content-blocking menu is enabled on `about:blank` and its rule lives in the app, not StaveCore; `SiteHost` keeps IPv6 brackets and does no IDN punycode; `UserAgent` accepts "." versions; the media-question default branch hides `(false, false)`; `DownloadOwner` fallbacks; `trackDownload` and `commitCount` visibility; the `StaveWebTests` dependency on StaveCore is unused.
- **Missing tests:** the unique `(profileID, host, key)` index, a v3-has-no-table migration control, `MAILTO:`, `ABOUT:BLANK` and typed `data:`, quarantine source URL, crash-to-commit, rule-list attachment and reattachment, the gate detaching after an allowed restore, flush resetting the throttle clock, same-state commit, the idle plus overflow union, dialog-gate and media-default identity (app target), the EngineLinkTests 60 s timeout task never cancelled, and `#expect(ready)` with no failure message.
- **Plan 5 and other plans' items still open:** web notifications (needs the engine change 1 below), location permission, history recording and favicon images in the sidebar, find, zoom, print, Web Inspector, HTTP auth prompts, default-browser registration, passkeys, and profile and container deletion UI, as the Scope section listed.
- **Engine changes Stave would use later** (requests to Chorus, none needed for the beta): the five listed at the end of the Tasks section above (notification bridge on any `WKUserContentController`; public `DownloadCenter.begin`, `setDestination` and `fail`; `WebSurface.DataStore.nonPersistent`; a logger subsystem parameter; an option on `DataStoreManager` to keep ITP on).
- **Housekeeping:** delete `.superpowers/sdd/2026-10-31-stave-web-layer/` (the execution ledger, briefs, reports and review diffs) when this plan's PR is merged or the branch is wrapped up.
- **Open questions for Nico:** whether to refuse `https://user@host` links (decision 9); whether a several-downloads question that can't be asked should refuse only that one download rather than the rest of the document.
