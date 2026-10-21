# 次にやること（2026-10-21 時点の引き継ぎ）

v0.7.0 の状態：設定が「一覧 → 詳細」に分かれた／下のバーは4つ／MCP は1台ぶんだけ／
プロバイダは1つだけ／設定ツールは `get_settings` と `update_settings`。

以下は**未実装**。上から順に、1つずつ CI を通してから次へ進む（まとめて入れると切り分けが壊れる）。

## 1. プロバイダを複数、1プロバイダにモデルを複数

いま：`ProviderStore` が単一の設定を持ち、モデル名も1つ。

- `lib/ai/provider_config.dart`：`ProviderConfig` に `models: List<ModelConfig>` を足す
  （`ModelConfig { id, name, params: {temperature, topP, maxTokens, ...}, prompt }`）。
  `provider_configs` を `List<ProviderConfig>` として保存する形に変える（`settings.v1` とは別キーに）。
- `lib/services/provider_store.dart`：`active`（いま使うプロバイダ）と `activeModel` を持ち、
  追加・削除・並べ替えを提供。既存の単一設定は**読み込み時に1件へ移行**して捨てない。
- `lib/ui/provider_widgets.dart`：一覧（＋で追加、長押しで削除）→ 詳細（種類・APIキー・URL・ヘッダー）
  → モデル一覧（取得ボタンで `/models` を読み、選択して追加。パラメータはモデル詳細で編集）。
- `lib/ai/openai_compatible.dart`：`AiRequest` にモデル名が入るようにする（いまは provider 固定）。
  呼び出し側（`CloudEngine`）は「いま選ばれているモデル」を渡す。
- テスト：`test/ai/provider_config_test.dart` に複数モデルの往復と移行を足す。

## 2. MCP サーバーを複数

いま：`AppSettings.mcpUrl` / `mcpEnabled` ＋ secure storage の `mcp_token` が1組だけ。

- 設定を `mcpServers: [{id, name, url, enabled, approveWrites}]` の配列にする
  （`settings.v1` に配列として保存）。トークンは `mcp_token_<id>` で secure storage に。
- `lib/mcp/mcp_tools.dart`：1台ではなく配列を受け取り、ツール名を `mcp_<serverId>__<tool>` にする
  （いまは `mcp_` だけ）。名前に `__` を含むサーバー id は作らせない。
- 設定画面：MCP 一覧（＋で追加）→ 詳細（名前・URL・トークン・有効化・ツール一覧・接続確認）。
- 読み込みは**プロバイダごとの結果をキャッシュ**（毎ターン全サーバーへ `tools/list` しない）。
  失敗したサーバーはそのターンだけ外す（既存の挙動をサーバー単位に）。

## 3. バックグラウンド実行

いま：生成はアプリが前面にある間だけ。画面を離れるとタイマーも止まる。

- Android：`android/app/src/main/.../service/GenerationService.kt` を足す（フォアグラウンドサービス、
  通知チャンネル `generation`、`FOREGROUND_SERVICE_DATA_SYNC` 権限、通知に「停止」）。
  `MANIFEST` に `<service android:foregroundServiceType="dataSync">`。
- Dart：`ChatController` はストリームを流すだけなので、`AppController` 側で
  「生成開始で `startForeground`、終了で `stopForeground`」を呼ぶだけにする（`MethodChannel('ai.arce.app/system')` に追加）。
- MCP 呼び出し中も同じ扱い（`ToolRuntime.run` の前後で開始/終了）。
- 落とし穴：Doze で HTTP が切れる → 既存の再試行（`RetryPolicy`）に任せ、通知に失敗理由を出す。

## 4. 同じ道具呼び出しの繰り返しで止まる

症状：同じツール・同じ引数を何度も呼び続けて固まる。

- `lib/core/chat_controller.dart`：直近 N 回（既定3）の `(name, argumentsJson)` を覚え、
  同じ組が既定回数続いたら `_fail(id, '同じ道具を繰り返し呼んでいます')`。
- `maxToolRounds`（既定4）と二重の歯止めにする。設定で `maxToolRounds` を変えても効くこと。
- テスト：同じ呼び出しを3回返す偽エンジンで、3回目でエラーになること。

## 5. 設定ツールの見え方

- `get_settings` は **APIキーとトークンだけ伏せる**。プロバイダ構成・モデル一覧・MCP サーバー
  （URL・有効/無効・ツール名）は読めるようにする。
- ツール説明に「MCP サーバーとプロバイダは設定画面から追加でき、自分でも読み書きできる」と書く
  （いまは「設定を読む」だけで、設定できることをモデルが知らない）。
- `update_settings` は従来どおり承認つき。APIキーを変更する口は**作らない**（読み書きとも不可）。

## 進め方

- 各項目ごとに：実装 → `flutter analyze` / `flutter test` を CI で通す → main へ → 版を上げて配布。
- 「参考にしたアプリ」の名前はコードにもドキュメントにも書かない（画面名と挙動だけ）。

## 実装メモ（2026-10-21 夜）

- 上記1〜5は `next-steps` ブランチで実装済み。CI が通ってから main にマージする。
- 1：`ProviderConfig.models` と `activeModel`。旧 `model` だけの保存は読み込み時に1件へ移行。
- 2：`AppSettings.mcpServers`。旧 `mcpUrl` は `id=default` の1台へ移行。ツール名は
  `mcp_<id>__<tool>`、`tools/list` はサーバーごとにキャッシュ。
- 3：`GenerationService`（dataSync）と `ai.arce.app/system` の `startForeground` / `stopForeground`。
- 4：同じ道具・同じ引数が3回続いたら `同じ道具を繰り返し呼んでいます` で止める。
- 5：`get_settings` にプロバイダ・モデル・MCP サーバーを追加（キーとトークンは伏せる）。
