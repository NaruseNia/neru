# 03. Logic Layer Basics

ロジック層 (`.nerul`) はゲームロジックを記述するための構文です。動的型付け、関数、ループなどをサポートします。

## 変数

`let` で変数を宣言します。再代入可能です。

```
let x = 42
let name = "neru"
let flag = true
let nothing = null
let pi = 3.14
```

## データ型

| 型 | 例 | 説明 |
|---|---|---|
| `int` | `42`, `0xFF`, `0b1010` | 64bit 整数 |
| `float` | `3.14`, `0.5` | 64bit 浮動小数点 |
| `string` | `"hello"` | UTF-8 文字列 |
| `bool` | `true`, `false` | 真偽値 |
| `null` | `null` | null 値 |
| `array` | `[1, 2, 3]` | 配列 |
| `map` | `{"key": "val"}` | マップ |
| `function` | `fn(x) { ... }` | 関数値 |

## 演算子

### 算術

```
10 + 3    // 13
10 - 3    // 7
10 * 3    // 30
10 / 3    // 3  (整数同士は切り捨て)
10 % 3    // 1
```

`int + float` は `float` に昇格します。

### 比較

```
==  !=  <  >  <=  >=
```

文字列の比較は辞書順です。

### 論理

```
&&  ||  !
```

### 代入

```
x = 10
x += 5    // x = x + 5
x -= 3
x *= 2
x /= 4
x %= 3
```

## 条件分岐

```
if score >= 90 {
  debug.log("excellent")
} else if score >= 60 {
  debug.log("good")
} else {
  debug.log("try again")
}
```

## ループ

### 範囲 for

```
for i in 0..10 {
  // i = 0, 1, 2, ..., 9
}
```

### 配列 for-in

```
let items = ["sword", "shield", "potion"]
for item in items {
  debug.log(item)
}
```

### while

```
let count = 0
while count < 10 {
  count += 1
}
```

### break / continue

```
for i in 0..100 {
  if i == 50 {
    break       // ループを抜ける
  }
  if i % 2 == 0 {
    continue    // 次のイテレーションへスキップ
  }
  // 奇数のみ処理
}
```

ネストしたループでは、`break`/`continue` は最も内側のループに作用します。

## 関数

```
fn greet(name) {
  return "Hello, " + name + "!"
}

let msg = greet("World")  // "Hello, World!"
```

### 暗黙の return

関数の末尾に `return` がない場合、`null` が返ります。

### 再帰

```
fn factorial(n) {
  if n <= 1 { return 1 }
  return n * factorial(n - 1)
}
```

## コメント

```
// 行コメント

/* ブロックコメント
   複数行にまたがる */
```

## 次のステップ

- 配列・マップを使う → [04. Data Structures](04-data-structures.md)
- 高度な関数の使い方 → [05. Functions & Closures](05-functions-advanced.md)
