# Finder Finder

Finder to find Finder.

[English](README.md)

Finder Finder は、既存の record ディレクトリを閲覧するための小さな macOS
アプリです。record ごとの JSON metadata を高速なリストへ読み込み、実ファイルを
Quick Look、Finder、クリップボード、既定アプリへ接続します。

## DB の形

一つのディレクトリを DB root として指定します。その直下にある隠しでないディレクトリは
すべて record として扱われ、ディレクトリ名が record ID になります。

```text
Database/
├── 000333/
│   ├── metadata.json
│   ├── measurement.csv
│   └── preview.png
├── experiment-alpha/
│   ├── metadata.json
│   └── result.pdf
└── notes/                 # 隠しディレクトリでなければこれも record
    └── metadata.json
```

ID は opaque な文字列です。Finder Finder は 6 桁・数字のみ・特定の命名規則を
要求しません。また、再帰的には探索せず、DB root の直下だけを record と見なします。

推奨する metadata ファイル名は `metadata.json` です。互換のため、それが存在しない
場合は record 直下の `.json` ファイルのうち辞書順で最初のものを使います。metadata を
正しく読めない record も発見自体はされますが、category は空になり、通常の操作も使え
ません。実用上は `metadata.json` を必須と考えてください。

## Metadata 契約

metadata は JSON object です。典型的な完全形は次のとおりです。

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
| `category` | はい | アプリで表示する category。`rawdata`、`analysis`、`sample` のような任意の空でない名前です。 |
| `display_name` | いいえ | 人間向けの行タイトル。存在しない、または空なら record ID を使います。 |
| `payload` | ファイル操作には必要 | record 内の一つのファイル名、またはファイル名の配列です。アプリが開く・Finder で表示する・コピーする実体であり、すべて存在する必要があります。 |
| `preview` | いいえ | record 内にある、Quick Look 対応の視覚的な派生物です。行のサムネイルと Quick Look にだけ使います。 |
| `links` | いいえ | `id` を持つ object の配列です。この record から別の record への直接の関係を宣言します。 |

`payload` と `preview` には record ディレクトリからの相対パスを使ってください。
`preview` は同じ record ディレクトリの内部にあるファイルとして解決できる必要があります。
Finder Finder は、Finder で開く対象や既定アプリで開く対象を preview に置き換えません。

### Preview

preview は意図的に format-agnostic です。元データを最もよく理解している任意のツールで
作った、Quick Look が表示できるファイルであれば構いません。

```text
CSV       → PNG
HDF5      → PNG
structure → PDF
audio     → waveform PNG
dataset   → HTML snapshot
```

preview を持たない record も有効です。その場合は payload の通常の system icon と
Quick Look 表現を使います。

### Link は両方向・1 hop

record `A` で links command を実行すると、次の両方を表示します。

- `A.links` が名前として持つ record
- `links` 配列の中で `A` を名前として持つ record

対象は直接の関係だけです。アプリは link を再帰展開せず、順方向・逆方向の両方から
到達した record も一度だけ表示します。

## 各操作が対象にするもの

| 表面または操作 | 対象 |
| --- | --- |
| 行のサムネイル | `preview`。なければ最初の `payload` |
| Quick Look | `preview` があればそれ。なければ各 payload |
| Payload を開く | `payload` |
| Finder で表示 (`⌘F`) | 通常リストでは metadata（したがって record directory）。Quick Look 中では payload |
| Path をコピー (`⌘P`) | 通常リストでは record directory。Quick Look 中では payload |
| Metadata を開く | record の metadata JSON |

この区別は意図的なものです。preview は record を一目で読めるようにするための表現であり、
payload が source of truth のままです。

## 設定

初回起動時は、次のように DB root を指定できます。

```sh
FINDER_FINDER_DB_ROOT=/path/to/Database ./build
```

選んだ root は次に保存されます。

```text
~/.finder-finder/settings.json
```

後から DB を切り替える場合は、その中の `dbRoot` を編集してください。Finder Finder は
通常 DB を変更しません。ただし Rename は record の metadata JSON にある
`display_name` を更新します。

## Build と install

Finder Finder は Rust core と小さな Objective-C/AppKit shell からなります。

```sh
./build
```

release app を build し、次へ install します。

```text
/Applications/Finder Finder.app
```

反復開発には `./build --dev` を使えます。source の変更は rebuild とアプリの
restart を必要とします。
