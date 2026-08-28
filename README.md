# Finder Finder

Finder to find Finder.

[日本語版](README_ja.md)

Finder Finder is a small macOS browser for an existing directory of records.
It reads record-local JSON metadata into a fast list, then connects the
underlying files to Quick Look, Finder, the clipboard, and their default
applications.

## Database layout

Choose one directory as the database root. Every non-hidden directory directly
under that root is treated as a record. Its directory name is the record ID.

```text
Database/
├── 000333/
│   ├── metadata.json
│   ├── measurement.csv
│   └── preview.png
├── experiment-alpha/
│   ├── metadata.json
│   └── result.pdf
└── notes/                 # also a record if it is not hidden
    └── metadata.json
```

IDs are opaque strings: Finder Finder does **not** require six digits, a
numeric name, or any particular naming scheme. It does not recurse into nested
directories; only immediate children of the database root become records.

`metadata.json` is the recommended metadata filename. For compatibility, if it
is absent Finder Finder uses the lexicographically first `.json` file directly
inside the record directory. Records without usable metadata are still found,
but will have an empty category and no usable actions; treat `metadata.json` as
required in practice.

## Metadata contract

Metadata is a JSON object. A complete, typical record looks like this:

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
| `category` | Yes | Category shown in the app. It is an arbitrary non-empty name, such as `rawdata`, `analysis`, or `sample`. |
| `display_name` | No | Human-facing row title. The record ID is used when absent or empty. |
| `payload` | Yes for file actions | One record-local filename or an array of filenames. These are the real files opened, revealed, and copied by the app. Every named file must exist. |
| `preview` | No | One record-local, Quick Look-compatible visual derivative. It is used only for the row thumbnail and Quick Look display. |
| `links` | No | Array of objects with an `id`. Each object declares one direct relation from this record to another record. |

Use paths relative to the record directory for `payload` and `preview`.
`preview` is required to resolve to a file contained in that same record
directory. Finder Finder never substitutes it for the payload when opening a
file or revealing it in Finder.

### Previews

A preview is deliberately format-agnostic. It can be any file Quick Look can
show, produced by whatever tool understands the underlying data best:

```text
CSV       → PNG
HDF5      → PNG
structure → PDF
audio     → waveform PNG
dataset   → HTML snapshot
```

A record may have no preview. In that case Finder Finder uses the payload's
normal system icon and Quick Look representation.

### Links are one hop in either direction

Pressing the links command for record `A` shows both:

- records named by `A.links`; and
- records whose `links` array names `A`.

These are direct relations only. The app does not recursively expand links, and
a record reached in both directions appears once.

## What actions target

| Surface or action | Target |
| --- | --- |
| Row thumbnail | `preview`, otherwise the first `payload` |
| Quick Look | `preview` when present; otherwise each payload |
| Open payload | `payload` |
| Reveal in Finder (`⌘F`) | Metadata on the list (therefore its record directory); payload from Quick Look |
| Copy path (`⌘P`) | Record directory on the list; payload from Quick Look |
| Open Metadata | the record's metadata JSON |

This distinction is intentional: a preview makes a record legible at a glance,
while the payload remains its source of truth.

## Configuration

On first launch, set the root with:

```sh
FINDER_FINDER_DB_ROOT=/path/to/Database ./build
```

Finder Finder persists the chosen root in:

```text
~/.finder-finder/settings.json
```

Edit `dbRoot` there to switch databases later. The app otherwise leaves the
database alone, except that Rename updates `display_name` in the record's
metadata JSON.

## Build and install

Finder Finder is a Rust core with a small Objective-C/AppKit shell.

```sh
./build
```

This builds the release app and installs it at:

```text
/Applications/Finder Finder.app
```

For iterative development, use `./build --dev`. Source changes require
a rebuild and application restart.
