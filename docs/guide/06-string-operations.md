# 06. String Operations

neru の文字列はダブルクオートで囲みます。UTF-8 エンコーディングです。

## 基本

```
let s = "Hello, World!"
let empty = ""
let escaped = "line1\nline2"
```

## 結合

`+` 演算子で文字列を結合します。

```
let first = "Hello"
let second = " World"
let greeting = first + second   // "Hello World"
```

## 比較

### 等値比較

```
"hello" == "hello"   // true
"hello" != "world"   // true
```

### 辞書順比較

```
"abc" < "abd"        // true
"xyz" >= "abc"       // true
"apple" < "banana"   // true
```

## メソッド一覧

| メソッド | 引数 | 戻り値 | 説明 |
|---|---|---|---|
| `len()` | - | int | 文字列のバイト長 |
| `upper()` | - | string | 大文字化 |
| `lower()` | - | string | 小文字化 |
| `contains(s)` | string | bool | 部分文字列の存在判定 |
| `replace(old, new)` | string, string | string | 置換 |
| `split(sep)` | string | array | 分割 |
| `trim()` | - | string | 前後の空白除去 |

## 使用例

### 大文字・小文字変換

```
let s = "Hello World"
s.upper()   // "HELLO WORLD"
s.lower()   // "hello world"
```

### 検索

```
let text = "The quick brown fox"
text.contains("quick")   // true
text.contains("slow")    // false
```

### 置換

```
let s = "Hello World"
s.replace("World", "neru")   // "Hello neru"
```

複数回出現する場合はすべて置換されます:

```
"aabaa".replace("a", "x")   // "xxbxx"
```

### 分割

```
let csv = "apple,banana,cherry"
let fruits = csv.split(",")
// fruits = ["apple", "banana", "cherry"]

fruits.len()    // 3
fruits[0]       // "apple"
```

### トリム

```
"  hello  ".trim()     // "hello"
"\t hi \n".trim()      // "hi"
```

## シナリオ内での文字列

シナリオ層では `{expr}` で任意の式を文字列に埋め込めます。非文字列値は自動的に文字列化されます。

```
// .neru ファイル内
@speaker Alice
My name is {name} and I am {age} years old.
Score: {score * 10} points
```

## 次のステップ

- 組み込みモジュール → [07. Built-in Modules](07-built-in-modules.md)
- モジュールシステム → [08. Module System](08-module-system.md)
