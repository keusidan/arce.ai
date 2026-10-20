# アプリ設定をモデルから読む・承認つきで変える（2026-10-21）

## 何を直したか

モデルに「このアプリの設定項目を全て教えてください」と聞くと、
「設定画面を参照できないのでお伝えできません」と答えていた。
原因は機能不足で、モデルにアプリ自身の設定を渡す手段が無かった
（`ask_user` / `web_search` / `get_weather` / `get_time` の4つだけだった）。

追加したツールは2つ。

| ツール | 何をするか | 承認 |
|---|---|---|
| `get_app_settings` | 設定を全部（キー・現在値・ラベル・選択肢・範囲・読み取り専用か）返す | 不要 |
| `set_app_setting` | 1項目だけ変更を**提案**する（値は文字列で受け取る） | 毎回必要 |

「承認」は既存の質問カード（`QuestionCard`）をそのまま使い、選択肢を `承認` / `拒否` の2つにした。
1つ選ぶと即答する設定（`multiSelect: false`、`allowFreeInput: false`）なので、UIの変更は不要だった。
承認されるまで設定ファイルには何も書かない。拒否されたらモデルには
`The user rejected the change. Nothing was changed.` を返して続行する。

## 決めたこと（と理由）

- **キーと値の一覧を1か所に置く**：`lib/core/app_settings_spec.dart` の `SettingsCatalog`。
  キーは保存JSONのキーそのもの（`AppSettings.toJson`）なので、変更の適用は
  「JSONに1つ書いて `AppSettings.fromJson` に通す」だけで済み、キーごとのコードが要らない
  （`lib/services/settings.dart` の `withSetting`）。`fromJson` は既に型違いを既定値に落とす。
- **値は文字列で受ける**：道具のスキーマは `key` と `value`（どちらも string）だけにした。
  真偽値・数値・選択肢のどれも文字列から型に落とせるので、スキーマの分岐（`oneOf` の入れ子）を
  増やさずに済み、GBNF 側の負担も増えない。範囲・選択肢の検査は `SettingsCatalog.parse` が行い、
  通らない呼び出しは `ParseInvalid`（＝カードを出さずにやり直し）になる。
- **キーは enum で縛らない**：`key` を `enum` にすると文法に24個の文字列が並ぶ。
  説明文（`keysForPrompt()`）に一覧を入れ、検査は Dart 側で行う方が読みやすく、増減にも強い。
- **`lastModelPath` は読み取り専用**：モデルのファイルパスを外から書き換えられると、
  次の起動で別のファイルを読み込ませられる。読めれば十分。
- **GitHubトークンは最初から存在しない**：`AppSettings` に入っておらず secure storage 側にあるので、
  ツールは何もしなくても触れない（`describe` の末尾でその旨を伝える）。
- **全エージェントに付けた**：「設定を教えて」はどのロールにも来る。ツールはエージェントごとに
  許可されるので、`general` だけに付けると選ばれ方次第で答えられない（報告された画面は
  File Analysis で答えていた）。
- **カードは `UiMessage.setting` として保存する**：再起動して会話を開き直しても承認待ちが残り、
  承認すればそのまま適用される。壊れた保存や未知のキーは `SettingsCatalog.fromStored` が捨てる。
- **読み込み時に効く設定はそう言い返す**：`contextLength`・`threads`・`batchSize`・`gpuOffload`・
  `kvCache` は次にモデルを読み込むまで反映されないので、ツールの応答に
  `It takes effect the next time the model is loaded.` を付ける（モデルが「反映しました」と
  言い切らないように）。

## 触った場所

- 追加：`lib/core/app_settings_spec.dart`（設定の一覧・検査・説明文）
- `lib/core/protocol.dart`：ツール定義2つ、`GetAppSettings` / `SetAppSetting`、
  `SettingsApproval`（承認カード）、`schemaVersion` を 3 に
- `lib/core/tool_runtime.dart`：`get_app_settings` の実行、`settingsValues` の受け口
- `lib/core/chat_controller.dart`：`set_app_setting` を承認待ちにする、`answer` で承認時に適用、
  `UiMessage.setting` と `ChatState.pendingSetting`
- `lib/core/agents.dart`：5つのエージェントすべてに2つのツール
- `lib/services/settings.dart`：`withSetting`
- `lib/services/app_controller.dart`：設定の読み出しと、承認された変更の適用
- テスト：`test/core/protocol_test.dart`、`test/core/tools_test.dart`、
  `test/services/settings_test.dart`

## まだ確かめていないこと

- 実機（Android）での動作。特に、24キー・2ツールを足したぶんの GBNF が
  `json_schema_to_grammar` を通るか、小さいモデル（0.8B）が `key` を正しく書けるかは未確認。
  ここは `flutter analyze` と `flutter test`（CI）では分からない。
- 承認の流れ（`answer` で `承認` を選んだときだけ書く）は、`chat_controller_test` に
  書いたがまだコミットしていない（会話の再起動を跨ぐ復元も同様）。
- `docs/ARCE_AI_flutter-spec_Claude-10-04-2026_09-58-53.md`（引き継ぎ文書）の §4 ツール一覧は
  まだ更新していない。次のセッションで追記すること。
