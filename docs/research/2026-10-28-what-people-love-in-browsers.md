# What people love (and leave) in other browsers

Research for Stave's design, 2026-10-28. Covers Arc, Dia, SigmaOS, Ora, Zen, Firefox, Vivaldi, Safari, Orion, Chrome and Brave.

**How much to trust this.** Three research passes read Hacker News threads, Tildes, Zen's GitHub discussions, MacRumors, MacPowerUsers, AppleVis, TidBITS, blogs and reviews. Reddit could only be reached through mirrors and snippets, and no vote counts were collected, so "recurs" means "came up across several sources", not a measured tally. Several vendor blogs (SupaSidebar, browser comparison sites) were discounted or used only for the Reddit quotes they carry. Feasibility tags are judgement calls for a WKWebView Mac browser; the ones checked in this project are marked **verified**.

## The short version

1. **Organization is why people come.** Arc's sidebar is the single most-missed thing about Arc. Zen's draw is workspaces, split view and Glance together. Stave's core is aimed at the right thing.
2. **Reliability is why people leave.** Orion is the closest analogue to Stave (WebKit, Mac, power-user features), and its users left over bugs, broken password autofill, site compatibility and sync gaps, not missing features. Speed from WebKit was never the problem.
3. **Losing tabs is unforgivable.** Arc users name tab loss on window close as what stops them switching to Zen. Session restore has to be bulletproof.
4. **Forced behaviour drives people off.** Zen users left when workspaces could not be turned off, and when a shared-workspaces change shipped as the default with no way to disable it. Opinionated features need a switch.
5. **Content blocking is table stakes.** It is the top reason people pick Brave and the top complaint against Safari. Without extensions, Stave must ship a good blocker built in. Chorus's engine already has one.
6. **Native Mac feel is open ground.** Firefox feels "weirdly alien in macOS land"; SigmaOS lost people by breaking standard shortcuts. A native WebKit app gets the feel for free if it keeps Safari/Chrome shortcuts.
7. **Arc stops working on 2026-12-22.** Accounts are deactivated and data is deleted within 30 days; The Browser Company points users to Dia ([TechCrunch](https://techcrunch.com/2026/10/22/arc-browser-sunsets-december-22-as-the-browser-company-doubles-down-on-dia/), verified). Dia is criticised as "Chrome with ChatGPT on top", so many Arc users will be shopping for a new browser.
8. **Trust in a small team is a real worry.** People hesitate over browsers run by one or two people (Zen's "bus factor", security trust). Open source, no forced account, no telemetry and a visible release cadence help.

## What people love

| Loved | Where | Why people love it | Feasibility in Stave |
|---|---|---|---|
| Vertical sidebar with pinned tabs and folders | Arc, Zen, Safari, Orion | "I miss Arc's sidebar the most. Everything else I can live without." | easy |
| Spaces / workspaces, each with its own pinned tabs | Arc, Zen, Vivaldi, SigmaOS | Keeps 20+ tabs per context manageable | easy |
| Pinned tabs that reset to their pinned page | Arc, Zen, Safari | Coyier liked Safari's reset as Arc's "done for now" | easy |
| Command bar over tabs, history, bookmarks and the web | Arc, Vivaldi | One field for everything | easy |
| Peek / Glance link previews | Arc, Zen, SigmaOS | Read a link without opening a tab | medium |
| Split view | Zen, SigmaOS, Vivaldi | "can't do without" (SigmaOS reviewer) | medium |
| Compact mode | Zen | Distraction-free page | medium (hover reveal over web content needs care) |
| Auto-archiving idle tabs | Arc | Tab overload clears itself | easy |
| Boosts (per-site CSS/JS) | Arc, Zen | Fix or restyle sites you use daily | medium; Chorus already injects per-service CSS and scripts |
| Containers (separate cookies per tab group) | Firefox | Privacy, several accounts on one site | **verified** possible: `WKWebsiteDataStore(forIdentifier:)`. Per-site auto-assignment rules are our own layer. |
| Built-in ad and tracker blocking | Brave, Orion | No extensions needed, ad-free YouTube | medium; network blocking via `WKContentRuleList` is easy, uBlock-level cosmetic filtering is not. Chorus ships HaGezi. |
| Speed and native feel | Orion, Safari | "far less problematic than Chrome or Firefox or Arc" | easy, inherited from WebKit |
| Zero telemetry | Orion, Brave | Trust | easy, a policy choice |
| Space colours that tint the whole sidebar | Arc | Instantly see which context you are in | easy |
| Select tab 1–9 with ⌘ digits, counting pinned tabs | Zen | Muscle memory | easy |
| Rebindable shortcuts | Vivaldi, Zen | Power users set their own | easy |
| Web panels in a side panel | Vivaldi | Keep a chat or notes site open alongside | easy |
| Chat with your tabs (AI) | Dia | Summaries across open tabs | medium; optional at most, AI-first is what Dia gets criticised for |

## Why people leave

| Reason | Where | Lesson for Stave |
|---|---|---|
| Bugs and rough edges (about 12 mentions in one Orion HN thread) | Orion, SigmaOS, Zen beta | Polish and stability before new features |
| Password autofill breaking, weak iCloud Passwords | Orion | See the Passwords note below; it is the same wall Stave faces |
| Google Docs/Sheets, Reddit, SSO redirects misbehaving | Orion, SigmaOS | A site-compatibility toolkit and early SSO testing |
| Sync gaps (history, non-default profiles) | Orion, Zen | Design for sync now, even if it ships later |
| Tab loss on window close | Zen | Never lose a tab |
| Forced behaviour with no off switch | Zen | Every opinionated behaviour gets a setting |
| Breaking standard shortcuts | SigmaOS | Keep Safari/Chrome defaults |
| Abandonment, AI pivot, forced login | Arc, Dia | No account needed, AI optional, steady releases |
| Crypto, rewards and new-tab ads | Brave | Nothing in the UI that sells something |
| Losing extensions (Manifest V3) | Vivaldi, Chrome | Stave starts with none; the built-in blocker and Boosts have to cover the main reasons people install them |
| Tab placement regressions after a rewrite | Vivaldi 8.0 | Tab placement rules must be deterministic and tested |
| Missing folders | SigmaOS | Folders in the pinned area |

## Table stakes for any daily browser

1. Sites just work: Google Workspace, Meet, banking, Slack, Reddit, SSO logins.
2. Password autofill that doesn't break.
3. Ad and tracker blocking.
4. No crashes, no lost tabs, fast tab switching.
5. Battery and memory discipline (people believe in it even where the data is mixed).
6. Video that works: Picture in Picture, background playback, DRM streaming.
7. Sync across devices (people expect it eventually).
8. Privacy with no telemetry.
9. Usable developer tools (Safari's Web Inspector works with WKWebView).

## Corrections to the raw research

The research passes guessed at a few things this project has already checked:

- **iCloud Passwords is not impossible, and system AutoFill does not just work.** Apple's Passwords helper serves only browsers on a list built into macOS; Orion and Zen are on it. Stave needs Apple to add it after a public release. Passkeys need Apple's browser passkey entitlement. Both were checked on this Mac on 2026-10-28.
- **Camera, mic and Meet-style calls work in WKWebView.** Chorus ships Google Meet and Microsoft Teams calls today.
- **SSO and popup sign-in flows are solvable.** Chorus has already fixed several (popups must inherit the opener's store and user agent), and that code comes with the shared engine.
- **DRM (Netflix, Widevine/FairPlay) in WKWebView is still unverified.** Test it early.

## What to build into the foundation now

These shape the data model and architecture, so they belong in the first design even where the feature ships later.

1. **Windows are views onto a profile's state, not owners of tabs.** Zen had to retrofit this, painfully (discussion #924). Two windows can show the same workspace.
2. **A workspace slot holds a tab or a split group.** Split view later needs no data migration.
3. **Tabs are never silently lost.** Closing archives rather than deletes; every change is saved as it happens, not at quit. Auto-archive of idle tabs builds on the same archive.
4. **Folders inside the pinned area** from day one.
5. **Stable IDs and change timestamps on every record**, so sync (likely CloudKit) can come later without reshaping the data.
6. **A settings switch for every opinionated behaviour.** No forced account, no telemetry.
7. **Safari/Chrome shortcut defaults**, rebindable later. Decide whether ⌘1–9 counts Essentials and pinned tabs.
8. **Content blocking on by default**, from Chorus's engine.
9. **A site-compatibility toolkit:** per-site user agent override, and an "open this page in another browser" escape hatch for the sites that break.
10. **Import from Arc, Safari and Chrome**: pinned tabs, Spaces as workspaces, bookmarks, history. Arc keeps its sidebar in a local file (believed to be `StorableSidebar.json` under `~/Library/Application Support/Arc`; verify).
11. **Hibernation of background tabs**, from Chorus's engine, for memory and battery.
12. **Boosts later** on top of the engine's existing CSS and script injection.
13. **Later, not first release:** Reader mode (our own extraction, no public API), sync, AI features.

## Sources

Arc, Dia, SigmaOS, Ora
- https://techcrunch.com/2026/10/22/arc-browser-sunsets-december-22-as-the-browser-company-doubles-down-on-dia/
- https://alternativeto.net/news/2026/10/the-browser-company-confirms-arc-browser-sunset-directs-users-to-ai-powered-successor-dia/
- https://supasidebar.com/blog/switching-from-arc-browser (vendor; used only for the Reddit quotes it carries)
- https://dev.to/sidtalesara/arc-browser-is-dead-and-dia-isnt-the-answer-a-deeply-frustrated-honest-review-21e8
- https://dev.to/theairabbit/arc-browser-a-compelling-but-controversial-newcomer-59oa
- https://clipcontent.substack.com/p/arc-has-changed-the-way-i-browse-22-11-08
- https://talk.tidbits.com/t/arc-now-in-maintenance-mode/31174
- https://www.androidauthority.com/dia-browser-hands-on-3568966/
- https://medium.com/@devongnall/sigmaos-review-great-design-horrible-keyboard-shortcuts-3d876478d7eb
- https://www.producthunt.com/products/sigmaos/reviews/new
- https://github.com/the-ora/browser (GPL-2.0, "not ready for daily use yet", macOS 15+)
- https://community.vercel.com/t/ora-browser-the-open-source-arc-alternative-for-macos/29424

Zen, Firefox, Vivaldi
- https://reddit.birdcat.cafe/r/browsers/comments/1kfaag8/thoughts_on_zen
- https://tildes.net/~tech/1r9o/zen_browser_chrome_alternatives
- https://github.com/zen-browser/desktop/discussions/924
- https://github.com/zen-browser/desktop/issues/11407
- https://piunikaweb.com/2026/09/11/zen-browser-regular-tabs-sync-on-hold/
- https://piunikaweb.com/2026/05/31/vivaldi-8-0-developers-investigating-bugs/
- https://reddit.birdcat.cafe/r/vivaldibrowser/comments/1hqa9oc/manifest_v3
- https://connect.mozilla.org/t5/ideas/native-tab-grouping-more-customizable-tab-bar/idc-p/82020
- https://alternativeto.net/news/2025/8/zen-web-browser-finally-gets-folders-simplifying-tab-grouping-in-the-sidebar/
- https://newreleases.io/project/github/zen-browser/desktop/release/1.22.2b

Safari, Orion, Chrome, Brave
- https://news.ycombinator.com/item?id=48970894 (Orion thread, July 2026)
- https://news.ycombinator.com/item?id=49960628
- https://news.ycombinator.com/item?id=49878759 (switching to Brave, September 2026)
- https://news.ycombinator.com/item?id=46834441
- https://chriscoyier.net/2024/12/04/attempting-a-safari-move/
- https://birchtree.me/blog/everyone-says-chrome-devastates-mac-battery-life-but-does-it-i-tested-for-36-hours-to-find-out/
- https://talk.macpowerusers.com/t/talking-about-browsers-on-mac-ipad-and-iphone/42833
- https://talk.macpowerusers.com/t/alternatives-to-the-arc-browser/41013
- https://tidbits.com/?p=62916
- https://digitaltrends.com/computing/why-i-stopped-using-safari-on-my-mac
- https://applevis.com/comment/166361
