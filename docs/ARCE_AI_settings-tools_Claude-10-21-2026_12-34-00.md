# 設定をモデルから読む・承認つきで変える（2026-10-21）

## 何が足りなかったか

v0.4.6 の時点で、設定を変える土台はほぼ出来ていた。

- `lib/core/settings_spec.dart` の `AgentSettings`（変更してよいキー・ラベル・選択肢・範囲の検査）
- `lib/core/protocol.dart` の `update_settings` ツール定義と `UpdateSettings` の解釈
- `test/core/protocol_update_settings_test.dart`、`test/core/settings_spec_test.dart`

足りなかったのは3つ。

1. `update_settings` が**どのエージェントにも許可されていなかった**（定義はあるがモデルから呼べない）
2. 承認カードと適用の配線が無かった（`ChatController` も `AppController` も知らなかった）
3. **設定を読む手段が無かった**ので、「このアプリの設定を教えて」に答えられなかった（報告された画面）

## 追加したもの

| ツール | 動き | 承認 |
|---|---|---|
| `get_settings`（新規） | 変更できる設定を、現在値・ラベル・選択肢（日本語ラベル付き）・範囲つきで返す。APIキーとGitHubトークンは返さない | 不要 |
| `update_settings`（既存を配線） | 1〜6件の変更を提案する。既存の質問カードに `承認` / `拒否` を出し、**承認するまで何も書かない** | 毎回 |

- 5エージェント全部に2つを許可した（「設定を教えて」はどのロールにも来るため）。
- 適用は `withSettings(current, changes)`（`lib/services/settings.dart`）が JSON に書いて
  `AppSettings.fromJson` に型を決めさせるだけ。キーごとのコードは無い。
- 承認待ちは `UiMessage.settings` として会話に保存される。再起動して開き直してもカードが残り、
  `承認` を押せばそのまま適用される。壊れた保存や、もう変更できないキーは `_settingsFromJson` が捨てる。
- モデルに返す文には、いま何になったか（`theme=ダーク` など）と、`contextLength` などの
  「次にモデルを読み込んだときから有効」を入れた（反映していないのに反映したと言わせないため）。

## 触った場所

- `lib/core/settings_spec.dart`：`describe()`（読み取りの文面）
- `lib/core/protocol.dart`：`get_settings` の定義、`GetSettings`、`SettingsApproval`（承認カード）
- `lib/core/tool_runtime.dart`：`get_settings` の実行と `settingsValues` の受け口
- `lib/core/chat_controller.dart`：`update_settings` を承認待ちにする、`answer` で承認時に適用、`UiMessage.settings`
- `lib/core/agents.dart`：5エージェントに `get_settings` / `update_settings`
- `lib/services/settings.dart`：`withSettings`
- `lib/services/app_controller.dart`：適用と、設定ストアの値をツールへ渡す配線
- `test/core/settings_tools_test.dart`（新規）：読み取り・承認・拒否・保存からの復元

## まだ確かめていないこと

- 実機（Android）での動作。`update_settings` の引数は `changes` の配列で、値は boolean / number /
  string のどれか（`oneOf`）。この形の JSON Schema が llama.cpp の `json_schema_to_grammar` を
  通るかは CI では分からない。
- 小さいモデル（0.8B）が `key` を正しく書けるか。
- v0.5.0 は別の（古い main から切った）ブランチで作ってしまった版で、この版とは中身が違う。
  0.5.1 が正しい系譜で、0.5.0 は使わないこと。
