# neru API リファレンス

## CLI

### `neru compile <file>`

`.nerul` / `.neru` ファイルをバイトコード（`.neruc`）にコンパイルする。

```sh
$ neru compile script.nerul
compiled: script.nerul -> script.neruc
```

### `neru run [--mock] <file>`

ファイルをコンパイルし VM で即時実行する。

- 拡張子が `.neru` ならシナリオモードで、`.nerul` ならロジックモードでレキサーを起動する。
- `--mock` を付けると組み込みモックエンジンがイベント駆動で実行を進め、各イベントを `stdout` に表示する。テキストは即 ack、選択肢は最初の `visible` を選び、ウェイトは即完了扱い。
- 指定なしの場合はロジックスクリプト向けに `execute()` で一気に完了させ、最後の式の値を出力する。

```sh
$ neru run script.nerul
55

$ neru run --mock script.neru
[speaker] Alice
[text] Alice: Hello.
...
```

### `neru help`

使用方法を表示する。

---

## 言語構文（ロジック層 `.nerul`）

### 変数宣言

```
let x = 42
let name = "neru"
let flag = true
let nothing = null
let pi = 3.14
```

### 代入

```
x = 10
x += 5      // x = x + 5
x -= 3      // x = x - 3
x *= 2      // x = x * 2
x /= 4      // x = x / 4
x %= 3      // x = x % 3
```

### データ型

| 型 | 例 | 説明 |
|---|---|---|
| `int` | `42`, `0xFF`, `0b1010` | 64bit 整数 |
| `float` | `3.14`, `0.5` | 64bit 浮動小数点 |
| `string` | `"hello"` | UTF-8 文字列 |
| `bool` | `true`, `false` | 真偽値 |
| `null` | `null` | null 値 |

### 演算子

```
// 算術
+  -  *  /  %

// 比較
==  !=  <  >  <=  >=

// 論理
&&  ||  !

// 範囲（for ループ用）
..
```

**型昇格**: `int + float` → `float`。整数同士の除算は切り捨て。

### 条件分岐

```
if x > 0 {
  // ...
} else if x < 0 {
  // ...
} else {
  // ...
}
```

### ループ

```
// 範囲 for
for i in 0..10 {
  // i = 0, 1, 2, ..., 9
}

// 配列 for-in
let items = ["a", "b", "c"]
for item in items {
  debug.log(item)
}

// while
while condition {
  // ...
  break       // ループを抜ける
  continue    // 次のイテレーションへ
}
```

### 関数

```
fn add(a, b) {
  return a + b
}

let result = add(10, 20)   // 30
```

再帰呼び出しも可能:

```
fn factorial(n) {
  if n <= 1 {
    return 1
  }
  return n * factorial(n - 1)
}
```

### ファーストクラス関数・クロージャ

```
// 変数に代入
let f = add
f(10, 20)   // 30

// 関数を引数に渡す
fn apply(func, x) { return func(x) }

// クロージャ
fn make_adder(x) {
  fn adder(y) { return x + y }
  return adder
}
let add5 = make_adder(5)
add5(10)   // 15
```

### データ構造

```
// 配列
let arr = [1, 2, 3]
arr.push(4)           // 末尾追加
arr.pop()             // 末尾削除
arr.len()             // 長さ
arr.contains(2)       // 含有判定
arr[0]                // インデックスアクセス

// マップ
let m = {"hp": 100, "mp": 50}
m["str"] = 30         // キー追加
m.remove("mp")        // キー削除
m.keys()              // キー一覧
m.has("hp")           // キー存在判定
m.len()               // エントリ数
```

### 文字列操作

```
let s = "Hello World"
s.len()                          // 11
s.upper()                        // "HELLO WORLD"
s.lower()                        // "hello world"
s.contains("World")              // true
s.replace("World", "Zig")        // "Hello Zig"
s.split(" ")                     // ["Hello", "World"]
"  hello  ".trim()               // "hello"
"abc" + "def"                    // "abcdef" (結合)
"abc" < "abd"                    // true (辞書順比較)
```

### 組み込みモジュール

```
// math
math.abs(-42)          // 42
math.min(3, 7)         // 3
math.max(3, 7)         // 7
math.floor(3.7)        // 3
math.ceil(3.2)         // 4
math.random(1, 10)     // 1〜10 のランダム整数

// debug
debug.log("message")   // stderr にログ出力
debug.dump(value)       // 型情報付きダンプ
debug.assert(cond)      // false なら RuntimeError
debug.assert(cond, "msg")
```

### モジュールシステム

```
// 名前付きインポート
@import add from "lib/math.nerul"

// ワイルドカードインポート
@import * from "lib/utils.nerul"
```

`_` プレフィックスの関数はプライベート（インポート不可）。

### コメント

```
// 行コメント

/* ブロックコメント
   ネスト可能 /* 内側 */ */
```

---

## 言語構文（シナリオ層 `.neru`）

### テキスト行と補間

行頭が `@` / `#` / `-` 以外なら、その行はテキストとして `emit_text` される。テキスト中の `{expr}` は実行時に評価され、非文字列は自動的に文字列へ coerce される (`to_str` オペコード経由)。

```
これは地の文です。
名前は {name} です。
```

### 話者 / 待機 / クリア

```
@speaker Alice               // 以降の emit_text に speaker=Alice が乗る
@speaker "Student A"         // スペースを含む話者は文字列で指定
@wait 500                    // 500ms ウェイトイベント
@clear                       // テキスト表示をクリア
```

### 演出命令 (media directive)

位置引数 1 つと、任意個の `--key=value` オプション。値は `int` / `float` / `string` / `ident` (シンボル扱い) / `bool`。

```
@bg forest.png --fade=slow --duration=500
@show taro --pos=center
@hide taro
@bgm theme.ogg --volume=0.8
@bgm_stop
@se door.wav
@transition wipe --direction=left
```

`forest.png` のようにドットを含むパスはクオート無しで書ける。スペースを含むパスは `"..."` でクオートする。

### ラベル / ジャンプ / 選択肢

```
#start
@speaker Narrator
You stand at a crossroads.

#choice
  - "Go left" -> left
  - "Go right" -> right
  - "Secret route" -> secret @if 1 == 1

#left
@goto end
#right
@goto end
#secret
@goto end
#end
```

- `#label` は行頭のジャンプ先定義。
- `@goto identifier` は同一ファイル内ラベルへの無条件ジャンプ。
- `#choice` 直後に `- "テキスト" -> target [@if cond]` の項目を並べる。`@if` が false の項目は event の `visible=false` として渡り、`--mock` では hidden として扱われる。
- `@jump path [#label]` は構文のみ受理。実行時は停止し警告を出す (Phase 3.6 でモジュールシステムと合わせて完成予定)。

### 条件分岐

```
@if state.active
  Active path.
@elif state.idle
  Idle path.
@else
  Fallback.
@end
```

### ロジック呼び出し / 式評価

```
@call play_fanfare()    // ロジック関数を呼び出す (結果は捨てる)
@eval 1 + 2             // 式を評価して捨てる (副作用のため)
```

---

## ランタイムイベント

VM はシナリオを実行すると、演出を直接行う代わりに `Event` をエンジンへ渡して停止する。エンジンは `Response` を添えて `resumeWith()` を呼び、次のイベントまで再開させる。

### `neru.runtime.Event`

```zig
pub const Event = union(EventTag) {
    text_display: TextDisplay,
    text_clear: void,
    speaker_change: SpeakerChange,
    bg_change: BgChange,
    sprite_show: SpriteShow,
    sprite_hide: SpriteHide,
    bgm_play: BgmPlay,
    bgm_stop: void,
    se_play: SePlay,
    transition: Transition,
    choice_prompt: ChoicePrompt,
    wait: Wait,
    save_point: SavePoint,
};
```

主要ペイロード:

```zig
pub const TextDisplay = struct { speaker: ?[]const u8, text: []const u8 };
pub const ChoiceOption = struct {
    label: []const u8,
    target: []const u8,
    visible: bool = true,
};
pub const ChoicePrompt = struct { options: []const ChoiceOption };
pub const Wait = struct { ms: u32 };
```

### `neru.runtime.Response`

```zig
pub const Response = union(enum) {
    none: void,
    text_ack: void,
    wait_completed: void,
    choice_selected: u32,
};
```

`choice_selected` は元の項目インデックス (非表示項目も含む) で返す。VM はそれを使って `emit_choice` に埋め込まれたジャンプテーブルからジャンプ先を決める。

---

## Zig ライブラリ API

### 依存の追加

```sh
zig fetch --save=neru git+https://github.com/NaruseNia/neru#v0.2.0
```

`build.zig`:

```zig
const neru_dep = b.dependency("neru", .{ .target = target, .optimize = optimize });
exe.root_module.addImport("neru", neru_dep.module("neru"));
```

バレルから主要な型へアクセスできる:

```zig
const neru = @import("neru");

// 推奨: 直接アクセス
const VM = neru.vm.VM;
const Lexer = neru.compiler.Lexer;
const Event = neru.runtime.Event;
const Response = neru.runtime.Response;

// 詳細なサブモジュールも利用可能
const opcodes = neru.vm.opcodes;
const token = neru.compiler.token;
const event_mod = neru.runtime.event;
```

### コンパイラパイプライン (ロジック)

```zig
const neru = @import("neru");
const std = @import("std");

var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
defer arena.deinit();
const allocator = arena.allocator();

var diags = neru.compiler.DiagnosticList.init(allocator);
var nodes = neru.compiler.NodeStore.init(allocator);

const source = "let x = 42\n";
var lexer = neru.compiler.Lexer.init(source, &diags, .logic);
var parser = neru.compiler.Parser.init(allocator, &lexer, &nodes, &diags);
const root = try parser.parseProgram();

var compiler = neru.compiler.Compiler.init(allocator, &nodes, &diags);
const module = try compiler.compile(root);

var vm = neru.vm.VM.init(allocator);
defer vm.deinit();
vm.load(module);
const result = try vm.execute();
```

### コンパイラパイプライン (シナリオ + イベント駆動)

```zig
// .neru ファイルはシナリオモードで
var lexer = neru.compiler.Lexer.init(source, &diags, .scenario);
// パース / コンパイルは同じ

var vm = neru.vm.VM.init(allocator);
defer vm.deinit();
vm.load(module);

while (try vm.runUntilEvent()) |event| {
    switch (event) {
        .text_display => |td| renderText(td.speaker, td.text),
        .choice_prompt => |cp| {
            const idx = askUser(cp.options);
            vm.resumeWith(.{ .choice_selected = idx });
            continue;
        },
        .wait => |w| {
            sleepMs(w.ms);
            vm.resumeWith(.{ .wait_completed = {} });
            continue;
        },
        else => {},
    }
    vm.resumeWith(.{ .none = {} });
}
```

### 主要な型

#### `neru.compiler.Lexer`

```zig
pub const Mode = enum { logic, scenario,
    pub fn fromPath(path: []const u8) Mode,
};

fn init(source: []const u8, diagnostics: *DiagnosticList, initial_mode: Mode) Lexer
fn next(self: *Lexer) Token
```

**Phase 2 以降は `initial_mode` が必須**。ファイルパスから自動判定するなら `Mode.fromPath(path)` を使う。

#### `neru.compiler.Parser`

```zig
fn init(allocator, lexer: *Lexer, nodes: *NodeStore, diagnostics: *DiagnosticList) Parser
fn parseProgram(self: *Parser) !NodeIndex
```

#### `neru.compiler.Compiler`

```zig
fn init(allocator, nodes: *const NodeStore, diagnostics: *DiagnosticList) Compiler
fn compile(self: *Compiler, program_idx: NodeIndex) !CompiledModule
fn deinit(self: *Compiler) void
```

#### `neru.compiler.CompiledModule`

```zig
fn serialize(self: *const CompiledModule, writer: anytype) !void
fn deserialize(data: []const u8, allocator) !CompiledModule
```

#### `neru.vm.VM`

```zig
fn init(allocator) VM
fn load(self: *VM, module: CompiledModule) void
fn deinit(self: *VM) void

// イベント駆動 API (推奨)
fn runUntilEvent(self: *VM) VMError!?Event
fn resumeWith(self: *VM, response: Response) void

// ロジックのみのスクリプト用: 実行完了まで run して最終値を返す
fn execute(self: *VM) VMError!?Value

fn currentSourceLine(self: *const VM) u32
```

`runUntilEvent` が返す `Event` は VM 所有のメモリを指すスライスを含む。次の `runUntilEvent` / `resumeWith` 呼び出しで無効化される。

#### `neru.vm.Value`

```zig
const Value = union(enum) {
    int: i64,
    float: f64,
    string: []const u8,
    bool_val: bool,
    null_val: void,
    function: u16,
    closure: *ClosureHandle,
    array: *ArrayHandle,
    map: *MapHandle,

    fn isTruthy(self: Value) bool
    fn eql(self: Value, other: Value) bool
    fn formatValue(self: Value, writer: anytype) !void
    fn typeName(self: Value) []const u8
};
```

---

## バイトコードフォーマット (.neruc)

### ヘッダー

| オフセット | サイズ | 内容 |
|---|---|---|
| 0 | 4 | マジック: `"NERU"` |
| 4 | 2 | バージョン (u16 LE) |
| 6 | 2 | フラグ (u16 LE) |

### セクション

ヘッダーの後に以下のセクションが順に配置される:

1. **定数プール**: `count(u32)` + エントリ列
   - `0x01` + `i64`: 整数
   - `0x02` + `u64`: 浮動小数点 (bitcast)
   - `0x03` + `len(u32)` + bytes: 文字列

2. **関数テーブル**: `count(u32)` + エントリ列
   - `name_idx(u16)` + `arity(u8)` + `offset(u32)` + `local_count(u16)`

3. **バイトコード**: `length(u32)` + 命令列

4. **デバッグ情報**: `count(u32)` + エントリ列
   - `bytecode_offset(u32)` + `source_line(u32)`

### オペコード一覧

| コード | 名前 | オペランド | 説明 |
|---|---|---|---|
| `0x01` | `push_const` | u16 | 定数プールの値をプッシュ |
| `0x02` | `push_null` | - | null をプッシュ |
| `0x03` | `push_true` | - | true をプッシュ |
| `0x04` | `push_false` | - | false をプッシュ |
| `0x05` | `pop` | - | TOS を破棄 |
| `0x10` | `load_local` | u16 | ローカル変数を読み込み |
| `0x11` | `store_local` | u16 | ローカル変数に格納 |
| `0x20` | `add` | - | 加算 (文字列は連結) |
| `0x21` | `sub` | - | 減算 |
| `0x22` | `mul` | - | 乗算 |
| `0x23` | `div` | - | 除算 |
| `0x24` | `mod` | - | 剰余 |
| `0x25` | `neg` | - | 符号反転 |
| `0x30` | `eq` | - | 等価比較 |
| `0x31` | `neq` | - | 非等価比較 |
| `0x32` | `lt` | - | 小なり |
| `0x33` | `gt` | - | 大なり |
| `0x34` | `lte` | - | 以下 |
| `0x35` | `gte` | - | 以上 |
| `0x40` | `op_and` | - | 論理 AND |
| `0x41` | `op_or` | - | 論理 OR |
| `0x42` | `op_not` | - | 論理 NOT |
| `0x50` | `jump` | i32 | 無条件ジャンプ (相対) |
| `0x51` | `jump_if` | i32 | 真ならジャンプ |
| `0x52` | `jump_if_not` | i32 | 偽ならジャンプ |
| `0x53` | `call` | u16 + u8 | 関数呼び出し (func_id, argc) |
| `0x54` | `ret` | - | 関数から復帰 |
| `0x55` | `call_value` | u8 | スタック上の関数値を呼び出し (argc) |
| `0x56` | `push_function` | u16 | 関数値をプッシュ (func_id) |
| `0x57` | `make_closure` | u16 + u16 | クロージャ生成 (func_id, upvalue_count) |
| `0x58` | `load_upvalue` | u16 | upvalue 読み込み |
| `0x59` | `store_upvalue` | u16 | upvalue 書き込み |
| `0x60` | `make_array` | u16 | 配列生成 |
| `0x61` | `make_map` | u16 | マップ生成 |
| `0x62` | `load_index` | - | インデックスアクセス |
| `0x63` | `store_index` | - | インデックス書き込み |
| `0x64` | `load_member` | u16 | メンバーアクセス |
| `0x65` | `store_member` | u16 | メンバー書き込み |
| `0x66` | `call_method` | u16 + u8 | メソッド呼び出し (name_idx, argc) |
| `0x90` | `call_builtin` | u16 + u8 | 組み込み関数呼び出し (name_idx, argc) |
| `0x70` | `emit_text` | - | TextDisplay イベント発行、一時停止。stack: `[speaker_or_null, text]` |
| `0x71` | `emit_speaker` | - | SpeakerChange イベント発行。stack: `[speaker_or_null]` |
| `0x72` | `emit_wait` | u32 | Wait イベント発行 (ms 即値) |
| `0x73` | `emit_save_point` | - | SavePoint イベント。stack: `[name]` |
| `0x74` | `emit_directive` | u8 + u8 | DirectiveKind + arg_count。primary + 引数ペアを stack から pop |
| `0x75` | `emit_choice` | u8 + N×i32 | count + count 個のジャンプオフセット。stack: 各項目 `[visible, label, target]` |
| `0x76` | `emit_text_clear` | - | TextClear イベント |
| `0x80` | `to_str` | - | TOS の値を文字列へ coerce |
| `0xFF` | `halt` | - | 実行停止 |
