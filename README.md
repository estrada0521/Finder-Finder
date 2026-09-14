# Finder Finder

Finder to find Finder.

[日本語版](README_ja.md)

Finder Finder browses an existing directory of records and connects their files to Quick Look, Finder, the clipboard, and default applications.

## Database layout

Set one directory as the database root. Its direct child directories containing `metadata.json` are records.

```text
Database/
├── 000333/
│   ├── metadata.json
│   ├── measurement.csv
│   └── preview.png
└── experiment-alpha/
    ├── metadata.json
    └── result.pdf
```

## Metadata

Each `metadata.json` is a JSON object.

```json
{
  "category": "rawdata",
  "display_name": "Example measurement",
  "payload": ["measurement.csv", "notes.pdf"],
  "preview": "preview.png",
  "links": [{ "id": "000271" }, { "id": "experiment-alpha" }]
}
```

| Field | Required | Meaning |
| --- | --- | --- |
| `category` | Yes | Category shown in the app. |
| `display_name` | No | Row title. The record ID is used when absent. |
| `payload` | Yes for file actions | One record-local filename or an array of filenames. |
| `preview` | No | One record-local, Quick Look-compatible display file. |
| `links` | No | Array of objects with an `id` field. |

Use paths relative to the record directory. Preview is for display; payload is the source of truth. Row thumbnails show the `preview`, or the first `payload` when there is none.

### Previews

A preview can be any Quick Look-compatible representation created alongside the record.

```text
CSV       → PNG
HDF5      → PNG
structure → PDF
audio     → waveform PNG
dataset   → HTML snapshot
```

### Links

The links window presents directly linked records in both directions and shows each record once.

## Menu and shortcuts

Everything is available from the menu bar; right-clicking a row opens a menu with that row's actions. During Quick Look the arrow keys step through items, and `⌘F` / `⌘C` / `⌘P` / `⌥⌘P` / `⌘O` act on the previewed item's payload (in the list they act on the record).

### Files and paths

| Action | Shortcut | Notes |
| --- | --- | --- |
| Open payload | double-click / ⌥-click | opens the payload in the default app |
| Quick Look | click a selected row | `preview`, otherwise each payload |
| Change Payloads… | row context menu | chooses one or more record-local files and writes them to `payload` |
| Open Payload from Quick Look | ⌘O | opens the previewed item's payload (only while Quick Look is open) |
| Open Metadata | ⌘J | opens `metadata.json` |
| Reveal in Finder | ⌘F | shows it in Finder |
| Rename | ⌘↩ | edits `display_name` (single selection only) |
| Copy | ⌘C | copies the payload files themselves to the clipboard |
| Copy Relative Path | ⌘P | copies the DB-root-relative path |
| Copy Full Path | ⌥⌘P | copies the full path |

### Links

| Action | Shortcut | Notes |
| --- | --- | --- |
| Open Related | ⌘E | opens related records along the provenance graph in a new window |
| Open Direct Links | ⌥⌘E | opens only the directly linked records |
| Remove Link | ⌘⌫ | removes the direct link to the selected row (links window only; the records are not deleted) |

### View and sorting

| Action | Shortcut | Notes |
| --- | --- | --- |
| Switch category | ⌥+initial | the assigned letter is shown in the Category menu |
| Sort | menu only | Number (default) / Name / Last Modified / Most Links; not persisted |

### Window

| Action | Shortcut | Notes |
| --- | --- | --- |
| Move to Top / Left / Right / Center | ⌥⌘↑ / ⌥⌘← / ⌥⌘→ / ⌥⌘↓ | Top/Left/Right move along one axis; Center centers on screen. Size is unchanged |
| Keep in Front | ⌘T | pins above other windows (on by default) |
| Close Window | ⌘W | closing the last window quits the app |

## Adding records

Dropping files onto a window opens an "Add Record" sheet. Choose a category and display name, and a new record with a fresh ID is created with the dropped files as its payload.

## Other interactions

| Action | Effect |
| --- | --- |
| Drag a row | drags the record's payload files to another app |
| Click the header | clears the selection |

## Configuration

Set the database root on first launch:

```sh
FINDER_FINDER_DB_ROOT=/path/to/Database ./build
```

The setting is stored in `~/.finder-finder/settings.json`. Edit `dbRoot` there to switch databases.

## Build

```sh
./build
```

The app is installed at `/Applications/Finder Finder.app`.

Use `./build --dev` for iterative development. Source changes require a rebuild and application restart.
