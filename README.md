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

Use paths relative to the record directory. Preview is for display; payload is the source of truth.

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

## Actions

| Surface or action | Target |
| --- | --- |
| Row thumbnail | `preview`, otherwise the first `payload` |
| Quick Look | `preview` when present; otherwise each payload |
| Open payload | `payload` |
| Reveal in Finder (`⌘F`) | Metadata from the list; payload from Quick Look |
| Copy relative path (`⌘P`) | DB-root-relative record directory from the list; DB-root-relative payload from Quick Look |
| Copy full path (`⌥⌘P`) | Record directory from the list; payload from Quick Look |
| Open Metadata | `metadata.json` |

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
