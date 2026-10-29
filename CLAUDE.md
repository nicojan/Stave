# Stave — project instructions

Stave is a Zen-style web browser for macOS on WKWebView, a sibling of Chorus (`../Chorus`) that will share Chorus's extracted web engine (`ChorusEngine` package, tagged in the Chorus repo).

## Read first

- Design: `docs/superpowers/specs/2026-10-28-stave-design.md` — the source of truth for scope and decisions. Items marked "(my call)" were Claude's decisions and can be revisited with Nico.
- Research: `docs/research/2026-10-28-what-people-love-in-browsers.md`.
- Plans: `docs/superpowers/plans/`. The foundation plan lists the roadmap of later plans.

## Rules

- Open source, MIT. Never copy code from Zen (MPL-2.0) or Ora (GPL-2.0); behaviour reference only. MIT code may be adapted with attribution in `THIRD_PARTY_NOTICES.md`.
- The bundle ID `com.nicojan.Stave` must never change (Apple's Passwords allow-list and passkey entitlement attach to it). Debug builds use `com.nicojan.Stave.debug` and `Application Support/Stave-debug`; never open a store through a framework default path.
- Never lose user data: nothing is deleted without passing through the archive, except a profile or container deletion the user confirmed.
- Engine code is never edited here. Engine changes go to Chorus and come back through a tag pinned `exact:`.
- Test fixtures never contain anyone's real browsing data (the repo is public).
- Stage named paths, never `git add -A`; a parallel session may be working in Chorus or here.
- Markdown is never hard-wrapped.
