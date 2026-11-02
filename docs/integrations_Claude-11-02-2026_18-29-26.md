# 外部との連携：MCP・Kaggle・検索・エラーの報告・GitHub Actions

現行の仕様だけを書く。**未確認**は、実機・実際のサービスで確かめていない。

## MCP（外部ツール）
- `lib/mcp/mcp_client.dart`：JSON-RPC 2.0 over HTTP（Streamable HTTP）。`initialize` → `notifications/initialized` → `tools/list` / `tools/call`。応答は JSON でも SSE（`data:` 行）でも読む。認証は `Authorization: Bearer <token>`。応答は **UTF-8 で復号する**（`utf8.decode(response.bodyBytes, allowMalformed: true)`。`package:http` の `response.body` は、`Content-Type` に charset が無いと Latin-1 で復号して日本語が化ける。GitHub の MCP サーバーは charset を付けない。`lib/core/http_get.dart` の GET も UTF-8 固定）。
- `lib/mcp/mcp_tools.dart`：サーバーのツールをアプリの `ToolDefinition` に変換する。名前は `mcp_<サーバー id>__<ツール名>`（id に `__` は使わせない）。`tools/list` はサーバーごとにキャッシュ。失敗したサーバーは、そのターンだけ外す（チャットは止めない）。呼び出しの失敗は `tool_response` としてモデルに返す。
- 設定：`mcpServers: [{id, name, url, enabled, approveWrites}]`。トークンは `mcp_token_<id>` で secure storage。旧 `mcpUrl` は `id=default` の 1 台に移行する。MCP サーバーの追加画面に「Kaggle を入れる」「GitHub を入れる」のひな形、「確認」ボタン（つながるか・道具の一覧が取れるか）。
- **書き込みの道具は、実行の前に確認カード**（`ToolApproval.needsApproval`）。道具の名前を**単語ごと**に分け（`create_or_update_file` も `CreateBenchmarkTaskFromPrompt` も）、書き込みを表す単語（create・update・delete・submit・start・cancel・stop・run・upload・publish・save・post・send ほか。`ToolApproval.writeVerbs`）に当たるかで判定する。部分文字列では判定しない（`ListDatasets` が「set」で確認になり、`Submit` / `Start` / `Cancel` が確認にならないため）。サーバー自体の id は読まない。サーバーごとの「書き込みの前に確認する」スイッチは既定オン。
- 端末のモデル（llama.cpp）では、MCP の複雑な JSON Schema が GBNF に重いので、**クラウドのモデル推奨**。stdio トランスポートは Android では難しい。**OAuth は未対応**（GitHub のホスト型サーバーは OAuth 前提のことが多い。いまは PAT をベアラーで送るだけ）。
- **道具が多いときは、探して呼ぶ**（`mcpOnDemand`、既定オン。`mcpOnDemandTokens`、既定 2000 トークン。0 で常に）：MCP の道具の定義は、毎回の送信に全部載る（GitHub の公式サーバーだけで数十個、数千トークン）。**定義の合計が `mcpOnDemandTokens` を超えるとき**は、定義を送らず、**3 つの道具**だけを渡す：`mcp_find`（`query`・`server` で探す。名前と 1 行の説明）、`mcp_describe`（1 つの道具の説明と引数の JSON Schema）、`mcp_call`（`tool` と `arguments`。呼ぶ）。`mcp_find` の説明に、サーバーの id・名前・道具の数が書いてある。
  - **`mcp_call` は、チャットが受け取った時点で、サーバーの道具そのものの呼び出し（`McpCall.unwrapped`）に直す**ので、確認カード・「次から確認しない」・実行は、本当の道具に対して働く（書き込みの道具は、承認を待つ）。`mcp_call` で届くのは `mcp_<サーバー>__<道具>` だけで、`run_command`・`update_settings` などアプリの道具には届かない。結果の長さは「MCP の結果の上限」で切る。
  - **やらないこと**：proot の中に `mcp` コマンドを置いて、コマンドから MCP を呼ぶ形。proot の中のコマンドは承認カードを通らずに MCP の道具（push など）を呼べてしまい（proot は境界ではない。`linux_environment`）、トークンを rootfs に置くか、橋渡しの口を開けることになるため。必要なら、利用者の指示で足す（`open_questions`）。
  - **未確認**：実機の、小さなモデル（端末）が「探す → 読む → 呼ぶ」の順を守れること（守れないときは、設定でオフにする）。
- **道具の結果がファイルのとき**（`McpClient.describeResult`）：`text` はそのまま。`resource`（結果の中のファイル）は、テキストなら中身（`[file: アドレス (種類)]` の下に）、バイナリなら説明だけ。`resource_link` は名前とアドレス。`image` / `audio` は種類と大きさだけ（**バイト列は渡さない**。モデルは読めず、何十万文字ものトークンになる）。`content` が無ければ `structuredContent`。全体は設定「MCP の結果の上限」（`mcpResultMaxChars`、既定 30000 文字）で切り、何文字省いたかを書く。画面には出さない（ファイルそのものを表示・保存する機能は無い。画像の表示は未対応）。
- MCP クライアントのリダイレクトの扱いは、セキュリティの点検をしていない（`verification`）。

## Kaggle
- Kaggle には**公式の MCP サーバー**がある（URL `https://www.kaggle.com/mcp`、Kaggle のブログによる）。道具の分野：ノートブック（管理・実行の開始と中止・出力）、コンペ（検索・メタデータ・データ・提出）、データセット、モデル、ベンチマーク。トークンは、Kaggle の設定 → API の「Generate New Token」。
- **未確認**：認証の方式。第三者の表では「OAuth 2.0 またはトークン、`npx mcp-remote` が必要」とある。アプリの MCP は**ベアラートークンだけ**で、ブラウザで承認する OAuth の流れには非対応。Kaggle のトークンがベアラーとして受け付けられるかは、実際に「確認」を押して確かめる必要がある。受け付けなければ OAuth への対応が要る。Kaggle の道具の実際の名前も未確認。
- **GPU の操作**：公式 MCP にノートブックの実行の道具があるかは未確認。アプリ内のモデルが `kaggle` コマンドを実行するには、アプリ内の Linux 環境（`linux_environment`。`pip install kaggle`）が要る（実機で未検証）。ほかの道：Raspberry Pi 5 に Kaggle 操作用の小さな MCP サーバーを置く、アプリに Kaggle の REST API を直接叩く道具を足す。
- まだ：Kaggle Models から**モデルのファイルを直接ダウンロードして端末で動かす**こと（いまのモデル一覧は Hugging Face。`kagglehub` のファイルの取り方が必要）。

## オンライン検索
- 検索の順は SearXNG（アドレスを入れたときだけ）→ 登録した検索 API（一覧の順、有効なもの）→ DuckDuckGo Instant Answer。Instant Answer は百科事典のような要約と関連項目だけを返す API（普通のキーワード検索の結果一覧は返らない）なので、アドレスが空だと、ほぼ空の答えだけになる。
- **検索 API を自由に登録できる**（設定 → 検索設定）：1 件の項目＝名前、URL、メソッド（GET / POST）、ヘッダー（JSON）、本文のひな形（POST）、API キー、「結果の場所」、題名・URL・概要の項目名、1 回の件数の上限（`maxCount`）、使う／使わない。URL・ヘッダー・本文の `{query}` が検索語、`{count}` が件数、`{key}` が API キーに入れ替わる（本文の中は JSON の文字列／数字として安全に入る）。結果の場所と項目名はドット区切り（`web.results` など。答えそのものが一覧なら空）。本文が JSON にならないときは保存の前に分かる。「試す」で、保存の前に 1 回検索して読み取れた件数を表示する。
- API キーは secure storage（`search_key_<id>`）。名前が機密らしいヘッダーは、値を `{key}` にしないと保存できない。**チャットからの追加・変更はできない**（URL を書き換えられると、保存済みのキーが別のサーバーに送られるため）。
- ひな形 13 件：Brave、Google カスタム検索、Tavily、Exa、Serper、Perplexity、Ollama、智谱（Zhipu）、Firecrawl、LinkUp、博查（Bocha）、Jina、秘塔（Metaso）。SearXNG は「SearXNG のアドレス」で使う。Tavily・Exa・Serper・Perplexity・Ollama・智谱は第三者の資料で形式が揃って見つかったもの、Firecrawl・LinkUp・Bocha・Jina・Metaso は一部の項目名が確かめられなかったので名前に「要確認」を付けた。Brave・Google などの検索 API のひな形の項目名は、公式で確かめていない。
- RikkaHub（Android の LLM アプリ）の検索サービスの一覧と比べて、**まだ対応していないもの**：Bing（検索ページを読む方式）、CustomJs、DeepSeek・Doubao・Grok（モデルに検索させる方式）、RikkaHub 自前、Tinyfish。使わない方法：DuckDuckGo の HTML ページの取得（公式の API ではなく、ブロックされやすい）。
- 検索のオン/オフは、チャットの入力欄の「検索」ボタン。
- 返信や検索結果のリンクは、http(s) だけ開く（`screens`）。

## エラーの自動報告（GitHub Issue）
アプリが落ちたとき・返信に失敗したときに、**1 件の Issue**（既定は `keusidan/arce.ai`）を作る。実装は `lib/core/error_report.dart`（報告の形・隠す処理・送るかの方針）と `lib/services/error_reporter.dart`（送信・上限・待ち行列）、`lib/services/error_hooks.dart`（Flutter / Dart の捕まえ損ねたエラーの受け口）。
- **送るもの**：エラーの種類（`crash` 捕まえ損ねた／`chat` 返信の失敗／`test` 設定画面の確認）、エラーのクラス名、短いメッセージ（400 字まで）、スタックのうちアプリ内の行（10 行まで）、状況（アプリの版・OS・端末か online か・プロバイダのホスト・モデル名）。**会話（質問・答え・ファイル）は送らない**。全ての文字列は `ErrorRedactor` を通す：キー・トークン・`Authorization`・既知のキーの形（`sk-`、`ghp_`、`github_pat_`、`AIza…`、`xox…`）・32 字以上の連続した英数字を `[removed]` / `[key]` / `[long-token]` に、URL はホストだけ残してログイン・パス・クエリを落とす。隠し過ぎる側に倒してある。
- **送るかの方針**（`ErrorPolicy`）：捕まえ損ねたエラーは、ネットワークの失敗（接続切れ・名前解決・タイムアウト）以外は送る。返信の失敗は、**アプリ側の不具合らしいものだけ**（HTTP 400 / 422、`not JSON`、プログラムの例外など）。API キーの誤り・401・403・404・429・5xx・タイムアウト・トークン超過のような、利用者の設定や相手側の事情のものは送らない。
- **同じ問題は 1 つの Issue**：署名（種類・クラス・数字や ID を除いたメッセージ・先頭のフレームの FNV-1a。HTTP の番号は残す＝400 と 422 は別の問題）が同じなら、新しい Issue を作らず**コメント**で件数を足す。同じ署名の報告は `errorReportMinHours`（既定 6 時間）に 1 回まで、全体で 1 時間に `errorReportMaxPerHour`（既定 5 件）まで。上限は設定画面（「エラーの報告」）とチャットの `AgentSettings` から変えられる。
- **送れなかったとき**：401・403・404 は、トークンかリポジトリが変わるまで止める（毎回失敗しない）。429・5xx・ネットワークは**待ち行列**（最大 20 件、端末に保存）に入れ、次の機会に送る。それ以外の失敗は捨てる。設定画面に直近の結果の一覧と「テスト送信」がある。
- **トークンは更新用と別**：Issue の作成には、**この 1 つのリポジトリだけ**に Issues: Read and write を付けた fine-grained のトークンを使う。リリースの更新用のトークンとは共有しない。secure storage（`github_issue_token`）に入り、設定の JSON・バックアップ・チャットには出ない。トークンが空なら送らない（設定画面に理由を表示）。
- **チャットからは変えられない**：`errorReportEnabled` と `errorReportRepo`（送り先）は `blocked`。書き換えられると、エラーの内容が別のリポジトリに送られるため。分や件数の上限だけがチャットから変えられる。
- **注意**：公開リポジトリの Issue は誰でも読める。メッセージにプロバイダのホストとモデル名が入る。非公開にしたいときは、送り先を非公開のリポジトリにする。
- 出典：Issues の作成 https://docs.github.com/en/rest/issues/issues#create-an-issue ／ コメントの作成 https://docs.github.com/en/rest/issues/comments#create-an-issue-comment ／ fine-grained のトークンの権限 https://docs.github.com/en/rest/authentication/permissions-required-for-fine-grained-personal-access-tokens ／ レート制限 https://docs.github.com/en/rest/using-the-rest-api/rate-limits-for-the-rest-api ／ Flutter のエラー処理 https://docs.flutter.dev/testing/errors
- **未確認**：実際の GitHub への送信（テストは HTTP の応答を差し替えたもの）。トークンの権限が足りないときの応答、実機で捕まえ損ねたエラーが受け口に届くこと。

## GitHub Actions の読み取り（`ci_status`）
- アプリに登録している GitHub の MCP サーバー（`api.githubcopilot.com/mcp/`）には **Actions の道具が無い**（トークンに全権限を渡していても、サーバーが公開していない）。そこで、アプリ自身の道具として足した。セルフホストの `ghcr.io/github/github-mcp-server` には Actions があるが、この環境からは確かめられていない。アプリ側に 1 つの道具を足すほうが小さく済む。
- `lib/services/ci_client.dart`：GitHub REST の `/repos/{owner}/{repo}/actions/runs`（`per_page`、`branch`）と `/actions/runs/{id}/jobs` を読むだけ（**書き込みはしない**）。`CiRun`（名前・イベント・ブランチ・短い SHA・状態・結論・URL）と、`CiJob`（状態・結論・**失敗したステップの名前**）。応答は UTF-8 で復号する。
- 道具 `ci_status`：引数 `repository`（既定は `keusidan/arce.ai`）・`branch`・`limit`（既定 10）・`run_id`。`run_id` を渡すとその実行のジョブと失敗したステップを返す。**読み取りだけなので、確認カードは出さない**。道具名は `mcp_` で始まらないので、MCP の道具と衝突しない。`ToolCallParser` は `run_command` と同じく、`McpCall` として扱って `McpTools` に渡す。
- トークン：`AppController._ciToken` が、**GitHub の MCP サーバーに入れてあるトークンをそのまま使う**（`id`/`name` が github、または URL が `githubcopilot.com` / `api.github.com`）。見つからなければ空で、**公開 API**（未認証）で読む（公開リポジトリなら足りる）。
- **未確認**：`Actions: Read` が無いトークンで 403 になるときの文言（`HTTP 403（トークンの権限に Actions: Read があるか確かめてください）` を出す）、非公開リポジトリでの動作（未認証では読めない）、実機での表示。
