# 07. Built-in Modules

neru には `math` と `debug` の2つの組み込みモジュールがあります。インポート不要で直接使えます。

## math

数学関連のユーティリティ関数です。

### math.abs(n)

絶対値を返します。int / float の両方に対応。

```
math.abs(-42)      // 42
math.abs(42)       // 42
math.abs(-3.14)    // 3.14
```

### math.min(a, b)

2値のうち小さい方を返します。

```
math.min(10, 3)    // 3
math.min(-5, 0)    // -5
```

### math.max(a, b)

2値のうち大きい方を返します。

```
math.max(10, 3)    // 10
math.max(-5, 0)    // 0
```

### math.floor(n)

小数点以下を切り捨てて整数にします。整数を渡した場合はそのまま返します。

```
math.floor(3.7)    // 3
math.floor(-1.2)   // -2
math.floor(5)      // 5
```

### math.ceil(n)

小数点以下を切り上げて整数にします。

```
math.ceil(3.2)     // 4
math.ceil(-1.8)    // -1
math.ceil(5)       // 5
```

### math.random(min, max)

min 以上 max 以下のランダムな整数を返します。

```
let dice = math.random(1, 6)
let damage = math.random(10, 30)
```

### 実用例: ダメージ計算

```
fn calculate_damage(base, defense) {
  let raw = base - defense
  let damage = math.max(raw, 1)             // 最低1ダメージ
  let variance = math.random(-3, 3)          // ブレ
  return math.max(damage + variance, 0)
}
```

## debug

開発・デバッグ用のユーティリティです。出力は標準エラー出力 (stderr) に送られます。

### debug.log(value)

値をログ出力します。戻り値は `null`。

```
debug.log("checkpoint reached")
debug.log(42)
debug.log(player_stats)
```

出力例:
```
[debug] checkpoint reached
[debug] 42
[debug] {"hp": 100, "mp": 50}
```

### debug.dump(value)

型情報付きで値をダンプします。

```
debug.dump(42)
debug.dump("hello")
debug.dump([1, 2, 3])
```

出力例:
```
[dump] type=int value=42
[dump] type=string value=hello
[dump] type=array value=[1, 2, 3]
```

### debug.assert(condition [, message])

条件が false の場合、実行を中断して RuntimeError を発生させます。

```
debug.assert(hp > 0)
debug.assert(items.len() > 0, "inventory is empty")
```

メッセージ付きの場合、stderr に出力されます:
```
[assert] inventory is empty
```

### 実用例: テスト的な利用

```
fn test_add() {
  debug.assert(1 + 1 == 2, "basic addition failed")
  debug.assert(0 + 0 == 0, "zero addition failed")
  debug.log("test_add passed")
}

test_add()
```

## 次のステップ

- モジュールシステム → [08. Module System](08-module-system.md)
