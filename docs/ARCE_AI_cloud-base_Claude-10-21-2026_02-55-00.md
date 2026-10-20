# ARCE.AI クラウド連携の土台（P1 の前半）

- 作成：2026-10-21 02:55 JST
- 作業ブランチ：`feat/llm-db`（`main` は 0.4.0 のまま。合流は §5）
- リリース：v0.4.4（Android・iOS・Linux・macOS は公開済み。Windows だけテスト3件で失敗、§4）
- 前提の文書：`ARCE_AI_handover_Claude-10-21-2026_02-01-53.md`、`ARCE_AI_design-draft_Claude-10-20-2026_19-19-07.md`

## 1. 今回入れたもの（コード）

| ファイル | 内容 |
|---|---|
| `lib/ai/chatml_bridge.dart` | チャットが組み立てた ChatML のプロンプトを、プロバイダに渡すメッセージ列に分解する。`Delta` を `Piece` に戻す `CloudEventAdapter` も同じファイル |
| `lib/ai/cloud_engine.dart` | `CloudEngine implements InferenceEngine`。プロバイダを普通の推論エンジンとして扱う |
| `lib/ai/provider_config.dart` | プロバイダ定義（id・表示名・Base URL・model・上書きヘッダー/body・道具の可否）と、その一覧の読み書き |
| `lib/ai/routing_engine.dart` | `RoutingEngine`。端末のエンジンとクラウドを要求ごとに振り分ける |

**画面にはまだ繋いでいない。** 設定画面でのプロバイダ登録・会話ごとの切替・使用量の記録が次の段階（§6）。

## 2. 決めたことと、その理由

1. **プロンプトは 1 本のまま**。どちらのエンジンでも同じ ChatML を作り、クラウドに送るときだけ
   メッセージ列に分解する。`<tool_call>` と `<tool_response>` はローカルの書き方のまま本文に残すので、
   道具呼び出しの解析（`ToolCallParser`）も `StreamSegmenter` も手を入れずに済む。
   → エンジンごとに文脈の作り方が違うと、同じ会話が別物になる。
2. **続行（途中までの返信）は指示文に置き換える**。OpenAI 互換の API には前置き（prefill）を
   指定する口が無いため、書けている本文を最後の assistant メッセージとして送り、
   「その続きから書く。繰り返さない」という user メッセージを足す（`ChatMlBridge.continuationNote`）。
3. **APIキーは設定に持たせない**。`ProviderConfig` は `provider_key.<id>` という保存先の名前だけを返す。
   実体は `flutter_secure_storage`。設定の JSON をコピーしても、QR で配っても鍵は出ない。
4. **`local` は予約 id**。端末のモデルは「フォールバック」ではなく、並んだプロバイダの 1 つ。
   一覧から `local` という id は受け付けない。
5. **黙って乗り換えない**。選んだプロバイダが失敗したら、その失敗をそのまま見せる（端末で答え直さない）。
   → 画面に出ている回答元と、実際に答えた相手がずれない。
6. **`ToolCallDelta` の名前が中核とぶつかる**ため、`chatml_bridge.dart` では中核側を `hide` している。
   どちらも「道具呼び出し」を表すが、片方はプロバイダの差分、もう片方はセグメンタのイベント。

## 3. テスト

- 追加：`test/ai/chatml_bridge_test.dart`（8）・`cloud_engine_test.dart`（7）・
  `provider_config_test.dart`（10）・`routing_engine_test.dart`（5）
- 手元（aarch64 の proot、Dart 3.13.5）では `dart analyze` と `dart test` が緑。ただし Flutter の
  テストランナーはこの環境で動かないため、`flutter_test` と同じ面（`matcher/expect.dart` と
  `test_api/scaffolding`）を持つ小さな代役を作って同じテストを走らせて確認した。
- CI（`flutter analyze` → `flutter test`）は `feat/llm-db` の先頭で緑。
- **最初の push では CI の analyze が落ちた**：新しいテストが `package:test` を import していたが、
  これは pubspec の依存に無い（既存のテストは `flutter_test` から取っている）。同じ形に直した。

## 4. Windows のリリースが落ちる件（原因が分かった）

**分かったこと**：`flutter test` の失敗は「ネイティブライブラリが無い」ではなく、**テスト3件の失敗**。
`flutter analyze` は通り、テストは「209 tests passed, 3 failed」。

- ジョブログは取得できない（403 `Must have admin rights to Repository`）。
- しかし **アノテーションは読める**：`/repos/{owner}/{repo}/check-runs/{id}/annotations`。
  ここに `209 tests passed, 3 failed` と `Process completed with exit code 1` が出ていた。
  → 0.4.1 以降ずっと「ステップ単位でしか分からない」としていたが、実は原因の一部は読めていた。
- 対策として `release-windows.yml` の Test ステップを、失敗時に**テスト名と期待値の前後を
  `::error::` で出す**ように変えた（アノテーション経由で読むため）。あわせて、
  `release-windows.yml` 自身を直したときも動くようにした（版を上げ直さずに試せる）。
- 数が合う候補：`test/ui/app_test.dart` の `testWidgets` はちょうど3件（スマホ配置・デスクトップ配置・
  設定の保存）。ただし**名前は次の実行のアノテーションで確定させる**。推測で直さない。

## 5. 塞がっていること：`main` への合流

`feat/llm-db` → `main` の PR 作成が `403 Resource not accessible by personal access token`。
トークンに **Pull requests: Read and write** が無いため。追加できれば PR 作成からマージまで行う。
不可なら GitHub の画面でマージする（差分の書き戻しは途中で失敗すると `main` が中途半端になるので避ける）。

## 6. 次にやること

1. Windows のテスト3件を、アノテーションで名前を確認してから直す（推測で直さない）
2. クラウドの画面配線
   - 設定：プロバイダの一覧・追加/編集・「接続を確認」（`AiProvider.verify`）・APIキーの入力
   - 会話ごとの切替：`conversations.provider_id` / `model_id` に保存し、履歴から開き直しても続く
     （`ConversationSnapshotStore.save` は既に `providerId` / `modelId` を受ける）
   - 使用量（`prompt_tokens` / `completion_tokens`）を DB に記録して履歴に出す
     → `CloudEventAdapter` は `UsageDelta` を捨てているので、`CloudEngine` から受け取れるようにする
3. 履歴の横断検索の入口（`ConversationDatabase.search` は実装済み）
4. 送信前プロンプトプレビュー（設計草案 P2）

## 7. 環境メモ（次回も当てはまる）

- ワークスペースの rootfs は導入済み（Ubuntu 24.04.3、`dart` 3.13.5、`git`、`curl` が動く）。
  Flutter SDK は arm64 で動かないため、Flutter の検証は CI に任せる。
- **GitHub API は未認証だと 1 時間 60 回**。ポーリングで使い切ると
  `API rate limit exceeded` になる（実際に起きた）。以降は `api.github.com` の読み取りを
  Web 取得の経路で行うと、この枠を使わずに済む。
- 待ち合わせに固定の `sleep` を使わない。GitHub の応答を見て次の行動を決める。
- アノテーションは読めるが、**ジョブログは読めない**。CI から原因を知りたいときは
  `::error::` を出す（アノテーションになる）。
