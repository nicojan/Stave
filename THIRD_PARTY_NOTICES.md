# Third-party notices

Stave is MIT licensed. It depends on the components below, and the app bundle ships the files named under ChorusEngine. Nothing here was copied from Zen, Ora or Nook.

## ChorusEngine

- Project: [Chorus](https://github.com/nicojan/Chorus), the `ChorusEngine` package, pinned to tag `1.5.36`
- Author: Nico Jan
- License: MIT

Stave links the engine as a Swift package. The engine's resource bundle is copied into the app as `Stave.app/Contents/Resources/ChorusEngine_ChorusEngine.bundle`. Inside it, `Contents/Resources/licenses/` holds the full licence texts (`GPL-3.0.txt`, `CC-BY-3.0.txt`, `DarkReader-MIT.txt`, `Chorus-MIT.txt`), and `Contents/Resources/THIRD_PARTY_NOTICES.md` is the engine's own notice file with the sources and versions of the items below.

### HaGeZi Light (ad and tracker blocklist)

- Project: [HaGeZi DNS Blocklists](https://github.com/hagezi/dns-blocklists), by HaGeZi and contributors
- License: GPL-3.0 (`licenses/GPL-3.0.txt` in the bundle)
- In the app: `hagezi-light.json`, converted to WebKit content rules and read as data

### Fanboy's Annoyance List

- Project: [EasyList](https://easylist.to/), by Fanboy and the EasyList authors
- License: CC BY 3.0 (`licenses/CC-BY-3.0.txt` in the bundle)
- In the app: `fanboy-annoyance.json`, converted to WebKit content rules and read as data

### Dark Reader

- Project: [Dark Reader](https://github.com/darkreader/darkreader)
- License: MIT (`licenses/DarkReader-MIT.txt` in the bundle)
- In the app: `darkreader.js`, bundled with the engine but not used by Stave yet

## GRDB

- Project: [GRDB.swift](https://github.com/groue/GRDB.swift), by Gwendal Roué
- License: MIT
- Use: SQLite access in StaveCore
