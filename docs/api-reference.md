# neru API リファレンス

## CLI

### `neru compile <file>`

`.nerul` ファイルをバイトコード（`.neruc`）にコンパイルする。

```sh
$ neru compile script.nerul
compiled: script.nerul -> script.neruc
```

### `neru run <file>`

`.nerul` ファイルをコンパイルし、VM で即時実行する。最後の式の値を標準出力に表示する。

```sh
$ neru run script.nerul
55
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

### コメント

```
// 行コメント

/* ブロックコメント
   ネスト可能 /* 内側 */ */
```

---

## Zig ライブラリ API

neru は Zig ライブラリとしても利用可能。`@import("neru")` でインポートする。

### コンパイラパイプライン

```zig
const neru = @import("neru");
const std = @import("std");

// 1. 初期化
var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
defer arena.deinit();
const allocator = arena.allocator();

var diags = neru.compiler.diagnostic.DiagnosticList.init(allocator);
var nodes = neru.compiler.ast.NodeStore.init(allocator);

// 2. レキサー + パーサー
const source = "let x = 42\n";
var lexer = neru.compiler.lexer.Lexer.init(source, &diags);
var parser = neru.compiler.parser.Parser.init(allocator, &lexer, &nodes, &diags);
const root = try parser.parseProgram();

// 3. コードジェネレーション
var compiler = neru.compiler.codegen.Compiler.init(allocator, &nodes, &diags);
const module = try compiler.compile(root);

// 4. VM 実行
var vm = neru.vm.vm.VM.init(allocator);
vm.load(module);
const result = try vm.execute();
```

### 主要な型

#### `neru.compiler.lexer.Lexer`

```zig
fn init(source: []const u8, diagnostics: *DiagnosticList) Lexer
fn next(self: *Lexer) Token
```

#### `neru.compiler.parser.Parser`

```zig
fn init(allocator, lexer: *Lexer, nodes: *NodeStore, diagnostics: *DiagnosticList) Parser
fn parseProgram(self: *Parser) !NodeIndex
```

#### `neru.compiler.codegen.Compiler`

```zig
fn init(allocator, nodes: *const NodeStore, diagnostics: *DiagnosticList) Compiler
fn compile(self: *Compiler, program_idx: NodeIndex) !CompiledModule
fn deinit(self: *Compiler) void
```

#### `neru.compiler.codegen.CompiledModule`

```zig
fn serialize(self: *const CompiledModule, writer: anytype) !void
fn deserialize(data: []const u8, allocator) !CompiledModule
```

#### `neru.vm.vm.VM`

```zig
fn init(allocator) VM
fn load(self: *VM, module: CompiledModule) void
fn execute(self: *VM) VMError!?Value
fn currentSourceLine(self: *const VM) u32
fn deinit(self: *VM) void
```

#### `neru.vm.value.Value`

```zig
const Value = union(enum) {
    int: i64,
    float: f64,
    string: []const u8,
    bool_val: bool,
    null_val: void,
    function: u16,

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
| `0x20` | `add` | - | 加算 |
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
| `0x60` | `make_array` | u16 | 配列生成 |
| `0x61` | `make_map` | u16 | マップ生成 |
| `0x62` | `load_index` | - | インデックスアクセス |
| `0x63` | `store_index` | - | インデックス書き込み |
| `0x64` | `load_member` | u16 | メンバーアクセス |
| `0x65` | `store_member` | u16 | メンバー書き込み |
| `0xFF` | `halt` | - | 実行停止 |
