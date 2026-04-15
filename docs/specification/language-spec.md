# neru 言語仕様書

## 1. 概要

neru は2層構造のノベルゲーム用スクリプト言語である。

- **シナリオ層**: マークダウン拡張構文によるシナリオ記述
- **ロジック層**: 独自スクリプト言語によるゲームロジック記述

ファイル拡張子はシナリオ層 `.neru`、ロジック層 `.nerul` で分離する。パーサーは拡張子でモードを確定する。
シナリオファイル (`.neru`) 内ではインラインロジック（`@if`, `@call`, `@eval` 等）も使用可能。

---

## 2. 字句構造（Lexical Structure）

### 2.1 文字セット

- ソースコードは UTF-8 エンコーディング
- シナリオ層のテキストは全 Unicode 文字を許容

### 2.2 コメント

```
// 行コメント（両層共通）

/* ブロックコメント
   複数行にまたがる */
```

### 2.3 識別子

```
identifier = [a-zA-Z_][a-zA-Z0-9_]*
```

- Unicode 文字はシナリオ層のテキスト内でのみ使用可能
- 識別子は英数字とアンダースコアのみ

### 2.4 リテラル

| 型 | 例 |
|---|---|
| 整数 | `42`, `-1`, `0xFF` |
| 浮動小数点 | `3.14`, `-0.5` |
| 文字列 | `"hello"`, `"日本語"` |
| 真偽値 | `true`, `false` |
| null | `null` |

### 2.5 予約語

```
let fn if else for while return break continue
goto true false null state import from
```

---

## 3. シナリオ層仕様

### 3.1 テキスト表示

プレーンテキスト行はそのままテキスト表示命令として解釈される。

```
「こんにちは、世界」
ここに書いたテキストがそのまま表示される。
```

#### 3.1.1 変数展開

`{}` で囲むことで式を評価し、結果をテキストに埋め込む。

```
「私の名前は{state.player_name}です」
「HP: {state.hp} / {state.max_hp}」
```

### 3.2 命令（ディレクティブ）

`@` プレフィックスで命令を記述する。

```
@command [args...] [--option value]
```

#### 3.2.1 テキスト制御命令

| 命令 | 説明 | 例 |
|---|---|---|
| `@speaker` | 話者名設定 | `@speaker 太郎` |
| `@narrator` | ナレーター設定 | `@narrator` |
| `@wait` | ウェイト（ms） | `@wait 500` |
| `@clear` | テキストクリア | `@clear` |

#### 3.2.2 演出命令

| 命令 | 説明 | 例 |
|---|---|---|
| `@bg` | 背景変更 | `@bg 校庭.png --fade 500` |
| `@show` | 立ち絵表示 | `@show taro smile --pos center` |
| `@hide` | 立ち絵非表示 | `@hide taro --fade 300` |
| `@bgm` | BGM 再生 | `@bgm morning.ogg --loop` |
| `@bgm_stop` | BGM 停止 | `@bgm_stop --fade 1000` |
| `@se` | 効果音再生 | `@se click.ogg` |
| `@transition` | トランジション | `@transition fade --duration 500` |

#### 3.2.3 フロー制御命令

| 命令 | 説明 | 例 |
|---|---|---|
| `@goto` | ラベルへ移動 | `@goto ending_a` |
| `@jump` | ファイル間ジャンプ | `@jump chapter2.neru#start` |
| `@call` | 関数呼び出し | `@call give_item("sword")` |
| `@eval` | 式の評価 | `@eval state.hp -= 10` |

#### 3.2.4 条件分岐命令

```
@if state.flags.met_taro
  「また会ったね」
@elif state.chapter > 3
  「初めまして…かな？」
@else
  「誰？」
@end
```

### 3.3 ラベル

`#` プレフィックスでラベルを定義する。ジャンプ先として使用。

```
# prologue
「物語の始まり…」

# chapter1_start
「第一章」
```

### 3.4 選択肢

`#choice` ブロックで選択肢を定義する。

```
#choice
  - 「はい」 -> yes_route
  - 「いいえ」 -> no_route
  - 「わからない」 -> confused_route
```

#### 3.4.1 条件付き選択肢

```
#choice
  - 「告白する」 -> confess @if state.affinity.taro >= 80
  - 「友達でいよう」 -> friend
  - 「さよなら」 -> goodbye
```

### 3.5 マクロ定義

```
@macro macro_name(param1, param2, ...)
  // マクロ本体（シナリオ命令）
@end
```

使用:

```
@macro_name arg1 arg2
```

例:

```
@macro enter(name, emotion)
  @speaker {name}
  @show {name} {emotion} --fade 300
@end

@enter "太郎" "smile"
「こんにちは！」
```

---

## 4. ロジック層仕様

### 4.1 変数

```
let x = 42
let name = "太郎"
let items = ["sword", "shield"]
let stats = { "hp": 100, "mp": 50 }
```

- `let` で変数を宣言
- 動的型付け（実行時に型を判定）
- 再代入可能

### 4.2 データ型

| 型名 | 説明 | 例 |
|---|---|---|
| `int` | 整数 | `42` |
| `float` | 浮動小数点 | `3.14` |
| `str` | 文字列 | `"hello"` |
| `bool` | 真偽値 | `true`, `false` |
| `null` | null値 | `null` |
| `array` | 配列 | `[1, 2, 3]` |
| `map` | マップ | `{"key": "value"}` |

### 4.3 演算子

#### 4.3.1 算術演算子

```
+   -   *   /   %
+=  -=  *=  /=  %=
```

#### 4.3.2 比較演算子

```
==  !=  <  >  <=  >=
```

#### 4.3.3 論理演算子

```
&&  ||  !
```

#### 4.3.4 文字列結合

```
let greeting = "Hello, " + name + "!"
```

### 4.4 制御構文

#### 4.4.1 条件分岐

```
if condition {
  // ...
} else if condition {
  // ...
} else {
  // ...
}
```

#### 4.4.2 for ループ

```
for item in items {
  // ...
}

for i in 0..10 {
  // ...
}
```

#### 4.4.3 while ループ

```
while condition {
  // ...
}
```

#### 4.4.4 break / continue

```
for item in items {
  if item == "key" {
    break
  }
  continue
}
```

### 4.5 関数

```
fn function_name(param1, param2) {
  // 関数本体
  return value
}
```

例:

```
fn calculate_damage(base, defense) {
  let damage = base - defense
  if damage < 0 {
    return 0
  }
  return damage
}
```

#### 4.5.1 ファーストクラス関数

関数は値として扱える。変数への代入、引数としての受け渡し、関数からの返却が可能。

```
fn double(n) { return n * 2 }

let f = double       // 変数に代入
let result = f(21)   // 変数経由で呼び出し

fn apply(func, x) {  // 引数として受け取り
  return func(x)
}
apply(double, 5)     // 関数を渡す
```

#### 4.5.2 クロージャ

関数は定義時のスコープの変数をキャプチャできる。

```
fn make_adder(x) {
  fn adder(y) {
    return x + y    // 外側スコープの x をキャプチャ
  }
  return adder
}

let add5 = make_adder(5)
add5(10)  // => 15
```

#### 4.5.3 可変長引数（将来拡張）

将来的に `...` 構文で可変長引数をサポート予定。設計方針:

```
fn log(level, ...messages) {
  for msg in messages {
    debug.log(level + ": " + msg)
  }
}

log("INFO", "start", "processing")
```

- `...param` は最後の仮引数にのみ使用可能
- `param` は配列として関数本体内でアクセスされる
- 通常の引数と混在可能（可変長部分は末尾に限定）
- スプレッド演算子 `...arr` で配列を展開して渡すことも検討

### 4.6 配列操作

```
let items = ["sword", "shield"]
items.push("potion")       // 末尾追加
items.pop()                // 末尾削除
let length = items.len()   // 長さ取得
let has = items.contains("sword")  // 含有判定
```

### 4.7 マップ操作

```
let stats = {"hp": 100, "mp": 50}
stats["str"] = 30          // キー追加
stats.remove("mp")         // キー削除
let keys = stats.keys()    // キー一覧
let has = stats.has("hp")  // キー存在判定
```

---

## 5. state オブジェクト

### 5.1 概要

`state` はグローバルな組み込みオブジェクトで、ゲーム状態を管理する。
セーブ/ロード時に自動的に永続化される。

### 5.2 アクセス

```
// ロジック層
state.affinity.taro = 0
state.flags.met_taro = true
state.inventory = ["key"]

// シナリオ層
@if state.flags.met_taro
  「また会ったね」
@end

「好感度: {state.affinity.taro}」
```

### 5.3 自動初期化

未定義の state パスにアクセスした場合、中間オブジェクトが自動生成される。

```
// state.affinity が未定義でもエラーにならない
state.affinity.taro = 50  // 自動的に中間マップが生成される
```

---

## 6. モジュールシステム

### 6.1 import

ロジックファイルの関数や定数を他のファイルから利用可能。

```
@import give_item from "logic/items.nerul"
@import * from "logic/game.nerul"
```

### 6.2 export

ロジックファイル内で定義された `fn` はデフォルトでエクスポートされる。
プライベート関数は `_` プレフィックスで示す。

```
fn public_function() {   // 外部から利用可能
  _helper()
}

fn _helper() {           // プライベート
  // ...
}
```

---

## 7. 国際化（i18n）

### 7.1 テキストキー方式

```
// locales/ja.neru
@locale ja
@text greeting = "こんにちは"
@text farewell = "さようなら"

// locales/en.neru
@locale en
@text greeting = "Hello"
@text farewell = "Goodbye"
```

### 7.2 シナリオでの使用

```
@speaker 太郎
@t greeting
@t farewell
```

### 7.3 ロケール設定

```toml
# neru.toml
[i18n]
default = "ja"
locales = ["ja", "en", "zh"]
path = "locales/"
```

---

## 8. 組み込み関数

### 8.1 文字列操作

| 関数 | 説明 |
|---|---|
| `str.len()` | 文字列長 |
| `str.upper()` | 大文字化 |
| `str.lower()` | 小文字化 |
| `str.contains(s)` | 部分文字列判定 |
| `str.replace(old, new)` | 置換 |
| `str.split(sep)` | 分割 |
| `str.trim()` | 前後空白除去 |

### 8.2 数学

| 関数 | 説明 |
|---|---|
| `math.abs(n)` | 絶対値 |
| `math.min(a, b)` | 最小値 |
| `math.max(a, b)` | 最大値 |
| `math.random(min, max)` | 乱数生成 |
| `math.floor(n)` | 切り捨て |
| `math.ceil(n)` | 切り上げ |

### 8.3 デバッグ

| 関数 | 説明 |
|---|---|
| `debug.log(msg)` | デバッグログ出力 |
| `debug.dump(value)` | 値のダンプ |
| `debug.assert(cond, msg)` | アサーション |
