# Finder Finder

Finder to find Finder.

[English](README.md)

Finder Finder は、既存の record ディレクトリを閲覧し、そのファイルを Quick Look、Finder、クリップボード、既定アプリへ接続するアプリです。

## DB の形

一つのディレクトリを DB root として指定します。その直下にあり、`metadata.json` を持つディレクトリが record です。

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

各 `metadata.json` は JSON object です。

```json
{
  "category": "rawdata",
  "display_name": "Example measurement",
  "payload": ["measurement.csv", "notes.pdf"],
  "preview": "preview.png",
  "links": [{ "id": "000271" }, { "id": "experiment-alpha" }]
}
```

| Field | 必須 | 意味 |
| --- | --- | --- |
| `category` | はい | アプリで表示する category。 |
| `display_name` | いいえ | 行タイトル。なければ record ID を使います。 |
| `payload` | ファイル操作には必要 | record 内の一つのファイル名、またはファイル名の配列。 |
| `preview` | いいえ | record 内の、Quick Look 対応の表示用ファイル。 |
| `links` | いいえ | `id` field を持つ object の配列。 |

パスは record directory からの相対パスを使います。preview は表示用、payload は source of truth です。

### Preview

preview には、record とともに置かれた任意の Quick Look 対応表現を使えます。

```text
CSV       → PNG
HDF5      → PNG
structure → PDF
audio     → waveform PNG
dataset   → HTML snapshot
```

### Link

link window には、直接 link している record を順方向・逆方向から集め、一度ずつ表示します。

## 各操作が対象にするもの

| 表面または操作 | 対象 |
| --- | --- |
| 行のサムネイル | `preview`。なければ最初の `payload` |
| Quick Look | `preview` があればそれ。なければ各 payload |
| Payload を開く | `payload` |
| Finder で表示 (`⌘F`) | 通常リストでは metadata、Quick Look 中では payload |
| Path をコピー (`⌘P`) | 通常リストでは record directory、Quick Look 中では payload |
| Metadata を開く | `metadata.json` |

## 設定

初回起動時は、次のように DB root を指定できます。

```sh
FINDER_FINDER_DB_ROOT=/path/to/Database ./build
```

設定は `~/.finder-finder/settings.json` に保存されます。DB を切り替える場合は、その中の `dbRoot` を編集してください。

## Build

```sh
./build
```

アプリは `/Applications/Finder Finder.app` に install されます。

反復開発には `./build --dev` を使えます。source の変更には rebuild とアプリの restart が必要です。
