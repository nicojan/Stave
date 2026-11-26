# Stave Release Implementation Plan (plan 5, Part B)

> **Where this came from:** Part B of `2026-11-10-stave-browser-basics.md`, moved here verbatim by that plan's Task 20 (question 1 of that plan). The text below is unchanged, so it still says "this plan" and refers to decisions, questions and tasks by their numbers in the browser basics plan (Part A's Outcome and "Carried into later plans" are there too, and this plan picks them up). Its branch is `feat/release`, from Part A's head (`feat/browser-basics`). Not started.

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

## Decisions 26–28 (from "Decisions" in the browser basics plan)

Release (Part B):

26. **Distribution copies Chorus's setup** (spec): a notarized, stapled DMG attached to a GitHub release tagged `vX.Y.Z`, a signed `docs/appcast.xml`, Sparkle 2.x in the app target, and a cask `stave.rb` in `nicojan/tap` (repo `nicojan/homebrew-tap`). Sparkle's update check sends no identifier, and Sparkle's system profiling stays off. The feed URL is `https://updates.nicojan.com/stave/appcast.xml` from the very first signed build, served by a Cloudflare Worker built like Chorus's: it passes through `docs/appcast.xml` from GitHub Pages and counts distinct machines per day with no install ID (as Chrome counts update checks). The Worker stores only a one-way hash of address, user agent and date with a secret salt, kept 48 hours, plus daily totals by version. Automatic update checks are on by default, with a Settings switch to turn them off. The README says plainly what a check sends (the app name and version in the User-Agent, and the Mac's IP address, which Cloudflare receives), what is stored and for how long, the free tier's ceiling of roughly 1,000 a day, and that counting never blocks an update. Updates also download in the background and install when Stave quits, on by default, with a second Settings switch (Nico, 2026-11-14), so turning off the download and install doesn't turn off checks. (question 25, answered 2026-11-13)
27. **The Sparkle feed URL chosen for the first public build is permanent.** Chorus learned that every build ever shipped asks its first feed forever. So Part B picks the final URL before the first signed build, never a temporary one.
28. **Signing and notarizing run from a local script, not CI.** No certificate or notary password goes into GitHub. CI keeps building Debug and Release unsigned.

## Questions 23–26 with their answers (from "Open questions for Nico" in the browser basics plan)

23. **A third bundle ID for betas** (foundation Carried: the `.debug` data-folder mapping). *Recommend:* no beta bundle ID; the beta is the normal `com.nicojan.Stave` app at a 0.x version, so the mapping and the passkey identity stay as they are. *Alternatives:* `com.nicojan.Stave.beta` with its own data folder (a separate identity for Apple's passkey and Passwords approvals).
    - **Answered 2026-11-13:** no beta bundle ID; the beta is `com.nicojan.Stave` at 0.x, as Safari (0.8) and Chrome (0.2) shipped their first public betas. A pre-release channel offered later next to a stable release would get `com.nicojan.Stave.beta` and `Application Support/Stave-beta`, as Chrome's side-by-side Beta does, and only then does the data-folder mapping change.
24. **The Sparkle signing key.** *Recommend:* a new EdDSA key for Stave, backed up like Chorus's, so a leak of one doesn't cover both apps. *Alternatives:* reuse the Chorus and WatchMeType key.
    - **Answered 2026-11-13:** a new EdDSA key for Stave alone, in its own Keychain account `stave`, backed up the way the existing key is. Every `generate_keys`, `sign_update` and `generate_appcast` run for Stave passes `--account stave`, because without it the tools quietly use the existing shared key (Tasks 21–23).
25. **The update feed and counting.** The spec's call: count anonymously, like Chorus, and say so. *Recommend:* `https://updates.nicojan.com/stave/appcast.xml` through the same Cloudflare Worker pattern from the very first build (decision 27), passing through `docs/appcast.xml` served by GitHub Pages; README states that daily checks are counted with no identifier. *Alternatives:* GitHub Pages only, no counting.
    - **Answered 2026-11-13:** the Worker feed URL with ID-free daily counting, as recommended (following Chrome; Firefox uses a per-profile ID). Automatic checks are on by default with a switch to turn them off; Sparkle's system profiling stays off; the README says what a check sends and what the Worker keeps (decision 26). Automatic download-and-install of updates is a separate decision the question didn't ask; Nico decided it on 2026-11-14: updates download in the background and install on quit, on by default, with a Settings switch (decision 26, Task 21).
26. **The first public version number.** *Recommend:* `0.1.0` labelled "beta" in the release notes and About box, with `CURRENT_PROJECT_VERSION` counting up for Sparkle. *Alternatives:* `0.9.0`; `1.0.0-beta.1`.
    - **Answered 2026-11-13:** `0.1.0`, labelled "beta" in the release notes and the About window; later betas go up through 0.x and the label goes away at 1.0.0, as Safari, Chrome and Firefox did. `CURRENT_PROJECT_VERSION` (`CFBundleVersion`) is a plain integer that goes up by one for every build given to anyone, because Sparkle compares it. `1.0.0-beta.1` is not a valid marketing version on Apple's platforms. The About label is built at run time from `CFBundleShortVersionString`, adding "beta" while the major version is 0, so no version number is typed by hand (Task 21).

## File structure entries tagged T21–T24 (from "File structure" in the browser basics plan)

The `Stave/Info.plist` line (T21 `SUFeedURL`, `SUPublicEDKey`) and the `THIRD_PARTY_NOTICES.md, README.md` line (T21, T24) are shared with Part A; they are copied here as written there. `Updater.swift` sits under `Stave/App/` and `VersionText.swift` under `Packages/StaveCore/Sources/StaveCore/`, as in the tree there.

```
├── Settings/VersionText.swift              # T21: About label from CFBundleShortVersionString (question 26)
├── Updater.swift                           # T21
Stave/Info.plist                            # T5 URL and document types; T17 location; T21 SUFeedURL, SUPublicEDKey
release/                                    # T22–T23: DISTRIBUTION.md, ExportOptions.plist, release.sh, homebrew/stave.rb
docs/appcast.xml                            # T22
THIRD_PARTY_NOTICES.md, README.md           # T1 (README backup and restore steps), T21, T24
```

# Part B: release

### Task 21: Version, update feed and Sparkle (questions 23–26, answered 2026-11-13)

**Files:**
- Create: `Stave/App/Updater.swift`, `Sources/StaveCore/Settings/VersionText.swift`; `Tests/StaveCoreTests/VersionTextTests.swift`
- Modify: `project.yml` (Sparkle 2.x from `https://github.com/sparkle-project/Sparkle`, app target only; `MARKETING_VERSION` stays `0.1.0` (already set); `CURRENT_PROJECT_VERSION` goes up by one for every build given out, question 26), `Stave/Info.plist` (`SUFeedURL` = `https://updates.nicojan.com/stave/appcast.xml`, `SUPublicEDKey`, `SUEnableAutomaticChecks` = YES, `SUAutomaticallyUpdate` = YES, no `SUEnableSystemProfiling`; question 25), `Stave/App/StaveApp.swift` (Stave ▸ Check for Updates…; Stave ▸ About Stave calls `orderFrontStandardAboutPanel(options:)` with `.applicationVersion` from `VersionText`), `Settings/SettingsCopy.swift` (Settings ▸ General ▸ "Check for updates automatically" and a second switch, "Download and install updates automatically", so turning off the download and install doesn't turn off checks), `THIRD_PARTY_NOTICES.md` (Sparkle, MIT), `README.md` (what the update check sends and what is counted, per decision 26)

**Interfaces:**
- Produces: `VersionText.aboutVersion(shortVersion: String) -> String`, built from `CFBundleShortVersionString` at run time, adding " beta" while the major version is 0 (question 26). No literal "0.1.0 beta" anywhere.

- [ ] **Step 1: Nico** runs `generate_keys --account stave` (question 24; never the default account, which already holds the shared key and would only print it), exports a backup with `generate_keys --account stave -x <file>` and keeps it safe, and gives only the public key (`generate_keys --account stave -p`) for `Info.plist`. **[Apple account not needed; Nico's Keychain]**
- [ ] **Step 2: Implement** the updater gated so Debug builds never check (`#if !DEBUG`), the menu item, the setting and the About version. Test `aboutVersionAddsBeta` (`0.1.0` → "0.1.0 beta", `1.0.0` → "1.0.0"). Updates download in the background and install on quit, on by default, with that Settings switch (Nico, 2026-11-14, question 25); the switch drives `SUAutomaticallyUpdate` and is independent of the check switch. The feed URL is the final one (decision 27).
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
