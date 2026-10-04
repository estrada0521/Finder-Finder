# Finder Finder

Finder to find Finder.

[English](README.md)

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

メニューバーから実行できるほか、行を右クリックするとその行への操作がまとまったメニューが出ます。Quick Look 表示中は矢印キーで項目を送れ、`⌥⌘R` / `⌘C` / `⌥⇧⌘C` / `⌥⌘C` / `⌘O` は表示中の項目の payload を対象にします（通常リストでは record が対象）。

### ファイル・パス

| 操作 | ショートカット | 内容 |
| --- | --- | --- |
| Open | ⌘O / ダブルクリック / ⌥クリック | payload を既定アプリで開く |
| Quick Look | Space / ⌘Y / 選択済みの行をクリック | `preview`。なければ payload |
| Reveal in Finder | ⌥⌘R | Finder で表示 |
| Open Metadata | ⌥⌘I | `metadata.json` を開く |
| Rename | Return | `display_name` を変更（単一選択時のみ） |
| Change Payloads… | 行の右クリックメニュー | record 内のファイルを選び、`payload` を更新する |
| Copy | ⌘C | payload ファイルそのものをクリップボードへ |
| Copy Absolute Path | ⌥⌘C | フルパスをコピー |
| Copy Relative Path | ⌥⇧⌘C | DB root 基準のパスをコピー |

### リンク

| 操作 | ショートカット | 内容 |
| --- | --- | --- |
| Open Links | ⌘E | provenance を辿った関連 record を別ウィンドウで開く |
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
| Always on top | ⌥⌘T | 最前面に固定（既定でオン） |
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

## Agent CLI

`./build --no-open` でGUIと読み取り専用CLIをビルドします。

```sh
ln -s /path/to/LabApp-2/cli/finder-finder/finder-finder ~/.local/bin/finder-finder
ln -s /path/to/LabApp-2/cli/finder-finder ~/.codex/skills/finder-finder
finder-finder --json context
finder-finder --json links record-alpha --direction both --depth 3
```

他のagentも同じskillディレクトリを所定のskillsディレクトリへsymlinkします。
`~/.local/bin` をPATHに入れてください。launcherは `CARGO_TARGET_DIR`、未指定なら
`~/.finder-finder/cache/native-target` のバイナリを使い、実行時にはビルドしません。
GUIのframeworkを使わずCLIだけをビルドする場合:

```sh
CARGO_TARGET_DIR="$HOME/.finder-finder/cache/native-target" cargo build --release --no-default-features --bin finder-finder
```

DB rootの優先順位は `--db-root` → `FINDER_FINDER_DB_ROOT` →
`~/.finder-finder/settings.json` の `dbRoot`。CLIは設定ファイルを作成しません。
`context`・`list`・`show`・`links`・`related` に `--json` を指定できます。
詳しくは `finder-finder --help` と [SKILL.md](cli/finder-finder/SKILL.md) を参照してください。
`links` は既定で直接の参照先を返します。`related` はGUIと同じ双方向3ホップの探索で、
一度離れたカテゴリへの再進入を除外します。カテゴリ名に特別な意味は持たせません。
JSONのschema versionは1。record、元のリンク情報を保持した有向edge、診断を含みます。
exit 1でも部分結果が得られる場合があります。exit 2は引数エラーです。
呼び出しごとにmetadataを走査します。atomic snapshotではなく、payloadの内容は読みません。

検証: `cargo test --lib` と、次のCLI結合テスト。

```sh
python3 tests/cli.py "$HOME/.finder-finder/cache/native-target/release/finder-finder"
```
