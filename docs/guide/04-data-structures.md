# 04. Data Structures

neru は配列とマップの2つのコレクション型を提供します。

## 配列

### 作成

```
let empty = []
let numbers = [1, 2, 3]
let mixed = [42, "hello", true, null]
```

### インデックスアクセス

```
let arr = [10, 20, 30]
let first = arr[0]    // 10
let last = arr[2]     // 30

arr[1] = 99           // 書き換え
```

### メソッド

| メソッド | 説明 | 例 |
|---|---|---|
| `push(val)` | 末尾に追加 | `arr.push(4)` |
| `pop()` | 末尾を取り出し | `let v = arr.pop()` |
| `len()` | 要素数 | `arr.len()` |
| `contains(val)` | 値が含まれるか | `arr.contains(2)` |

### 配列イテレーション

```
let items = ["sword", "shield", "potion"]

for item in items {
  debug.log(item)
}
```

### 例: アイテム管理

```
let inventory = []

fn add_item(name) {
  if !inventory.contains(name) {
    inventory.push(name)
  }
}

fn remove_item(name) {
  let new_inv = []
  for item in inventory {
    if item != name {
      new_inv.push(item)
    }
  }
  inventory = new_inv
}

add_item("sword")
add_item("shield")
add_item("sword")       // 重複なので追加されない
debug.log(inventory.len())  // 2
```

## マップ

### 作成

```
let empty = {}
let stats = {"hp": 100, "mp": 50, "str": 30}
```

### アクセス

```
// ブラケット記法
let hp = stats["hp"]
stats["def"] = 20

// ドット記法
let mp = stats.mp
```

### メソッド

| メソッド | 説明 | 例 |
|---|---|---|
| `has(key)` | キーが存在するか | `stats.has("hp")` |
| `remove(key)` | キーを削除 | `stats.remove("mp")` |
| `keys()` | キー一覧（配列） | `let k = stats.keys()` |
| `len()` | エントリ数 | `stats.len()` |

### 例: キャラクターステータス

```
fn create_character(name, hp, mp) {
  return {"name": name, "hp": hp, "mp": mp, "level": 1}
}

fn level_up(char) {
  char["level"] = char["level"] + 1
  char["hp"] = char["hp"] + 10
  char["mp"] = char["mp"] + 5
}

let hero = create_character("Taro", 100, 50)
level_up(hero)
debug.log(hero["level"])  // 2
debug.log(hero["hp"])     // 110
```

## ネスト

配列とマップは自由にネストできます。

```
let party = [
  {"name": "Taro", "hp": 100},
  {"name": "Hana", "hp": 80}
]

let first_name = party[0]["name"]  // "Taro"
```

## 次のステップ

- 関数とクロージャ → [05. Functions & Closures](05-functions-advanced.md)
- 文字列操作 → [06. String Operations](06-string-operations.md)
