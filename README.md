# Stave

A calm, organized web browser for macOS, built on WebKit: profiles, workspaces, pinned tabs that stay, and container tabs. A sibling of [Chorus](https://github.com/nicojan/Chorus), sharing its web engine.

## Status

In development, no release yet. The design is in `docs/superpowers/specs/2026-10-28-stave-design.md`, and the plans are in `docs/superpowers/plans/`.

- **Done:** the organization model and its storage. That covers profiles, workspaces, Essentials, pinned tabs and folders, regular tabs, the archive, containers and window restore, all stored in SQLite.
- **In review:** an importer for Arc's sidebar (spaces, pinned tabs and folders, Favorites, profiles).
- **Not yet:** web pages (they wait on the shared engine from Chorus), the real sidebar and command bar, and a release.

## Building

Requires macOS 14 or later, Xcode 16.2 or later, and [XcodeGen](https://github.com/yonaskolb/XcodeGen).

```sh
swift test --package-path Packages/StaveCore   # model, storage and import tests
xcodegen generate
xcodebuild build -project Stave.xcodeproj -scheme Stave -destination 'platform=macOS'
```

Debug builds keep their data in `~/Library/Application Support/Stave-debug`, apart from release builds.
