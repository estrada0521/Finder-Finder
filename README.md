# Finder Finder

Finder to find Finder. The supported entry point is `./native_start`; it builds
the Rust + AppKit application at `/Applications/Finder Finder.app`.

It reads existing record directories, metadata, declared links, and payloads;
then provides direct Quick Look, Finder, clipboard, and default-app access.

Set `FINDER_FINDER_DB_ROOT` before the first launch, or edit
`~/.finder-finder/settings.json` afterwards to choose the records directory.

## Previews

Records may optionally declare a record-local visual derivative:

```json
"preview": "preview.png"
```

Finder Finder uses it for the row thumbnail and Quick Look display only. Open,
Finder reveal, and path copy actions always target `payload`. The preview can be
any Quick Look-compatible file produced alongside the record.
