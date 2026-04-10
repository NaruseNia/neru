# neru アーキテクチャ設計書

## 1. システム全体構成

```
┌─────────────────────────────────────────────────────┐
│                    開発者ツール                        │
│  ┌─────────┐  ┌─────────┐  ┌──────────────┐         │
│  │   CLI   │  │   LSP   │  │  デバッガー    │         │
│  └────┬────┘  └────┬────┘  └──────┬───────┘         │
│       │            │              │                   │
├───────┴────────────┴──────────────┴───────────────────┤
│                  neru コンパイラ                        │
│  ┌─────────┐  ┌─────────┐  ┌──────────────┐         │
│  │ レキサー  │→│ パーサー  │→│ コードジェネ   │         │
│  │ (Lexer) │  │(Parser) │  │  レーター     │         │
│  └─────────┘  └─────────┘  └──────┬───────┘         │
│                                    │                  │
│                              ┌─────▼─────┐           │
│                              │バイトコード │           │
│                              │  (.neruc)  │           │
│                              └─────┬─────┘           │
├────────────────────────────────────┼──────────────────┤
│                  neru VM           │                  │
│                              ┌─────▼─────┐           │
│  ┌──────────┐               │   VM Core  │           │
│  │  state   │◄─────────────►│  (実行器)   │           │
│  │  管理    │               └─────┬─────┘           │
│  └──────────┘                     │                  │
│                              ┌─────▼─────┐           │
│                              │ 命令出力    │           │
│                              │(IR/Events) │           │
│                              └─────┬─────┘           │
├────────────────────────────────────┼──────────────────┤
│              nerune-engine         │                  │
│                              ┌─────▼─────┐           │
│  ┌──────────┐               │ 命令解釈    │           │
│  │   wgpu   │◄──────────────│ (Executor) │           │
│  │ レンダラ  │               └───────────┘           │
│  └──────────┘                                        │
└─────────────────────────────────────────────────────┘
```

---

## 2. コンパイラパイプライン

### 2.1 レキサー (Lexer / Tokenizer)

**入力**: .neru / .nerul ソースコード（UTF-8）
**出力**: トークンストリーム

#### 2.1.1 トークン種別

```
// シナリオ層トークン
TEXT            // プレーンテキスト行
DIRECTIVE       // @command
LABEL           // #label
CHOICE_BLOCK    // #choice
INTERPOLATION   // {expression}

// ロジック層トークン
LET, FN, IF, ELSE, ELIF, FOR, WHILE, RETURN
BREAK, CONTINUE, GOTO, TRUE, FALSE, NULL
STATE, IMPORT, FROM

// リテラル
INT_LITERAL, FLOAT_LITERAL, STRING_LITERAL

// 演算子
PLUS, MINUS, STAR, SLASH, PERCENT
EQ, NEQ, LT, GT, LTE, GTE
AND, OR, NOT
ASSIGN, PLUS_ASSIGN, MINUS_ASSIGN, ...

// 構造
LPAREN, RPAREN, LBRACE, RBRACE, LBRACKET, RBRACKET
COMMA, DOT, ARROW, COLON, SEMICOLON

// 特殊
NEWLINE, INDENT, DEDENT, EOF, COMMENT
```

#### 2.1.2 モード切替

レキサーはファイル拡張子と文脈に応じて2つのモードを持つ:

- **シナリオモード**: `.neru` ファイルのデフォルト。テキスト行を `TEXT` トークンとして扱う
- **ロジックモード**: `.nerul` ファイルのデフォルト。また `.neru` ファイル内でも `@eval`/`@call`の引数、`{}`ブロック内で一時的に切り替わる

### 2.2 パーサー (Parser)

**入力**: トークンストリーム
**出力**: AST (Abstract Syntax Tree)

#### 2.2.1 AST ノード種別

```
// トップレベル
Program
  - ScenarioBlock
  - LogicBlock

// シナリオ
TextNode          // テキスト表示
DirectiveNode     // @command
LabelNode         // #label
ChoiceNode        // #choice ブロック
MacroDefNode      // @macro 定義
MacroCallNode     // @macro_name 呼び出し
ConditionalNode   // @if/@elif/@else/@end
ImportNode        // @import

// ロジック
LetStatement      // let x = ...
FnDeclaration     // fn name() { ... }
IfStatement       // if/else
ForStatement      // for
WhileStatement    // while
ReturnStatement   // return
AssignStatement   // x = ...
ExprStatement     // expression;
BinaryExpr        // a + b
UnaryExpr         // !a, -a
CallExpr          // func()
IndexExpr         // arr[0]
MemberExpr        // obj.field
LiteralExpr       // 42, "str", true
ArrayExpr         // [1, 2, 3]
MapExpr           // {"key": "value"}
InterpolationExpr // {expr} in text
```

### 2.3 セマンティック解析

- 未定義ラベルの検出
- 未定義関数呼び出しの検出
- import 先ファイルの存在確認
- マクロ引数の数の検証
- 到達不能コードの警告

### 2.4 バイトコードジェネレーター

**入力**: AST
**出力**: バイトコード (.neruc)

#### 2.4.1 命令セット（主要）

```
// スタック操作
PUSH_CONST index     // 定数プール値をスタックに積む
PUSH_NULL            // null をスタックに積む
POP                  // スタックトップを破棄

// 変数操作
LOAD_LOCAL slot      // ローカル変数を読み込み
STORE_LOCAL slot     // ローカル変数に格納
LOAD_STATE           // state オブジェクト参照
LOAD_MEMBER name     // メンバアクセス
STORE_MEMBER name    // メンバ書き込み
LOAD_INDEX           // インデックスアクセス
STORE_INDEX          // インデックス書き込み

// 算術・比較
ADD, SUB, MUL, DIV, MOD
EQ, NEQ, LT, GT, LTE, GTE
AND, OR, NOT, NEG

// 制御フロー
JUMP offset          // 無条件ジャンプ
JUMP_IF offset       // 条件付きジャンプ
JUMP_IF_NOT offset   // 条件付きジャンプ（否定）
CALL func_id argc    // 関数呼び出し
RETURN               // 関数から戻る

// シナリオ命令
EMIT_TEXT text_id    // テキスト表示
EMIT_DIRECTIVE cmd   // 演出命令発行
EMIT_CHOICE choice_id // 選択肢表示
EMIT_WAIT ms         // ウェイト

// データ構造
MAKE_ARRAY count     // 配列生成
MAKE_MAP count       // マップ生成
```

#### 2.4.2 バイトコードフォーマット (.neruc)

```
Header:
  magic: [4]u8 = "NERU"
  version: u16
  flags: u16

Sections:
  [Constant Pool]    // 文字列・数値リテラル
  [Function Table]   // 関数定義テーブル
  [Label Table]      // ラベル→オフセットマッピング
  [Text Table]       // テキストリソース（i18n対応）
  [Bytecode]         // 命令列
  [Debug Info]       // ソースマップ（行番号対応）
```

---

## 3. VM アーキテクチャ

### 3.1 概要

スタックベースの仮想マシン。

```
┌──────────────────────────┐
│         VM Core          │
│  ┌────────────────────┐  │
│  │  Instruction       │  │
│  │  Pointer (IP)      │  │
│  └────────────────────┘  │
│  ┌────────────────────┐  │
│  │  Operand Stack     │  │
│  └────────────────────┘  │
│  ┌────────────────────┐  │
│  │  Call Stack         │  │
│  │  (Frame Stack)     │  │
│  └────────────────────┘  │
│  ┌────────────────────┐  │
│  │  State Store       │  │
│  └────────────────────┘  │
│  ┌────────────────────┐  │
│  │  Event Queue       │  │
│  │  (→ Engine)        │  │
│  └────────────────────┘  │
└──────────────────────────┘
```

### 3.2 実行サイクル

```
1. IP からバイトコード命令をフェッチ
2. 命令をデコード
3. 命令を実行
   - スタック操作
   - 変数読み書き
   - 演出命令の Event Queue への発行
4. IP を進める
5. Event Queue にイベントがあればエンジンに通知
6. エンジンからの応答（選択肢結果等）を待機
7. 1 に戻る
```

### 3.3 コールスタック

```
CallFrame:
  function_id: u32      // 現在の関数
  ip: u32               // 戻りアドレス
  base_pointer: u32     // ローカル変数のベース
  local_count: u16      // ローカル変数数
```

### 3.4 イベントシステム（エンジン連携）

VM は演出命令を直接実行せず、イベントとしてキューに発行する。

```
Event:
  type: EventType
  data: EventData

EventType:
  TEXT_DISPLAY        // テキスト表示
  SPEAKER_CHANGE      // 話者変更
  BG_CHANGE           // 背景変更
  SPRITE_SHOW         // 立ち絵表示
  SPRITE_HIDE         // 立ち絵非表示
  BGM_PLAY            // BGM再生
  BGM_STOP            // BGM停止
  SE_PLAY             // SE再生
  TRANSITION          // トランジション
  CHOICE_PROMPT       // 選択肢表示
  WAIT                // ウェイト
  SAVE_POINT          // セーブポイント
```

---

## 4. エンジン連携（疎結合インターフェース）

### 4.1 VM ↔ Engine インターフェース

```
// neru VM が提供するインターフェース
NeruVM:
  fn load(bytecode: []u8) -> void
  fn step() -> ?Event           // 1命令実行、イベントがあれば返す
  fn run_until_event() -> Event // イベント発生まで実行
  fn resume(response: Response) -> void  // エンジンからの応答で再開
  fn get_state() -> State       // 現在のstate取得（セーブ用）
  fn set_state(state: State) -> void     // state復元（ロード用）

// エンジンが VM に返す応答
Response:
  CHOICE_SELECTED(index: u32)   // 選択肢結果
  TEXT_ACKNOWLEDGED              // テキスト送り
  WAIT_COMPLETED                 // ウェイト完了
```

### 4.2 シーケンス例

```
Engine                    VM
  │                        │
  │   load(bytecode)       │
  │──────────────────────►│
  │                        │
  │   run_until_event()    │
  │──────────────────────►│
  │                        │──── 命令実行
  │   Event::TEXT_DISPLAY  │
  │◄──────────────────────│
  │                        │
  │   (テキスト表示)        │
  │                        │
  │   resume(TEXT_ACK)     │
  │──────────────────────►│
  │                        │──── 命令実行
  │   Event::CHOICE_PROMPT │
  │◄──────────────────────│
  │                        │
  │   (選択肢表示)          │
  │                        │
  │   resume(CHOICE(1))    │
  │──────────────────────►│
  │                        │──── 分岐処理
  │         ...            │
```

---

## 5. State 管理

### 5.1 データ構造

state は内部的にネストされたマップとして実装する。

```
StateStore:
  root: Map<String, Value>

Value:
  Int(i64)
  Float(f64)
  Str(String)
  Bool(bool)
  Null
  Array([]Value)
  Map(Map<String, Value>)
```

### 5.2 永続化（セーブ / ロード）

- シリアライズ: state をバイナリまたは JSON 形式にシリアライズ
- デシリアライズ: バイナリ/JSON から state を復元
- セーブデータには state + VM の実行位置（IP, コールスタック）を含む

```
SaveData:
  version: u32
  state: SerializedState
  vm_state:
    current_file: String
    ip: u32
    call_stack: []CallFrame
  metadata:
    timestamp: u64
    chapter: String
    thumbnail: ?[]u8
```

---

## 6. インタプリタモード

### 6.1 概要

開発時の迅速なイテレーション用に、バイトコードコンパイルを経ずに AST を直接実行するモードを提供する。

### 6.2 AST ウォーカー

```
ASTInterpreter:
  fn visit(node: ASTNode) -> Value
  fn visit_text(node: TextNode) -> void
  fn visit_directive(node: DirectiveNode) -> void
  fn visit_if(node: IfStatement) -> void
  fn visit_for(node: ForStatement) -> void
  fn visit_fn_call(node: CallExpr) -> Value
  ...
```

### 6.3 用途

- `neru run` コマンドでのスクリプト実行
- ホットリロード時の差分実行
- REPL（将来的に）

---

## 7. ツールチェーン

### 7.1 CLI

```
neru compile <file.neru>          # バイトコードコンパイル
neru run <file.neru>              # インタプリタ実行
neru build                        # プロジェクトビルド
neru check                        # 静的解析のみ
neru fmt <file.neru>              # フォーマッター（将来）
```

### 7.2 LSP (Language Server Protocol)

- テキストドキュメント同期
- シンタックスハイライト（TextMate grammar）
- 補完（命令名、ラベル名、state パス、関数名）
- ホバー情報
- 定義ジャンプ（ラベル、関数）
- リファレンス検索
- エラー/警告のリアルタイム表示

### 7.3 デバッガー

- DAP (Debug Adapter Protocol) 準拠
- ブレークポイント（行番号、ラベル名）
- ステップ実行（ステップイン、ステップオーバー、ステップアウト）
- 変数ウォッチ（ローカル変数、state）
- コールスタック表示
- 条件付きブレークポイント
