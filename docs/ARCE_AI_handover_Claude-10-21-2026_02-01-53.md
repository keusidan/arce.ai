# ARCE.AI 引き継ぎメモ

- 作成：2026-10-21 02:01 JST
- リポジトリ：`keusidan/arce.ai`（公開）
- 作業ブランチ：`feat/llm-db`（`main` はまだ 0.4.0 のまま）
- これを読めば、会話の履歴なしで作業を続けられるように書いています。

## 0. 最初に読むもの

| 文書 | 内容 |
|---|---|
| `AGENTS.md` | ブランチ・コマンド・壊すと困る約束 |
| `docs/ARCE_AI_flutter-spec_Claude-10-04-2026_09-58-53.md` | 構成・決定・未確認事項（2026-10-04 時点の全体像） |
| `docs/ARCE_AI_flutter-release_Claude-10-04-2026_08-46-00.md` | リリース手順 |
| `docs/ARCE_AI_design-draft_Claude-10-20-2026_19-19-07.md` | 機能拡張の設計草案（P0〜P7） |
| `docs/ARCE_AI_llm-db_Claude-10-20-2026_22-37-26.md` | 会話履歴DB移行の記録 |

## 1. いまの状態（2026-10-21 02:00 JST）

- 最新リリース：**v0.4.3**（Android 01:48 JST、`ios-` / `macos-` / `linux-v0.4.3` も公開済み）
- CI（`flutter analyze` → `flutter test`）は `feat/llm-db` の先頭で**緑**
- `main` は 0.4.0 のまま。**合流できていない**（理由は §5）
- Android の APK は Actions でビルド・署名検証・公開まで通る
- **Windows のリリースだけが 0.4.1 以降ずっと失敗している**（§4）

## 2. 直近でやったこと（2026-10-20〜21）

### 2.1 会話履歴を LLM 専用DBへ（設計草案 P0・完了）

- `lib/data/llm_db.dart`：`replaceMessages` / `lastFinishReasons` / `setLastFinishReason` を追加
- `lib/data/conversation_snapshot_store.dart`（新規）：画面のスナップショット（`messages` / `history` / `nextId`）を DB に読み書き。**Flutter 非依存**なので端末なしで検証できる
- `lib/services/conversation_database.dart`（新規）：DB を開く・旧JSONの取り込み・`list/save/get/delete/clearGenerating/search`
- `lib/services/history_store.dart`（JSON保存）は削除
- `app_controller.dart` を DB に切替、`history_page.dart` のIDを `String`（UUID）に追従
- テスト：`test/data/conversation_snapshot_store_test.dart` 17件＋既存DBテスト

**決めたことと理由**

1. 保存は追記ではなく**置き換え**。画面は返信の開始時と終了時に会話全体を渡すので、追記だと生成中の返信が 2 行になる。メッセージIDは位置（`<会話ID>@<seq>`）から作り、何度保存しても行を増やさない
2. アプリが落ちた中断は `finish_reason = 'interrupted'` として `cancelled` と区別。読み戻すときに `cancelled` になるので、起動時の「続きから再開」が従来どおり効く
3. 旧JSONの取り込みは毎起動でよい（ID が `legacy-<元id>` なので冪等）。ファイルは消さない
4. 設定・プロバイダ定義・APIキーは DB に入れない（設定JSONとセキュアストレージのまま）

### 2.2 更新のダウンロードを中断しても続きから（完了）

- `<asset>.part` に書き、切れても残す。次回は `Range: bytes=<済み>-` で続きだけ取る
- SHA-256 は「ディスク上の済み分＋続き」で全体を計算するので検証は従来どおり
- ストレージが Range を無視したら、途中ファイルを捨てて取り直す
- 壊れた途中ファイル（アセットサイズ超）は破棄
- 起動時に「いま動いている版のダウンロード」「古い版のファイル」を削除。**再開に使える新しい版の `.part` は残す**
- デスクトップは展開完了後にアーカイブを削除
- テスト：`test/services/update_resume_test.dart` 5件

### 2.3 クラウド連携の土台（途中）

- `lib/ai/provider.dart`：`Delta`（本文・思考・道具呼び出し・使用量・停止理由）/ `AiRequest` / `AiMessage` / `AiToolSpec` / `AiProvider` / `ProviderCapabilities`。Flutter 非依存
- `lib/ai/openai_compatible.dart`：chat-completions の SSE 購読。**chunk 境界で切れた行の復元**、`reasoning_content` の分離、**分割で届く関数呼び出し引数の組み立て**（完成時のみ 1 つ返す）、`usage`、`finish_reason` の対応付け。接続先ごとの差は headers / body の上書きで吸収。失敗は日本語で原因別
- テスト：`test/ai/openai_compatible_test.dart` 12件
- **まだ画面・チャットに繋いでいない**（次は §6 の 1）

### 2.4 リリース

- v0.4.2（履歴DB版）、v0.4.3（更新の再開版）。どちらも `feat/llm-db` から版上げして出している
- Android の versionCode は `主版×1,000,000 + 副版×1,000 + 修正版` なので 0.4.3 は 4003

## 3. 確認できていること／できていないこと

**確認済み**
- CI（analyze + test）が緑。データ層のテストは手元の Dart SDK でも 91 件緑
- `lib/ai` の 12 件は手元（`dart analyze` + `dart test`）でも緑
- v0.4.3 の Android APK がビルド・署名検証・公開まで通る（約 7 分、ccache 有効）
- 利用者から「動作は確認しました」との報告あり（v0.4.2 の履歴保存について）

**未確認**
- 旧JSON→DB の取り込みを実データ量で試していない
- iOS / Windows / macOS / Linux の実機での DB 読み書き（`flutter test` は Linux で通る）
- 更新の再開が実機のモバイル回線で効くか（テストは mock のみ）
- クラウドプロバイダとの実接続（未実装のため）

## 4. 既知の問題：Windows のリリースが落ちる

- 症状：`Release Windows` が **`flutter test` の段階で失敗**し、ビルドと公開に進まない
- いつから：**0.4.1 以降**（0.4.1 の run 39414565354 でも同じステップで失敗）。0.4.0 までは Windows リリースが出ている
- 推定原因：`sqlite3` 3.x は build hook で SQLite を同梱するが、**Windows ランナーの `flutter test` ではそのネイティブライブラリを用意できない**（DBを開くテストが落ちる）
- 制約：ジョブログの取得がトークン権限で 403 になるため、ステップ単位までしか特定できていない
- 方針（未適用）：`release-windows.yml` の `flutter test` を **`flutter test test/core test/services`** に変える。DB・UI のテストは Linux 側で回る。まずこれでビルドと公開まで通し、`flutter build windows` が sqlite3 を含められるかを見る

## 5. 塞がっていること：`main` への合流

- `feat/llm-db` → `main` の PR 作成が **403 Resource not accessible by personal access token**。トークンに **Pull requests: Read and write** が無い
- ブランチの付け替え（force update）はこのAPI群からは触れない
- 選択肢：(1) トークンに Pull requests 権限を追加 → PR作成→マージを任せてもらう、(2) GitHub 画面でマージ、(3) 差分ファイルを `main` へ書き戻す（途中で失敗すると `main` が中途半端に壊れるので非推奨）
- リリースはタグ基準なので、`main` が古くても端末の更新は届く

## 6. 次にやること（この順）

1. **クラウド連携の配線**
   - 設定：プロバイダ定義（名前・Base URL・モデル・上書きヘッダー/body）＋ APIキーは `flutter_secure_storage`、「接続を確認」（`AiProvider.verify`）
   - `CloudEngine implements InferenceEngine`：`GenerateRequest.prompt`（ChatML）を `parseChatMl` で分解して `AiRequest` にし、`Delta` を `Piece` / `<tool_call>` テキストに戻す。文脈は `core/prompt.dart` の履歴をそのまま使う
   - 会話ごとの切替。`conversations.provider_id` / `model_id` に保存し、履歴から開き直しても同じプロバイダで続く
   - 使用量（`prompt_tokens` / `completion_tokens` / `cost_micros`）を DB に記録して履歴に出す
   - 注意：`GenerationEvent` は `Piece` と `Finished` しかないため、**いまはクラウドの思考（reasoning）を画面に出せない**。出すなら `generation.dart` に思考用のイベントを足して `stream_segmenter` と `chat_controller` を直す
2. Windows の `flutter test` を §4 の方針で通す（0.4.4 で Windows リリースを復活させる）
3. 履歴画面に横断検索の入口を付ける（`ConversationDatabase.search` は実装済み）
4. 設計草案 P2（送信前プロンプトプレビュー）。クラウド導入後は「外部に何が出るか」の確認が要る
5. 添付の実体を `assets` テーブル＋ファイルに移す（いまはファイル名だけ）

## 7. 作業のルール（利用者の指定）

- 返答は日本語、時刻は **日本時間**
- ブランチは利用者が指定する（通常は `main`。いまの作業は `feat/llm-db`）。頼まれるまで PR は作らない・ブランチを増やさない
- `docs/` の新規文書は末尾に `Claude-MM-dd-yyyy_HH-mm-ss`
- リリースは Actions で回す（端末のリソースを使わない）。ビルドが回るならリリースまで進めてよい
- 待ち合わせに固定の sleep を使わず、**GitHub の応答で状態を確認する**
- Android：パッケージ名 `ai.arce.app.engine`、`applicationId` `ai.arce.app`、`minSdk 31` を変えない。タグは接頭辞なし `vX.Y.Z` で Latest、他OSは `ios-v…` 等
- 署名鍵（`*.jks`）はコミットしない

## 8. 環境メモ（次のセッションでも当てはまる可能性が高い）

- ワークスペースは **aarch64 の proot Ubuntu**。`dart` は手元にあるが **Flutter SDK は arm64 版が無く、x86_64 版は qemu でも動かなかった**（`flutter_tools.snapshot` が Illegal instruction）。そのため `flutter analyze` / `flutter test` は **CI を検証手段にする**
- ただし **純 Dart のファイル（`lib/data`、`lib/ai`、`lib/core` のいくつか）は手元で `dart analyze` / `dart test` できる**。作業用の小さなパッケージにコピーし、`package:flutter_test` を `package:test` に置換して回す
- CI の結果は `https://api.github.com/repos/keusidan/arce.ai/...` を未認証で照会できる（`/commits/<sha>/check-runs`、`/actions/runs/<id>/jobs`）。**ジョブログは 403**
- ファイルを push するときは内容をそのまま送る必要がある。push 後に `git hash-object` と GitHub の blob sha を比べると、送った内容がローカルと一致したか確認できる
