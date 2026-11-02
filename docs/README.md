# ARCE.AI ドキュメント（索引）

**現行の仕様だけ**を書いている（1.0.1 時点）。経緯・版ごとの変更・利用者の指示の記録は書かない。1.0.0 より前の履歴は `archive` ブランチにある（旧 1 ファイルの docs もそこ。`overview` の「履歴とブランチ」）。`AGENTS.md` に、壊すと困る約束がある。

トピックごとに 1 ファイル（ファイル名の末尾の `Claude-MM-dd-yyyy_HH-mm-ss` は、Claude が作ったことを示す印）。**未確認**と書いてあるものは、実機・実際のサービスで確かめていない。

| ファイル | 内容 |
|---|---|
| [overview_Claude-11-02-2026_18-29-26.md](overview_Claude-11-02-2026_18-29-26.md) | 何のアプリか・ディレクトリ・作業のルール・履歴とブランチ（`main`・`dev`・`archive`） |
| [screens_Claude-11-02-2026_18-29-26.md](screens_Claude-11-02-2026_18-29-26.md) | 画面の仕様：チャット（Markdown・思考・進み具合・同時進行・停止・割り込み・通知・承認カード）、設定画面（グリッドと検索） |
| [core_engine_Claude-11-02-2026_18-29-26.md](core_engine_Claude-11-02-2026_18-29-26.md) | 中核（チャット制御・エージェント・ツール・会話の圧縮・JSON の方針）、エンジンと Android の橋渡し |
| [storage_Claude-11-02-2026_18-29-26.md](storage_Claude-11-02-2026_18-29-26.md) | 会話の履歴（SQLite）、KV キャッシュ、添付ファイル |
| [providers_Claude-11-02-2026_18-29-26.md](providers_Claude-11-02-2026_18-29-26.md) | クラウドのモデル：構成・上限と推奨・思考・ツールの形・`add_provider`・一覧とフォールバック・キャッシュと使用量・使えないモデルの印 |
| [settings_policy_Claude-11-02-2026_18-29-26.md](settings_policy_Claude-11-02-2026_18-29-26.md) | 設定の方針（機密情報以外はすべて設定。チャットから変えられるもの・変えられないもの） |
| [coding_mode_Claude-11-02-2026_18-29-26.md](coding_mode_Claude-11-02-2026_18-29-26.md) | コーディングモード（プランナー＋複数の開発モデル、依存・並列、図） |
| [integrations_Claude-11-02-2026_18-29-26.md](integrations_Claude-11-02-2026_18-29-26.md) | MCP・Kaggle・オンライン検索・エラーの自動報告・`ci_status` |
| [updates_Claude-11-02-2026_18-29-26.md](updates_Claude-11-02-2026_18-29-26.md) | アプリ内更新・ダウンロードの部品・差分更新 |
| [release_ci_Claude-11-02-2026_18-29-26.md](release_ci_Claude-11-02-2026_18-29-26.md) | リリースと CI：タグ・ワークフロー・署名鍵・ブランチ・OS ごとの注意・ローカルでの確認 |
| [github_bot_Claude-11-02-2026_18-29-26.md](github_bot_Claude-11-02-2026_18-29-26.md) | リポジトリの bot（`bot.yml`。安全の限度が規則） |
| [linux_environment_Claude-11-02-2026_18-29-26.md](linux_environment_Claude-11-02-2026_18-29-26.md) | アプリ内の Linux 環境（proot）と `run_command`、安全面、proot のビルドと同梱 |
| [shell_sessions_Claude-11-02-2026_18-29-26.md](shell_sessions_Claude-11-02-2026_18-29-26.md) | 対話セッション `shell_session`、CLI エージェント |
| [secrets_Claude-11-02-2026_18-29-26.md](secrets_Claude-11-02-2026_18-29-26.md) | 秘密の扱い：環境変数 `secrets` と、プレースホルダー `{{secret:ID}}`（`http_request`・スクリプト） |
| [verification_Claude-11-02-2026_18-29-26.md](verification_Claude-11-02-2026_18-29-26.md) | 確認できていること／できていないこと、既知の制限、環境の制約 |
| [open_questions_Claude-11-02-2026_18-29-26.md](open_questions_Claude-11-02-2026_18-29-26.md) | 利用者の判断待ち・実機での確認待ち |
| [sources_Claude-11-02-2026_18-29-26.md](sources_Claude-11-02-2026_18-29-26.md) | 出典 |
| [requirements_Claude-11-02-2026_18-29-26.md](requirements_Claude-11-02-2026_18-29-26.md) | 利用者の企画書（原文） |
| [lessons_Claude-11-02-2026_18-29-26.md](lessons_Claude-11-02-2026_18-29-26.md) | 利用者の助言書：実装の教訓と失敗ログ（原文） |

コードを読めば分かること（個々の関数の動き）は書かず、**意図・決定・制約・未確認のこと**を書く。
