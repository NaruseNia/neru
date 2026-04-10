# neru

ノベルゲームエンジン [nerune-engine](https://github.com/NaruseNia/nerune-engine) 向けのスクリプト言語。

シナリオライターとプログラマーの両方が快適に開発できるよう、2層構造の言語設計を採用しています。

> **Warning**
> 本プロジェクトは開発中です。言語仕様や API は予告なく破壊的変更が入る可能性があります。**プロダクション環境での使用は推奨しません。**

## 特徴

- **シナリオ層** (`.neru`) — マークダウン拡張構文。プレーンテキストがそのままセリフになる
- **ロジック層** (`.nerul`) — 独自スクリプト言語。ゲームロジックを記述
- **バイトコードVM** — Zig で実装された高速な仮想マシン
- **疎結合設計** — エンジンに依存しない汎用的な中間表現を出力
- **国際化 (i18n)** — 多言語対応を言語レベルでサポート

## サンプル

### シナリオ (.neru)

```
@speaker 太郎
@bg 校庭.png --fade 500

「こんにちは、私の名前は{state.player_name}です」
「今日はいい天気だね」

#choice
  - 「そうだね」 -> good_route
  - 「そうかな？」 -> bad_route

# good_route
@eval state.affinity.taro += 5
「ありがとう！」

# bad_route
「そっか…」
```

### ロジック (.nerul)

```
fn give_item(item) {
  state.inventory.push(item)
  debug.log("Added: " + item)
}

fn check_affinity(char) {
  if state.affinity[char] >= 50 {
    return true
  }
  return false
}
```

## ドキュメント

- [要件定義書](docs/specification/requirements.md)
- [言語仕様書](docs/specification/language-spec.md)
- [アーキテクチャ設計書](docs/specification/architecture.md)
- [実装計画書](docs/specification/implementation-plan.md)
- [EBNF 文法定義](docs/specification/grammar.ebnf)

## ビルド

```sh
zig build
```

## ライセンス

[MIT](LICENSE)
