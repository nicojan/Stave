# Stave

A calm, organized web browser for macOS, built on WebKit: profiles, workspaces, pinned tabs that stay, and container tabs. A sibling of [Chorus](https://github.com/nicojan/Chorus), sharing its web engine.

## Status

In development, no release yet. The design is in `docs/superpowers/specs/2026-10-28-stave-design.md`, and the plans are in `docs/superpowers/plans/`.

- **Done:** the organization model and its storage. That covers profiles, workspaces, Essentials, pinned tabs and folders, regular tabs, the archive, containers and window restore, all stored in SQLite.
- **Done:** an importer for Arc's sidebar (spaces, pinned tabs and folders, Favorites, profiles), with its import screens.
- **Done:** the window and sidebar, command bar, compact mode, drag and drop (including drag to reorder workspaces), keyboard moves, first run (search engine choice) and the Arc import UI.
- **Built, in review:** web pages on Chorus's shared engine (`ChorusEngine`): a page per tab with restore, pop-ups tied to their opener, a separate data store per profile, container and private window, content blocking, downloads, camera and microphone questions, and JavaScript dialogs.
- **Not yet:** settings, history, find, zoom, default-browser registration and a release. These are drafted as plan 5, waiting for review.

## Building

Requires macOS 15 or later, Xcode 26 or later, and [XcodeGen](https://github.com/yonaskolb/XcodeGen).

```sh
swift test --package-path Packages/StaveCore   # model, storage and import tests
xcodegen generate
xcodebuild build -project Stave.xcodeproj -scheme Stave -destination 'platform=macOS'
```

Debug builds keep their data in `~/Library/Application Support/Stave-debug`, apart from release builds.
