# neru

[![CI](https://github.com/NaruseNia/neru/actions/workflows/ci.yml/badge.svg)](https://github.com/NaruseNia/neru/actions/workflows/ci.yml)
[![Release](https://img.shields.io/github/v/release/NaruseNia/neru)](https://github.com/NaruseNia/neru/releases/latest)

ノベルゲームエンジン [nerune-engine](https://github.com/NaruseNia/nerune-engine) 向けのスクリプト言語。

シナリオライターとプログラマーの両方が快適に開発できるよう、2層構造の言語設計を採用しています。

> [!WARNING]
> 本プロジェクトは開発中です。言語仕様や API は予告なく破壊的変更が入る可能性があります。**プロダクション環境での使用は推奨しません。**

## クイックスタート

[Releases](https://github.com/NaruseNia/neru/releases/latest) から最新バイナリを取得:

```sh
# ロジックスクリプト
cat <<'EOF' > hello.nerul
fn fib(n) {
  if n <= 1 { return n }
  return fib(n - 1) + fib(n - 2)
}
let result = fib(10)
EOF

neru run hello.nerul
# => 55

# シナリオスクリプト — --mock で自動応答モックエンジンを起動
cat <<'EOF' > hello.neru
@speaker アリス
旅人さん、こんにちは。
@wait 500
今日はどちらへ?
EOF

neru run --mock hello.neru
# => [speaker] アリス
#    [text] アリス: 旅人さん、こんにちは。
#    [wait] 500ms
#    [text] アリス: 今日はどちらへ?

# バイトコードにコンパイル
neru compile hello.nerul
# => hello.neruc
```

実行可能なサンプルは [`examples/`](examples/README.md) にまとめてあります。

## 特徴

- **シナリオ層** (`.neru`) — テキスト行、`@speaker`/`@wait`/`@clear`、`@bg`/`@show`/`@bgm`/`@se`/`@transition` (`--key=value` オプション対応)、`#label` + `@goto`、条件付き項目を含む `#choice`、`@if`/`@elif`/`@else`/`@end`、`@call`/`@eval`、`{expression}` 変数展開
- **ロジック層** (`.nerul`) — 式、`let`、`fn`、`if`/`else`、`for`/`while`、`break`/`continue`、再帰、複合代入
- **バイトコード VM** — Zig 製のスタックベース仮想マシン。演出は直接実行せず、エンジン非依存のイベントとして発行
- **モックエンジン** — `neru run --mock` で、エンジン抜きでもスクリプトを end-to-end で動かして stdout にイベントを流せる
- **クロスプラットフォーム** — CI から Linux / macOS / Windows バイナリを配布

### これから実装する機能

- 配列、マップ、クロージャ、モジュール (Phase 3)
- `state` 管理、セーブ/ロード、マクロ、i18n (Phase 4)
- LSP、デバッガー、フォーマッター (Phase 5)

## サンプル

### シナリオ (`.neru`)

```
@bg forest.png --fade=slow
@bgm theme.ogg --volume=0.8
@show taro --pos=center

@speaker 太郎
森の中は静かだな。
@wait 500

#choice
  - "声をかける" -> call
  - "そのまま進む" -> silent
  - "隠しルート" -> secret @if 1 == 1

#call
@speaker 太郎
おーい!
@goto done

#silent
@speaker ナレーター
(太郎は黙って歩き続けた。)
@goto done

#secret
@speaker ナレーター
あなたは隠しルートを解放した。
@goto done

#done
@bgm_stop
```

### ロジック (`.nerul`)

```
fn factorial(n) {
  if n <= 1 { return 1 }
  return n * factorial(n - 1)
}

let x = factorial(5)  // 120

for i in 0..10 {
  // ループ本体
}

while x > 0 {
  x -= 1
}
```

## ソースからビルド

[Zig](https://ziglang.org/) 0.15.2+ が必要です。

```sh
zig build              # ビルド
zig build run          # ビルド＆CLI実行
zig build test         # 全テスト実行
```

## Zig ライブラリとして使用

### 依存追加

`build.zig.zon` に fetch:

```sh
zig fetch --save=neru git+https://github.com/NaruseNia/neru#v0.2.0
```

`build.zig` でモジュールを取り込み:

```zig
const neru_dep = b.dependency("neru", .{ .target = target, .optimize = optimize });
exe.root_module.addImport("neru", neru_dep.module("neru"));
```

### 利用例

```zig
const neru = @import("neru");

// コンパイル
var diags = neru.compiler.DiagnosticList.init(allocator);
var nodes = neru.compiler.NodeStore.init(allocator);
var lexer = neru.compiler.Lexer.init(source, &diags, .scenario); // .logic も可
var parser = neru.compiler.Parser.init(allocator, &lexer, &nodes, &diags);
const root = try parser.parseProgram();

var compiler = neru.compiler.Compiler.init(allocator, &nodes, &diags);
const module = try compiler.compile(root);

// イベント駆動で実行 (シナリオ向け)
var vm = neru.vm.VM.init(allocator);
defer vm.deinit();
vm.load(module);
while (try vm.runUntilEvent()) |event| {
    // event を処理して Response を返す
    vm.resumeWith(.{ .none = {} });
}
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
| 2. シナリオ層 | 完了 | テキスト表示、話者、演出命令、フロー制御、条件分岐、イベント |
| 3. ロジック層 | 予定 | 配列、マップ、クロージャ、モジュール |
| 4. 統合機能 | 予定 | State管理、セーブ/ロード、マクロ、i18n |
| 5. 開発者ツール | 予定 | LSP、デバッガー、フォーマッター |

## ライセンス

[MIT](LICENSE)
