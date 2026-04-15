# 01. Introduction

## neru とは

neru は、ビジュアルノベルエンジン [nerune-engine](https://github.com/NaruseNia/nerune-engine) 向けのスクリプト言語です。

**2層アーキテクチャ** を採用しており、シナリオライターとプログラマーがそれぞれの領域で快適に作業できます。

| 層 | 拡張子 | 対象 | 用途 |
|---|---|---|---|
| シナリオ層 | `.neru` | ライター | テキスト表示、演出、選択肢、分岐 |
| ロジック層 | `.nerul` | プログラマー | ゲームロジック、データ処理、関数定義 |

## インストール

### バイナリダウンロード

[Releases](https://github.com/NaruseNia/neru/releases/latest) から OS に合ったバイナリをダウンロードし、PATH の通った場所に配置してください。

### ソースからビルド

[Zig](https://ziglang.org/) 0.15.2 以上が必要です。

```sh
git clone https://github.com/NaruseNia/neru.git
cd neru
zig build
```

`zig-out/bin/neru` にバイナリが生成されます。

## Hello World

### ロジック層 (`.nerul`)

```
// hello.nerul
let message = "Hello, neru!"
debug.log(message)
```

```sh
neru run hello.nerul
```

### シナリオ層 (`.neru`)

```
// hello.neru
@speaker Alice
Hello, traveler!
@wait 500
Welcome to the world of neru.
```

```sh
neru run --mock hello.neru
```

出力:
```
[speaker] Alice
[text] Alice: Hello, traveler!
[wait] 500ms
[text] Alice: Welcome to the world of neru.
```

## CLI コマンド

| コマンド | 説明 |
|---|---|
| `neru compile <file>` | バイトコード (`.neruc`) にコンパイル |
| `neru run <file>` | コンパイル + 即時実行 |
| `neru run --mock <file>` | モックエンジンで実行（イベントを stdout に出力） |
| `neru help` | ヘルプ表示 |

## 次のステップ

- シナリオを書きたい → [02. Scenario Layer](02-scenario-layer.md)
- ロジックを書きたい → [03. Logic Layer](03-logic-layer.md)
