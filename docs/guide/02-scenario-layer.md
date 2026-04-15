# 02. Scenario Layer

シナリオ層 (`.neru`) はビジュアルノベルのテキスト・演出・分岐を記述するための構文です。

## テキスト表示

行頭が特殊文字 (`@`, `#`, `-`) でない行は、そのままテキストとして表示されます。

```
これはそのまま画面に表示されるテキストです。
複数行を書くと、それぞれ別のテキスト表示イベントになります。
```

### 変数展開

`{}` で式を埋め込めます。

```
名前は {player_name} です。
HP: {hp} / {max_hp}
残り {100 - progress}%
```

## 話者設定

```
@speaker Alice
こんにちは！

@speaker "Student A"
よろしくお願いします。

@speaker Narrator
```

`@speaker` 以降のテキスト行には自動的にその話者が設定されます。スペースを含む名前はダブルクオートで囲みます。

## 演出命令

`@` プレフィックスで演出を指示します。エンジンへイベントとして送信され、エンジン側で処理されます。

### 背景・立ち絵

```
@bg forest.png --fade=500
@show taro smile --pos=center
@hide taro --fade=300
```

### BGM・効果音

```
@bgm morning.ogg --loop --volume=0.8
@bgm_stop --fade=1000
@se click.ogg
```

### トランジション

```
@transition fade --duration=500
```

### ウェイト・クリア

```
@wait 500
@clear
```

## ラベルとジャンプ

`#` で名前付きラベルを定義し、`@goto` でジャンプします。

```
#start
物語の始まり...

@goto chapter1

#chapter1
第一章が始まった。
```

## 選択肢

`#choice` ブロックで選択肢を定義します。各項目は `->` でジャンプ先を指定します。

```
#choice
  - "はい" -> yes_route
  - "いいえ" -> no_route

#yes_route
よい返事だ。
@goto end

#no_route
残念。
@goto end

#end
```

### 条件付き選択肢

`@if` で表示条件を付けられます。条件が false の場合、選択肢は非表示になります。

```
#choice
  - "告白する" -> confess @if affinity >= 80
  - "友達でいよう" -> friend
  - "さよなら" -> goodbye
```

## 条件分岐

テキストやディレクティブを条件で切り替えられます。

```
@if has_key
  鍵を使ってドアを開けた。
@elif strength > 10
  力ずくでドアを壊した。
@else
  ドアは開かない...
@end
```

## ロジック呼び出し

シナリオ内からロジック層の関数や式を利用できます。

```
@call give_item("sword")
@eval score += 10
```

## 次のステップ

- ゲームロジックを書く → [03. Logic Layer](03-logic-layer.md)
- データ構造を使う → [04. Data Structures](04-data-structures.md)
