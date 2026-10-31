# Stave — project instructions

Stave is a Zen-style web browser for macOS on WKWebView, a sibling of Chorus (`../Chorus`) that will share Chorus's extracted web engine (`ChorusEngine` package, tagged in the Chorus repo).

## Read first

- Design: `docs/superpowers/specs/2026-10-28-stave-design.md` — the source of truth for scope and decisions. Items marked "(my call)" were Claude's decisions and can be revisited with Nico.
- Research: `docs/research/2026-10-28-what-people-love-in-browsers.md`.
- Plans: `docs/superpowers/plans/`. The foundation plan lists the roadmap of later plans. Each finished plan ends with an "Outcome" section and a "Carried into later plans" section. Read both before writing the next plan.

## Rules

- Open source, MIT. Never copy code from Zen (MPL-2.0), Ora (GPL-2.0) or Nook (GPL-3.0); behaviour reference only. MIT code may be adapted with attribution in `THIRD_PARTY_NOTICES.md`.
- The bundle ID `com.nicojan.Stave` must never change (Apple's Passwords allow-list and passkey entitlement attach to it). Debug builds use `com.nicojan.Stave.debug` and `Application Support/Stave-debug`; never open a store through a framework default path.
- Never lose user data: nothing is deleted without passing through the archive, except a profile or container deletion the user confirmed.
- Engine code is never edited here. Engine changes go to Chorus and come back through a tag pinned `exact:`.
- Test fixtures never contain anyone's real browsing data (the repo is public).
- Stage named paths, never `git add -A`; a parallel session may be working in Chorus or here.
- Markdown is never hard-wrapped.
- CI's macOS 14 runner has Xcode 16.2 / Swift 6.0.3. No Swift 6.1+ features, so GRDB is capped below 7.9. Never nest `try #require` inside `#expect`; hoist it to a `let`.
- Nico's real Arc data (`~/Library/Application Support/Arc/`) is read only by throwaway programs kept outside the repo. Those programs print keys, types and counts, never titles, URLs or IDs, and nothing they read goes into a fixture, commit or log.
- Data from outside (Arc files, later other browsers' files) is hostile input. A strange shape is reported to the user, never fatal, and never dropped silently.
- By-hand checks launch the Debug app with `-StaveDataDirectory <folder>/data -StaveArcHome <folder>/home -StaveSeedSample`, using a throwaway folder under `/private/tmp` (literal path). The full procedure is "The by-hand check" in the plan 4 file.
- Checks always pass `-StaveArcHome` pointing at a throwaway folder. A Debug launch with `-StaveDataDirectory` but no `-StaveArcHome` isolates the Arc home inside the data folder, but never rely on that.
- Screenshots use `swift scripts/capture-window.swift Stave <path>.png` and accessibility labels use `scripts/ax-dump.sh Stave`. Screenshots stay in the session scratchpad, never in the repo.
- Send keystrokes only after confirming Stave is frontmost in the same osascript call, and never click outside Stave.
