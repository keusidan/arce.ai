# 中核（`lib/core`）とエンジン・Android の橋渡し

現行の仕様だけを書く。

## チャット制御（`lib/core/chat_controller.dart`）
- 1 回の返信は「エージェントを選ぶ → プロンプトを作る → エンジンから流れてくる文字を `StreamSegmenter` で思考・本文・ツール呼び出しに分ける → ツール呼び出しなら実行して続ける、`ask_user` なら質問カードを出して待つ」の繰り返し。ツール呼び出しが途中で切れたら、設定の回数だけ書き直す。最大ツール回数を超えたらエラー。**同じ道具・同じ引数が 3 回続いたら**「同じ道具を繰り返し呼んでいます」で止める。会話は返信の開始時（生成中フラグ付き）と終了時に保存する。
- 状態（`TaskState`）：waiting / search / thinking / userWait / generation / completed / error / cancelled。遷移は `GenerationTask` が検査する。
- **ストリームの表示**：返信と思考は `StringBuffer` に貯め（`String` への `+=` は毎回コピーするため、長い返信で 2 乗の時間になる）、画面への通知は、断片が届く間は 50 ms に 1 回までにまとめる。段階が変わったとき・最初の思考の文字・ラウンドの終わりは、すぐ通知する。思考の見出しは、通知を送るときにだけ読む。
- **エージェント**：General Chat / Coding / Research / Artifact / File Analysis。キーワードで選び、迷うときだけ（設定が有効で、モデルが読み込み済みなら）モデルに厳密な JSON で選ばせる。ユーザーが指定すればそれが最優先。5 つ全部に `get_settings` / `update_settings` / `add_provider` を許可している。
- **プロンプト**：Qwen3 の ChatML。口調は `<tone>` で囲み、制御用の文字列を取り除く（200 文字まで）。
- **途中送信・送る前のトークン数・承認**は `screens`、道具ごとの仕様は下と `integrations`・`linux_environment`・`secrets`。

## ツール（`lib/core/protocol.dart`。定義の版 `Protocol.schemaVersion` は **7**）
- `ask_user`、`web_search`、`get_weather`（Open-Meteo）、`get_time`（`timezone` パッケージ）、`get_settings`、`update_settings`、`add_provider`。
- MCP のツール：`mcp_<サーバー id>__<ツール名>`。サーバーが多いときは、**必要なときだけ呼ぶ形**（`mcp_find`・`mcp_describe`・`mcp_call`。`integrations`）。
- アプリ自身の道具（`McpTools` が実行する）：`run_command`・`shell_session`（Linux 環境。`linux_environment`）、`http_request`（`secrets`）、`ci_status`（GitHub Actions の読み取りだけ。`integrations`）。
- **プロンプトの中の道具の定義**（`ChatMlPromptBuilder._appendTools`）：選べる値の一覧（`enum`）が **24 個より多いもの**（`update_settings` の設定名）は、プロンプトには書かず、短い注意（`longEnumNote`）を足す。モデルの出力を縛る文法（`Protocol.toolCallSchema`）と呼び出しの検査（`AgentSettings.normalize`）には、一覧を全部残すので、正しくない名前は受け付けない。設定名は `get_settings` が返す。端末のモデルは答えの前に指示を全部読むので、道具の定義が長いと最初の言葉までが遅い（8B の Q4 で、指示約 4,000 トークンのうち道具が約 3,400 トークンだったとき、4 分半たっても最初の言葉が出なかった。実機の報告）。
- 検索の順：SearXNG のアドレス（入れていれば）→ 登録した検索 API（一覧の順、有効なもの）→ DuckDuckGo Instant Answer（`integrations`）。
- 道具の定義・承認・実行は、1 つの `McpTools` から作る（定義を作る側と実行する側が別のインスタンスだと、設定やトークンが片方にしか渡らない）。

## 長い会話の圧縮（`ChatController._makeRoom`、`lib/core/compaction.dart`）
- 返信のたびに、**送る前**に、リクエストが文脈の `compactAtPercent`％（既定 80）を超えそうか数える。文脈の大きさが分かるときだけ（オンラインのモデルは設定・自動取得の値、端末のモデルは読み込んだ文脈長）。超えるときは、順に：
  1. **古い道具の結果を切り詰める**（直近の発言より前の道具の答えを `compactToolResultChars` 文字まで。長い検索結果や MCP の答えが一番かさばるため。モデルは使わない）。
  2. 足りなければ、**直近 `compactKeepTurns` 件の発言より前を、モデルに要約させる**。要約の依頼は、会話を「文脈の 4 割」ほどの大きさの組に分けて組ごとに書かせ、前の要約を次の依頼に添える（要約の依頼自体が文脈に入るように）。
- 要約は、**残す最初の発言の頭に入れる**（「[Summary of the earlier conversation…] … [The user's message that follows the summary] …」）ので、ユーザーとアシスタントの交代は崩れない。道具の呼び出しとその答えの間では切らない（切り目は、必ずユーザーの発言の頭）。アプリが履歴に書いた注意（`[from the app]`）は「発言」に数えない。
- 要約を書けなかったとき（エラー・空・思考だけ）は**履歴を変えず**、そのまま送る（足りなければ、いつもの「入りません」のエラー）。**画面のメッセージは消えない**（モデルに送る履歴だけが変わる）。返信に「会話の前半（N 件）を要約しました（約 A → B トークン）」と出る。
- **手動**：入力欄の下のトークン数の横の「会話を要約する」（`canCompact` のとき。`compactNow`。文脈の大きさに関係なく今すぐ）。
- 設定（制限のグループ）：`compactEnabled`（既定オン）・`compactAtPercent`・`compactKeepTurns`（既定 4）・`compactSummaryChars`（既定 3000）・`compactToolResultChars`（既定 1500）。チャットからも変えられる（`AgentSettings`）。
- 使うモデルは、いま答えているモデルそのもの（別のモデルを選ぶ設定は無い）。端末のモデルでは、要約の依頼が KV キャッシュを一度押しのけるので、その返信は遅くなる（`storage`）。**未確認**：実機の端末モデルでの要約の質（小さいモデルは下手なはず）。

## JSON の方針
JSON は GBNF（llama.cpp の文法）で縛る。ただし、縛るのは**構造が必要な部分（質問タイル・tool call）だけ**で、本文は Markdown のまま。決まった合図（`<tool_call>`）が出たところから文法を効かせる（lazy grammar）ので、Thinking と本文は自由に書ける。Tool と質問の定義は JSON Schema で書き、llama.cpp の変換で文法にする。形式が崩れたときは修復せず、途中切断のときだけ再生成する。意味のチェック（`options` が空でない、など）は別に行う。Schema にはバージョン番号を付ける。出典は `sources`（llama.cpp の文書）。

## モデルカタログ
基本は Qwen3.5-0.8B（Q8_0）。Qwen3 の 0.6B〜14B（GGUF）と、LiteRT-LM の 4 種。NPU 用は、その SoC の端末にだけ出す。GGUF と `.litertlm` は形式が違うので、エンジンごとに別の一覧。

## エンジンと Android の橋渡し
- Dart の `NativeEngine` と、Kotlin の `EngineBridge` は、`ai.arce.app/engine`（メソッド）と `ai.arce.app/engine/events`（イベント）でつなぐ。
- メソッド：`devices`、`load`（`kvType` ＝ 0 F16 / 1 Q8_0 / 2 Q4_0）、`generate`（`id` を渡す）、`cancel`、`unload`、`saveState` / `loadState`（KV キャッシュのファイル保存。`storage`）。
- イベント：`{id, type: piece|done|error, text/reason/message}`。1 本のストリームを、`id` で振り分ける。
- 端末情報・APK のインストール・Linux 環境は `ai.arce.app/system`（`memory`、`freeStorage`、`soc`、`canInstall`、`requestInstall`、`install`、`baseApk`、`startForeground`、`stopForeground`、`prootCheck`、`linuxStatus`・`linuxInstall`・`linuxRun`・`linuxRemove`・`workspaceClear`、対話セッション用の `sessionStart` ほか）。子プロセスを使うもの（`prootCheck`、Linux 環境）は、メインスレッドで呼ばない。通知は `ai.arce.app/notify`。
- **前面サービス**（`GenerationService`、通知つき。システムにプロセスを止められにくくする）：返信の生成、アプリの更新のダウンロード、モデルのダウンロードの 3 つの種類。MANIFEST は `foregroundServiceType="dataSync"`。
- **llama.cpp の JNI**（`arce_llama.cpp`）：JNI の関数名がパッケージ名（`ai.arce.app.engine.LlamaNative`）に結びついているので、**このパッケージ名を変えない**。`nativeStart` は、プロンプトを 1 回のパスでトークン化する（`prompt.size() + 8`。トークナイザが追加のトークンを足すときだけ再試行）。
- `applicationId` は `ai.arce.app`、最小は Android 12（API 31）、`targetSdk` は最新。native library は 16KB ページに対応してリンクする（Android 15 以降の端末向け）。`versionCode` は版から作る（`major*1000000 + minor*1000 + patch`。実行番号から作らない）。
- ネイティブのビルドには NDK 29.0.13113456 と CMake 3.22.1。GPU（Vulkan / OpenCL）は `gradle.properties` の `arce.ggml.vulkan` / `arce.ggml.opencl` を `true` にすると有効になる（実機で未検証のため既定は OFF）。llama.cpp は固定のコミット（81bc6b8、サブモジュール）。
- Kotlin の `core/` は Dart に移してあり、テストも `test/core` に対応がある。`lib/core` を変えたら、対応するテストも変える。
