# 05. Functions & Closures

neru の関数はファーストクラスオブジェクトです。変数に代入したり、引数として渡したり、関数から返すことができます。

## ファーストクラス関数

### 変数に代入

```
fn double(n) {
  return n * 2
}

let f = double
let result = f(21)   // 42
```

### 引数として渡す

```
fn apply(func, value) {
  return func(value)
}

fn square(n) { return n * n }
fn negate(n) { return -n }

apply(square, 5)     // 25
apply(negate, 3)     // -3
```

### 関数を返す

```
fn get_operation(name) {
  fn add(a, b) { return a + b }
  fn sub(a, b) { return a - b }

  if name == "add" { return add }
  return sub
}

let op = get_operation("add")
op(10, 3)   // 13
```

## クロージャ

内側の関数は、外側の関数のスコープにある変数をキャプチャできます。

```
fn make_counter(start) {
  let count = start
  fn next() {
    count = count + 1
    return count
  }
  return next
}

let counter = make_counter(0)
counter()   // 1
counter()   // 2
counter()   // 3
```

### 複数の変数をキャプチャ

```
fn make_range_checker(min, max) {
  fn check(value) {
    return value >= min && value <= max
  }
  return check
}

let is_teen = make_range_checker(13, 19)
is_teen(15)    // true
is_teen(25)    // false
```

### ファクトリーパターン

同じファクトリーから異なるクロージャを生成:

```
fn make_multiplier(factor) {
  fn mul(n) {
    return n * factor
  }
  return mul
}

let double = make_multiplier(2)
let triple = make_multiplier(3)

double(5)   // 10
triple(5)   // 15
```

## 高階関数の実用例

### map 風の処理

```
fn transform(arr, func) {
  let result = []
  for item in arr {
    result.push(func(item))
  }
  return result
}

let numbers = [1, 2, 3, 4, 5]
let doubled = transform(numbers, make_multiplier(2))
// doubled = [2, 4, 6, 8, 10]
```

### filter 風の処理

```
fn select(arr, predicate) {
  let result = []
  for item in arr {
    if predicate(item) {
      result.push(item)
    }
  }
  return result
}

fn is_positive(n) { return n > 0 }
let filtered = select([-1, 2, -3, 4, 5], is_positive)
// filtered = [2, 4, 5]
```

## 次のステップ

- 文字列操作 → [06. String Operations](06-string-operations.md)
- 組み込みモジュール → [07. Built-in Modules](07-built-in-modules.md)
