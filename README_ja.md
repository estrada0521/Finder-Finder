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

パスは record directory からの相対パスを使います。preview は表示用、payload は source of truth です。行のサムネイルは `preview`、なければ最初の `payload` を表示します。

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

## メニューとショートカット

メニューバーから実行できるほか、行を右クリックするとその行への操作がまとまったメニューが出ます。Quick Look 表示中は矢印キーで項目を送れ、`⌘F` / `⌘C` / `⌘P` / `⌥⌘P` / `⌘O` は表示中の項目の payload を対象にします（通常リストでは record が対象）。

### ファイル・パス

| 操作 | ショートカット | 内容 |
| --- | --- | --- |
| Payload を開く | ダブルクリック / ⌥クリック | payload を既定アプリで開く |
| Quick Look | 選択済みの行をクリック | `preview`。なければ payload |
| Open Payload from Quick Look | ⌘O | Quick Look 表示中の項目の payload を開く（表示中のみ） |
| Open Metadata | ⌘J | `metadata.json` を開く |
| Reveal in Finder | ⌘F | Finder で表示 |
| Rename | ⌘↩ | `display_name` を変更（単一選択時のみ） |
| Copy | ⌘C | payload ファイルそのものをクリップボードへ |
| Copy Relative Path | ⌘P | DB root 基準のパスをコピー |
| Copy Full Path | ⌥⌘P | フルパスをコピー |

### リンク

| 操作 | ショートカット | 内容 |
| --- | --- | --- |
| Open Related | ⌘E | provenance を辿った関連 record を別ウィンドウで開く |
| Open Direct Links | ⌥⌘E | 直接リンクしている record だけを開く |
| Remove Link | ⌘⌫ | 選択行への直接リンクを外す（links ウィンドウでのみ有効、record は消えない） |

### 表示・並び替え

| 操作 | ショートカット | 内容 |
| --- | --- | --- |
| Category 切り替え | ⌥+頭文字 | 割り当て文字は Category メニューに表示 |
| Sort | メニューのみ | Number（既定）/ Name / Last Modified / Most Links。セッション限り |

### ウィンドウ

| 操作 | ショートカット | 内容 |
| --- | --- | --- |
| Move to Top / Left / Right / Center | ⌥⌘↑ / ⌥⌘← / ⌥⌘→ / ⌥⌘↓ | Top・Left・Right は片軸だけ移動、Center は画面中央。サイズは不変 |
| Keep in Front | ⌘T | 最前面に固定（既定でオン） |
| Close Window | ⌘W | 最後のウィンドウを閉じるとアプリ終了 |

## Record の追加

ウィンドウにファイルをドロップすると「Add Record」シートが開きます。category と display name を指定すると、ドロップしたファイルを payload とする新しい ID の record が作られます。

## その他の操作

| 操作 | 内容 |
| --- | --- |
| 行をドラッグ | その record の payload ファイルを外部アプリへドラッグ |
| ヘッダをクリック | 選択を解除 |

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
