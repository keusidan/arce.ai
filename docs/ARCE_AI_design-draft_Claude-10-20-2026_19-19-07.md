# ARCE.AI 機能拡張 設計草案

- 作成日：2026-10-20
- 対象：`keusidan/arce.ai`（Flutter版 v0.4.0）
- 位置づけ：実装前の草案。決定済み事項と未確定事項を分けて記載する

## 1. 方針（決定済み）

1. **UIデザインは現行の ARCE.AI のまま**。`theme.dart` のトークンを維持し、新しい画面は既存のボトムシート・一覧パターンで作る
2. **ローカル推論とクラウドモデルを両方メインとして扱う**。どちらも第一級のプロバイダで、特別扱いしない。会話単位・メッセージ単位で切り替えられる
3. **チャット履歴は LLM 専用のデータベースに保存する**（現行のJSONファイル保存から移行）
4. **送信前にプロンプトをプレビューできるようにする**

## 2. 組み込む機能

| # | 機能 | 概要 |
|---|---|---|
| 1 | 複数プロバイダ | クラウド各社（OpenAI / Anthropic / Google 互換）とローカルを同一の抽象で扱う。API/URL/モデルは自由設定 |
| 2 | 送信前プロンプトプレビュー | 実際にモデルへ渡る内容・推定トークン・送信ペイロードを送信前に確認 |
| 3 | マルチモーダル入力 | 画像・テキスト文書・PDF・Docx |
| 4 | Markdown描画 | コードハイライト・LaTeX・表・図 |
| 5 | 検索 | 複数プロバイダの切り替えと失敗時のフォールバック |
| 6 | MCP | 外部ツールサーバーへの接続（SSE / Streamable HTTP） |
| 7 | Skills | ディレクトリ単位の手順書を読み込んでツールとして使う |
| 8 | エージェント編集 | 名前・アイコン・システムプロンプト・許可ツール・使用モデルをユーザーが定義 |
| 9 | ファイルベースメモリ | Markdownファイル群として保持し、ツールから読み書き |
| 10 | プロンプト変数 | モデル名・現在時刻・ユーザー名などの差し込み |
| 11 | キャラクターカード取込 | カード画像またはJSONからエージェントを作成 |
| 12 | 設定のQR共有 | プロバイダ設定をQRで書き出し／読み込み（秘密情報は含めない） |
| 13 | カスタムHTTPヘッダー／ボディ | プロバイダごとにリクエストを上書き |
| 14 | メディア生成 | 画像・動画の生成ジョブ投入とポーリング |
| 15 | AI翻訳 | 選択テキストの翻訳 |
| 16 | 音声 | 読み上げ（TTS）と音声入力（STT） |
| 17 | エージェント環境 | proot ベースの永続シェル環境 |
| 18 | Web access | 同一ネットワークからブラウザで利用 |

## 3. アーキテクチャ

```
lib/
  core/          既存（chat_controller, agents, prompt, tool_runtime, sandbox, toolchain）
  ai/            ← 新規：プロバイダ抽象と正規化
    provider.dart     AiProvider / ProviderCapabilities
    delta.dart        text・reasoning・tool_call・usage の統一流
    transport.dart    HTTP、プロバイダ別ヘッダー/ボディ上書き
    assembler.dart    プロンプト組み立て（送信とプレビューで共用）
    adapters/         openai / anthropic / google / local
    registry.dart     プロバイダ台帳（保存・QR・資格情報の参照）
  data/          ← 新規：LLM専用DB
    llm_db.dart       スキーマとDAO
    legacy_import.dart 既存JSON履歴の一度きり移行
  features/      markdown / document / search / mcp / skills / memory / mediagen / speech / agents / webhost
  platform/      Android ブリッジ（sandbox, workspace）
```

中核は次の2点。

- **`AiProvider` に能力を申告させ、UIはフラグだけ見る**。プロバイダ追加時に画面を触らなくて済む
- **ツール呼び出し戦略を分離する**。ローカルは文法でJSONを書かせる方式、クラウドは各社のネイティブな関数呼び出し。`ToolCallingStrategy` を2実装にして既存パイプラインに合流させる（既存のローカル経路を壊さないため）

## 4. チャット履歴の保存（LLM専用DB）

### 4.1 なぜDBにするか

1. 1メッセージが複数パート（本文・思考・画像・ツール往復）を持つ
2. メッセージ単位でトークン数とコストを残したい
3. 会話を横断して検索したい
4. 生成中に部分更新が頻発する
5. 破損時に復旧できる余地を残したい（WAL）

**設定・プロバイダ定義・APIキーはこのDBに入れない**（従来どおり設定JSONとセキュアストレージ）。DBは会話データ専用の `arce_llm.db`。

### 4.2 スキーマ（drift / SQLite）

```sql
PRAGMA journal_mode = WAL;

CREATE TABLE conversations (
  id          TEXT PRIMARY KEY,        -- UUIDv7（時系列順）
  title       TEXT NOT NULL,
  agent_id    TEXT NOT NULL,
  provider_id TEXT NOT NULL,           -- 'local' または追加したプロバイダ
  model_id    TEXT NOT NULL,
  created_at  INTEGER NOT NULL,
  updated_at  INTEGER NOT NULL,
  archived    INTEGER NOT NULL DEFAULT 0,
  pinned      INTEGER NOT NULL DEFAULT 0
);

CREATE TABLE messages (
  id                TEXT PRIMARY KEY,
  conversation_id   TEXT NOT NULL REFERENCES conversations(id) ON DELETE CASCADE,
  seq               INTEGER NOT NULL,
  role              TEXT NOT NULL,     -- system / user / assistant / tool
  agent_id          TEXT,              -- 生成時のエージェント（遡及用）
  provider_id       TEXT, model_id TEXT,
  created_at        INTEGER NOT NULL,
  finish_reason     TEXT,              -- stop / length / cancelled / error
  error_text        TEXT,
  prompt_tokens     INTEGER, completion_tokens INTEGER, cost_micros INTEGER,
  UNIQUE(conversation_id, seq)
);

CREATE TABLE parts (
  id           TEXT PRIMARY KEY,
  message_id   TEXT NOT NULL REFERENCES messages(id) ON DELETE CASCADE,
  seq          INTEGER NOT NULL,
  kind         TEXT NOT NULL,          -- text|reasoning|image|document|tool_call|tool_result|artifact
  text         TEXT,
  asset_id     TEXT REFERENCES assets(id),
  tool_call_id TEXT, tool_name TEXT,
  payload      TEXT,                   -- JSON（引数・結果の詳細）
  UNIQUE(message_id, seq)
);

CREATE TABLE assets (
  id              TEXT PRIMARY KEY,
  conversation_id TEXT REFERENCES conversations(id) ON DELETE SET NULL,
  rel_path        TEXT NOT NULL,       -- 実体はファイル、DBはメタのみ
  mime            TEXT NOT NULL,
  byte_size       INTEGER NOT NULL,
  sha256          TEXT NOT NULL,
  created_at      INTEGER NOT NULL
);

CREATE VIRTUAL TABLE messages_fts USING fts5(body, tokenize='trigram');
CREATE INDEX idx_messages_conv ON messages(conversation_id, seq);
CREATE INDEX idx_parts_msg     ON parts(message_id, seq);
CREATE INDEX idx_conv_updated ON conversations(updated_at DESC);
```

- 検索は `trigram` トークナイザを使う（日本語の部分一致が効く）
- 画像・PDFの実体はファイルに置き、DBはメタだけ持つ（DBを軽く保つ）

### 4.3 書き込み方針

- 送信時：`messages` と `parts` を1トランザクションで確定。`seq` は `MAX(seq)+1` を同一トランザクション内で採番
- 生成中：本文はメモリ上で伸ばし、**500ms間隔でドラフトを upsert**。落ちても直前までが残る
- 削除：`archived` による論理削除。完全削除時は `assets` のファイルもGC

### 4.4 移行・入出力

- 既存のJSON履歴は初回起動時に一度だけ取り込む（`legacy_import` フラグで冪等化）
- 会話単位／全件の Markdown・JSON 書き出し。バックアップはDBと `assets` のzip

### 4.5 検証

`drift` は純Dartで動くため、`NativeDatabase.memory()` でインメモリのテストが書ける。スキーマ・採番・移行・検索を実際に検証する。生成コード（`*.g.dart`）はコミットし、CIにコード生成を挟まない方針とする。

## 5. 新機能：送信前プロンプトプレビュー

### 目的

- ローカルとクラウドが混在するため、**いま何がモデルに渡るか**を保証する
- コンテキスト肥大の原因（システムプロンプト・ツール定義・履歴）を可視化する
- クラウド利用時に、外部へ出る内容を最終確認できる

### 入口

- 入力欄の目アイコン（送信ボタンの隣）
- 長押しで「プレビューして送信」
- 詳細設定 > 回答 > 「送信前に必ず確認する」

### 画面（ボトムシート・3タブ）

| タブ | 内容 |
|---|---|
| 概要 | エージェント／プロバイダ／モデル／有効なツール／添付／推定トークンの内訳（システム・ツール定義・履歴・今回の入力）／コンテキスト上限に対する割合／「端末内」か「外部送信」かの表示 |
| プロンプト | 実際に渡る文字列をそのまま。制御用ブロックを強調。コピー可 |
| 送信ペイロード | POSTするJSON。認証情報はマスク。コピー可 |

### 実装の要

```dart
class PromptAssembler {
  PromptAssembly build({required Agent agent, required List<Message> history,
                        required UserInput input, required List<ToolDefinition> tools});
}

abstract interface class AiProvider {
  Object buildRequest(PromptAssembly assembly);  // タブ3はこの戻り値
  Stream<Delta> stream(PromptAssembly assembly);
}
```

**プレビューと本送信が同一の `PromptAssembler` と `buildRequest()` を通る**構造にする。ここを別実装にすると必ず乖離するため、単一の経路を強制する。

- プレビューは開いた時点のスナップショット。時刻変数や添付が変われば送信時に差分を警告
- 生成中は開けない
- トークン推定は概算であることを画面に明記（ローカルはトークナイザ、クラウドは近似）

### 非目標

- プレビュー画面からの編集は入れない（「プレビュー＝送信内容」の保証が崩れるため）。将来「上書きして送る」を別機能として設計する

## 6. フェーズ

| Phase | 内容 | 完了条件 |
|---|---|---|
| **P0 データ基盤** | LLM専用DB、既存JSONからの移行、横断検索、書き出し | 会話がDBに保存され、検索と移行のテストが緑 |
| **P1 プロバイダ基盤** | `AiProvider` 抽象、Delta正規化、OpenAI互換、ローカルのラップ、両方メインの切替、ツール戦略の分離 | ローカルとクラウドで同じ会話が動く |
| **P2 プロンプト基盤** | 組み立ての一本化、**プレビュー** | プレビューと実送信のペイロード一致テストが緑 |
| **P3 会話品質** | マルチモーダル入力、Markdown強化、プロンプト変数 | 画像・PDFを投げて要約できる |
| **P4 外部連携** | 検索プロバイダ、MCP、Skills | 外部ツールサーバーを繋いでツールが呼べる |
| **P5 パーソナライズ** | エージェント編集、メモリ、カード取込、QR、カスタムヘッダー | エージェントを自作して保存できる |
| **P6 生成系** | メディア生成、翻訳、音声 | 生成物が Artifacts に出る |
| **P7 環境** | エージェント環境（proot）、Web access | シェルツールが動く |

各フェーズのゲートは `dart analyze` / `flutter test` / CI のAPKビルド。

## 7. 未確定事項

1. proot 環境の rootfs を同梱するか初回ダウンロードにするか
2. Web access を Flutter Web 同梱にするか、軽量UIを自作するか
3. トークン推定の精度（ローカルはトークナイザ、クラウドは近似で許容するか）
4. メモリ機能をファイルのままにするか、DB内のテーブルに持つか
