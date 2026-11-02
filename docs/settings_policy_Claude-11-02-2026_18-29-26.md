# 設定の方針：機密情報以外は全て設定できる

現行の仕様だけを書く。

- **設定できないのは機密情報だけ**：API キー、GitHub トークン、MCP トークン、検索 API のキー。これらは安全な領域（`flutter_secure_storage`）に置き、設定の JSON・バックアップ・チャットのどこにも出さない。プロバイダの追加ヘッダーに `Authorization` や `x-api-key` のような（機密になりうる）名前は書けない。
- **それ以外は全て、設定画面から変えられる**。上限・タイムアウト・件数・サンプリング・プロンプト・モデルの選択・プロバイダのヘッダーとボディ。**コードに固定の数字を足すときは、設定も足す**（例：添付の個数と文字数と画像の MB、検索結果の件数、通信・MCP・オンラインモデルのタイムアウト、ツールの繰り返し検出、更新ダウンロードの試行回数と無通信の判定、DRY、Linux 環境、`http_request` のリダイレクトの回数）。
- **チャットからも変えられる**（`update_settings`。変更はカードで見せ、承認してから反映）。対象は `AgentSettings.specs`（`lib/core/settings_spec.dart`）。チャットから変えさせないものは `blocked` に**理由つきで**置く：`lastModelPath`・`updateRepo`・`kvCache`・`errorReportEnabled`・`errorReportRepo`・`shellConfirm`・`shellConfirmAfterExternal`・`linuxRootfsUrl`・`linuxRootfsSha256`・`linuxDns`・`approvedTools`・`secretsOffForModel`・`httpRequestConfirm`・`httpRequestAllowInsecure`・`autoShowPages`（モデルが書いたページを、ボタンなしで動かす設定）など。**送り先やキーの扱いを変えるもの**（確認の切り替え、DNS、プロバイダの送り先、秘密の許可ホスト、フォールバックのルール）は、チャットの指示で変えさせない。プロバイダーは、チャットからは**追加だけ**できる（`providers`）。
- **設定の読み書きの道具**：
  - `get_settings`：変更できる設定を、現在値・ラベル・選択肢（日本語ラベル付き）・範囲つきで返す。プロバイダ構成・モデル一覧・MCP サーバー（URL・有効/無効・ツール名）・検索 API（名前・URL の `?` より前・有効か・キーの有無）も読める。**キーとトークンは伏せる**。承認は不要。
  - `update_settings`：1〜6 件の変更を提案し、**承認するまで何も書かない**（毎回）。承認待ちは `UiMessage.settings` として会話に保存され、再起動しても残る。適用は `withSettings(current, changes)` が JSON に書いて `AppSettings.fromJson` に型を決めさせるだけ（キーごとのコードは無い）。モデルに返す文には、いま何になったか（`theme=ダーク` など）と、「次にモデルを読み込んだときから有効」な項目（`contextLength` など）を入れる。
  - API キーを変える口は作らない（読み書きとも不可）。
- **ローカルとオンラインは別々**：端末のモデルは `local*`（temperature・top_p・top_k・min_p・DRY・最大トークン・追加プロンプト）、オンラインは `online*`（temperature・top_p・最大トークン・追加プロンプト）。優先順位は、オンライン＝モデルごとの設定 ＞ `online*` ＞ 既定、ローカル＝`local*` ＞ 既定。端末専用：コンテキスト長・スレッド・HyperLoad・GPU・KV キャッシュ・Force Execution。`AppSettings.toGeneration(modelParamsB, cloud: engine.isCloud)` が、答えるモデルの側を選ぶ。
- モデルごとに **画像を送る** スイッチ（`storage`）。プロバイダには、ツール呼び出しの対応・追加ヘッダー・追加のリクエスト項目（JSON）・プロンプトのキャッシュ用の印の編集画面。
- テスト：設定を足したら、`test/ui/settings_index_test.dart` の索引（`screens`）と、`settings_spec` の対応のテストが通ること。
- 主な設定の例：`downloadConnections`（ダウンロードの同時接続数、既定 4）、`updateUseDelta`、`resumeDownloadsOnStart`、`fontScale`、`autoInstallUpdate`、`maxToolRounds`。
