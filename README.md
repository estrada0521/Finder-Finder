# Lab Browser

Native macOS browser for linked local records. The supported entry point is
`./native_start`; it builds the Rust + AppKit application at
`/Applications/Lab Browser.app`.

It reads existing record directories, metadata, declared links, and payloads;
then provides direct Quick Look, Finder, clipboard, and default-app access.

Set `LAB_BROWSER_DB_ROOT` before the first launch, or edit
`~/.lab-browser/settings.json` afterwards to choose the records directory.
