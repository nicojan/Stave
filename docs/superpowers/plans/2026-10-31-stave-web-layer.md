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
11. **Camera and microphone:** the first request from a host asks with a sheet ("Allow example.com to use your camera?", Allow / Don't Allow, plus "Remember for this site", on by default). A remembered answer is stored per profile and host. In a private window answers are kept in memory only. macOS's own TCC prompt follows the first Allow, as in every browser.
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
    - Each private window gets its own non-persistent store. The window is never saved or restored.
    - Closing it closes its pop-ups and drops its store and download rows.
16. **"Showing in another window"** shows the page's last snapshot, taken when its owner window last shows a different tab or the window resigns key. Snapshots are kept in memory only.
17. **Pages survive moves:** a tab moved between workspaces of one profile keeps its live page (the host is keyed by tab ID).

## Review Focus

1. **A stored URL with a hostile scheme** (an Arc-imported `javascript:alert(1)`, `file:///etc/hosts`, `data:text/html,x`, `arc://x`, or `chrome://settings`) is selected. It never loads, the content area shows "Stave won't open this address" with the text, and nothing is written. Tests: Task 2 `storedHostileSchemesRefused`, Task 6 `hostileStoredURLNeverLoads`.
2. **Stores are isolated.** A tab in profile B, a tab in a named container and a private-window tab each get a different store: profile B's `identifier` is its `dataStoreID`, and a private store has `isPersistent == false`. Two private windows never share one, and no page ever gets `WKWebsiteDataStore.default()`. Tests: Task 6 `storesFollowProfileContainerAndPrivate`, `twoPrivateWindowsNeverShare`.
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
  - **Media:** `requestMediaCapturePermissionFor` uses `SiteHost.normalized(origin.host)` and the stored decision, otherwise `askMedia`.
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
