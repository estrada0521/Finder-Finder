<div align="center">

# Finder Finder

Finder to find Finder.

[日本語](README_ja.md)

</div>

<p align="center">
  <img src="media/f100.png" width="100%" alt="Finder Finder">
</p>

---

## DB layout

One record is a directory directly under the DB root, containing `metadata.json`. Its ID is a six-digit number such as `000001`, used as the directory name. Add Record assigns the next number after the highest existing ID.
Set the DB root as `dbRoot` in `~/.finder-finder/settings.json`.

```text
Database/
└── 000001/
    ├── metadata.json
    ├── measurement.csv
    └── preview.png
```

## Metadata

<details>
<summary>Fields</summary>

| Field | Required | Content |
| --- | --- | --- |
| `category` | ✓ | Display category |
| `display_name` | | Display name; defaults to the ID |
| `payload` | For file actions | Record-relative filename or array of filenames |
| `preview` | | Quick Look-compatible display file; falls back to payload |
| `links` | | Array of `{"id": "000002"}` objects |

</details>

## Operations

<details>
<summary>Actions and shortcuts</summary>

### Data actions

| Action | Key | Effect |
| --- | --- | --- |
| Open | `⌘O` / double-click / `⌥`-click | opens the payload in the default app |
| Quick Look | `Space` / `⌘Y` / click a selected row | `preview`, otherwise each payload |
| Reveal in Finder | `⌥⌘R` | shows it in Finder |
| Open Metadata | `⌥⌘I` | opens `metadata.json` |
| Rename | `Return` | edits `display_name` (single selection only) |
| Change Payloads… | row context menu | chooses one or more record-local files and writes them to `payload` |
| Copy | `⌘C` | copies the payload files themselves to the clipboard |
| Copy Absolute Path | `⌥⌘C` | copies the full path, wrapped in backticks |
| Copy Relative Path | `⌥⇧⌘C` | copies the DB-root-relative path, wrapped in backticks |
| Open Links | `⌘E` | opens related records along the provenance graph in a new window |
| Open Direct Links | `⌥⌘E` | opens only the directly linked records |
| Remove Link | `⌘`⌫ | removes the direct link to the selected row (links window only; the records are not deleted) |
| Pass payloads | drag a row | Sends payload files to another app |
| Add record | drop files onto a window | Choose a category and display name |

### View and window

| Action | Key | Effect |
| --- | --- | --- |
| Switch category | `⌥`+initial | the assigned letter is shown in the Category menu |
| Sort | menu only | Number (default) / Name / Last Modified / Most Links; not persisted |
| Move to Top / Left / Right / Center | `⌥⌘↑` / `⌥⌘←` / `⌥⌘→` / `⌥⌘↓` | Top/Left/Right move along one axis; Center centers on screen. Size is unchanged |
| Always on top | `⌥⌘T` | pins above other windows (on by default) |
| Close Window | `⌘W` | closing the last window quits the app |
| Clear selection | click the header | |

During Quick Look, arrow keys step through items. Open, Reveal, Copy, and path copying act on the displayed item’s payload.

</details>

## Setup

Requires Rust and Xcode Command Line Tools. Set the DB root for the first build.

```sh
FINDER_FINDER_DB_ROOT=/path/to/Database ./build
```

The app and read-only CLI are built, and the app is saved to `/Applications/Finder Finder.app` and launched. Use `./build` after setup, or `./build --no-open` to skip launching.

The DB root is saved as `dbRoot` in `~/.finder-finder/settings.json`. Edit it to change databases.

## CLI

A simple CLI for Agents to follow links.

To use it, add `cli/finder-finder` to PATH and place [SKILL.md](cli/finder-finder/SKILL.md) in the Agent’s environment.
