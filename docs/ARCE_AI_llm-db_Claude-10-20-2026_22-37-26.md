# ARCE.AI 会話履歴の DB 移行（P0）

- 作成日：2026-10-20（日本時間 22:37 時点）
- 対象：`keusidan/arce.ai` の `feat/llm-db` ブランチ（`main` はまだ 0.4.0 のまま）
- 位置づけ：設計草案 §4「チャット履歴の保存（LLM専用DB）」と Phase P0 の実装メモ

## 1. 何が変わったか

これまで会話は `conversations/<id>.json` に 1会話1ファイルで保存していた。今回から **SQLite の `arce_llm.db`** が保存先になる。

| 層 | ファイル | 役割 |
|---|---|---|
| 画面 | `lib/ui/history_page.dart` | 一覧のIDが `int` から `String`（UUID）に変わっただけ |
| サービス | `lib/services/conversation_database.dart` | DB を開き、旧JSONを取り込み、`list/save/get/delete/clearGenerating/search` を提供 |
| データ | `lib/data/conversation_snapshot_store.dart` | 画面が渡すスナップショット（`messages`/`history`/`nextId`）を DB に読み書き |
| データ | `lib/data/llm_db.dart` | `replaceMessages`、`lastFinishReasons`、`setLastFinishReason` を追加 |

`lib/services/history_store.dart`（JSON保存）は削除した。旧JSONを読むのは取り込み処理だけ。

## 2. 決めたことと、その理由

1. **保存は「追記」ではなく「置き換え」**
   チャット画面はクラッシュで失う地点（返信の開始時と終了時）で会話全体を渡してくる。追記にすると、
   まだ生成中の返信が 2 行になる。そこで `replaceMessages` で毎回書き直す。メッセージIDは
   位置（`<会話ID>@<seq>`）から作るので、同じ会話を何度保存しても行は増えない。
2. **「中断」を `cancelled` と区別する**
   アプリが落ちて返信が途中で終わった状態を、利用者が「停止」を押した状態と同じにすると、
   起動時に「続きから再開しますか」を出す判断ができない。DB には `interrupted` を書き、
   画面に戻すときに `cancelled` に読み替える（`UiMessage.finish` は既存の enum のまま）。
3. **旧JSONの取り込みは起動のたびに実行してよい**
   取り込んだ会話のIDは `legacy-<元のid>` なので、二度目以降は `skipped` になる。ファイルは消さない。
4. **モデル履歴も DB に入れる**
   `turns` テーブルに `user/assistant/tool` をそのまま保存する。旧JSONの `history` と同じ形なので、
   復元した会話はこれまでと同じ文脈で続けられる。
5. **設定・プロバイダ定義・APIキーは DB に入れない**
   従来どおり設定JSONとセキュアストレージ。DB は会話データ専用。

## 3. 画面から見た振る舞い

- 会話一覧の並び（更新の新しい順）、ピン留め、メッセージ数の表示は従来と同じ。
- 生成中にアプリが落ちた場合、次回起動で「再開する／作り直す／捨てる」を出す流れも従来どおり。
- 履歴のIDが UUID になったので、`conversationId` の型が `String?` になっている。

## 4. 確認したこと

- `dart analyze`（`flutter_lints` 込み）で **No issues found**。`flutter analyze` も CI で成功（run 118657287784）。
- `flutter test` も CI で成功。データ層のテストは手元（arm64 の Dart SDK）でも 91 件すべて緑。
  - `test/data/llm_db_test.dart` 65 件（うち旧JSONの取り込み 6 件）
  - `test/data/conversation_snapshot_store_test.dart` 17 件（保存・読み戻し・中断の印・壊れたJSON・検索・削除）
- `feat/llm-db` の CI（`flutter analyze` → `flutter test`）が緑になったことを API で確認。

## 5. まだ確認していないこと

- **実機（Android）での動作**。`sqlite3` 3.x は build hook で SQLite を同梱するので追加の依存は要らない想定だが、
  APK で DB を開けるかは未確認（v0.4.1 の APK は DB を使っていないため、まだ誰も通っていない道）。
- 旧JSONからの取り込みを、実データ量（数百会話）で試していない。
- iOS / Windows / macOS / Linux での DB の読み書き（`flutter test` は通るが、実機の書き込み先は未確認）。

## 6. 次にやること

1. `feat/llm-db` を `main` に合流させ、版を上げて APK をビルド（実機で履歴が残るか確認）。
2. 履歴画面に横断検索の入口を付ける（DB 側は `ConversationDatabase.search` が実装済み）。
3. 設計草案 P1（プロバイダ抽象）へ。`provider_id` / `model_id` は保存済みだが、いまは `local` 固定。
4. 添付の実体を `assets` テーブル＋ファイルに移す（現状はファイル名だけを持つ）。
