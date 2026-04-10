# neru

[![CI](https://github.com/NaruseNia/neru/actions/workflows/ci.yml/badge.svg)](https://github.com/NaruseNia/neru/actions/workflows/ci.yml)
[![Release](https://img.shields.io/github/v/release/NaruseNia/neru)](https://github.com/NaruseNia/neru/releases/latest)

ノベルゲームエンジン [nerune-engine](https://github.com/NaruseNia/nerune-engine) 向けのスクリプト言語。

シナリオライターとプログラマーの両方が快適に開発できるよう、2層構造の言語設計を採用しています。

> [!WARNING]
> 本プロジェクトは開発中です。言語仕様や API は予告なく破壊的変更が入る可能性があります。**プロダクション環境での使用は推奨しません。**

## クイックスタート

[Releases](https://github.com/NaruseNia/neru/releases/latest) から最新のバイナリをダウンロード:

```sh
# スクリプトを書く
cat <<'EOF' > hello.nerul
fn fib(n) {
  if n <= 1 { return n }
  return fib(n - 1) + fib(n - 2)
}
let result = fib(10)
EOF

# 実行
neru run hello.nerul
# => 55

# バイトコードにコンパイル
neru compile hello.nerul
# => hello.neruc
```

## 特徴

- **シナリオ層** (`.neru`) — マークダウン拡張構文。プレーンテキストがそのままセリフになる *（Phase 2 で実装予定）*
- **ロジック層** (`.nerul`) — 独自スクリプト言語。ゲームロジックを記述
- **バイトコード VM** — Zig で実装されたスタックベース仮想マシン
- **疎結合設計** — エンジンに依存しない汎用的な中間表現を出力
- **国際化 (i18n)** — 多言語対応を言語レベルでサポート *（Phase 4 で実装予定）*
- **クロスプラットフォーム** — Linux / macOS / Windows バイナリを配布

## サンプル

### ロジック (.nerul) — 利用可能

```
let x = 42
let name = "neru"

fn factorial(n) {
  if n <= 1 { return 1 }
  return n * factorial(n - 1)
}

let result = factorial(5)  // 120

for i in 0..10 {
  // ループ本体
}

while x > 0 {
  x -= 1
}
```

### シナリオ (.neru) — Phase 2 で実装予定

```
@speaker 太郎
@bg 校庭.png --fade 500

「こんにちは、私の名前は{state.player_name}です」
「今日はいい天気だね」

#choice
  - 「そうだね」 -> good_route
  - 「そうかな？」 -> bad_route
```

## ソースからビルド

[Zig](https://ziglang.org/) 0.15.2+ が必要です。

```sh
zig build              # ビルド
zig build run          # ビルド＆CLI実行
zig build test         # 全テスト実行 (104テスト)
```

### Zig ライブラリとして使用

```zig
const neru = @import("neru");

var vm = neru.vm.VM.init(allocator);
var lexer = neru.compiler.Lexer.init(source, &diags);
var parser = neru.compiler.Parser.init(allocator, &lexer, &nodes, &diags);
// ...
```

## ドキュメント

- [API リファレンス](docs/api-reference.md)
- [言語仕様書](docs/specification/language-spec.md)
- [アーキテクチャ設計書](docs/specification/architecture.md)
- [実装計画書](docs/specification/implementation-plan.md)
- [EBNF 文法定義](docs/specification/grammar.ebnf)

## ロードマップ

| Phase | 状態 | 内容 |
|---|---|---|
| 1. コア基盤 | 完了 | Lexer, Parser, Codegen, VM, CLI |
| 2. シナリオ層 | 次 | テキスト表示、選択肢、演出命令、イベント |
| 3. ロジック層 | 予定 | 配列、マップ、クロージャ、モジュール |
| 4. 統合機能 | 予定 | State管理、セーブ/ロード、マクロ、i18n |
| 5. 開発者ツール | 予定 | LSP、デバッガー、フォーマッター |

## ライセンス

[MIT](LICENSE)
