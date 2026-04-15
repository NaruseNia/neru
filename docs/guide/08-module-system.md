# 08. Module System

neru のモジュールシステムを使うと、関数を複数ファイルに分割して管理できます。

## 基本的な使い方

### 名前付きインポート

特定の関数だけをインポートします。

```
// math_utils.nerul
fn add(a, b) {
  return a + b
}

fn multiply(a, b) {
  return a * b
}
```

```
// main.nerul
@import add from "math_utils.nerul"

let result = add(10, 20)   // 30
```

### ワイルドカードインポート

ファイル内のすべてのパブリック関数をインポートします。

```
// main.nerul
@import * from "math_utils.nerul"

let sum = add(10, 20)       // 30
let product = multiply(3, 4) // 12
```

## パスの解決

インポートパスは、インポート元ファイルのディレクトリからの相対パスで解決されます。

```
project/
  main.nerul          ← @import add from "lib/math.nerul"
  lib/
    math.nerul        ← ここが読み込まれる
    string_utils.nerul
```

```
// project/main.nerul
@import add from "lib/math.nerul"

// project/lib/math.nerul
@import trim from "string_utils.nerul"   // lib/ 内の相対パス
```

## プライベート関数

`_` (アンダースコア) で始まる関数はプライベートです。他のファイルからインポートできません。

```
// utils.nerul
fn public_func() {
  return _helper() * 2
}

fn _helper() {
  return 21
}
```

```
// main.nerul
@import * from "utils.nerul"

public_func()    // 42 — OK
// _helper()     // エラー: インポートされない
```

## 循環インポートの検出

ファイル A が B をインポートし、B が A をインポートするような循環参照はコンパイルエラーになります。

```
// a.nerul
@import foo from "b.nerul"   // エラー: circular import detected

// b.nerul
@import bar from "a.nerul"
```

## 実用例: ゲームロジックの分割

```
project/
  main.neru
  logic/
    combat.nerul
    items.nerul
    characters.nerul
```

```
// logic/items.nerul
fn give_item(inventory, item_name) {
  if !inventory.contains(item_name) {
    inventory.push(item_name)
  }
}

fn has_item(inventory, item_name) {
  return inventory.contains(item_name)
}

fn _validate_item(name) {
  return name.len() > 0
}
```

```
// logic/combat.nerul
fn calculate_damage(attacker, defender) {
  let base = attacker["atk"] - defender["def"]
  return math.max(base, 1)
}
```

```
// main.neru (シナリオ層からもインポート可能)
@import give_item from "logic/items.nerul"
@import calculate_damage from "logic/combat.nerul"

@eval give_item(inventory, "sword")

@if has_sword
  剣を手に入れた！
@end
```

## 設計ガイドライン

1. **1ファイル1責務**: 関連する関数をまとめ、ファイル名で内容がわかるようにする
2. **プライベート関数を活用**: 内部実装の詳細は `_` プレフィックスで隠蔽する
3. **名前付きインポート推奨**: `*` より明示的に関数名を指定した方が依存関係が明確になる
4. **循環参照を避ける**: 共通の処理は別ファイルに切り出す
