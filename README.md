# Stave

A calm, organized web browser for macOS, built on WebKit: profiles, workspaces, pinned tabs that stay, and container tabs. A sibling of [Chorus](https://github.com/nicojan/Chorus), sharing its web engine.

## Status

In development, no release yet. The design is in `docs/superpowers/specs/2026-10-28-stave-design.md`, and the plans are in `docs/superpowers/plans/`.

- **Done:** the organization model and its storage. That covers profiles, workspaces, Essentials, pinned tabs and folders, regular tabs, the archive, containers and window restore, all stored in SQLite.
- **Done:** an importer for Arc's sidebar (spaces, pinned tabs and folders, Favorites, profiles), with its import screens.
- **Done:** the window and sidebar, command bar, compact mode, drag and drop (including drag to reorder workspaces), keyboard moves, first run (search engine choice) and the Arc import UI.
- **Built, in review:** web pages on Chorus's shared engine (`ChorusEngine`): a page per tab with restore, pop-ups tied to their opener, a separate data store per profile, container and private window, content blocking, downloads, camera and microphone questions, and JavaScript dialogs.
- **Not yet:** settings, history, find, zoom, default-browser registration and a release. These are drafted as plan 5, waiting for review.

## Backups

Stave keeps copies of its database in the `Backups` folder inside its data folder, `~/Library/Application Support/Stave` (`Stave-debug` for Debug builds). It makes one at launch, one every hour while it runs, and one before it updates the database to a newer format. It keeps the 10 newest hourly copies and the newest copy of each of the last 3 days, plus the newest copy made before an update. A copy holds your profiles, workspaces, tabs, pinned tabs, folders, archive and settings. It has no history or downloads list, so clearing history is never undone by restoring an old copy.

Stave has no restore command. To restore a copy by hand:

1. Quit Stave.
2. In the data folder, move `stave.sqlite`, `stave.sqlite-wal` and `stave.sqlite-shm` aside together, for example into a new folder. Move all three: a leftover `-wal` file beside a different `stave.sqlite` can corrupt it.
3. Copy the backup you want from `Backups` into the data folder and rename it `stave.sqlite`.
4. Open Stave.

If the copy is from an older Stave, Stave backs it up again and then updates it when it opens.

## Building

Requires macOS 15 or later, Xcode 26 or later, and [XcodeGen](https://github.com/yonaskolb/XcodeGen).

```sh
swift test --package-path Packages/StaveCore   # model, storage and import tests
xcodegen generate
xcodebuild build -project Stave.xcodeproj -scheme Stave -destination 'platform=macOS'
```

Debug builds keep their data in `~/Library/Application Support/Stave-debug`, apart from release builds.
