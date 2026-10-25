# ARCE.AI ドキュメント（1 ファイルにまとめた版）

- 整理した日：2026-10-26（日本時間 02:16）。内容は v0.9.0 時点（7.6 と 17 章に 0.9.0 を追記）。
- 目的：会話の履歴なしで、この文書だけを読んで作業を続けられるようにする。コードを読めば分かること（個々の関数の動き）は書かず、**意図・決定・制約・未確認のこと**を書く。
- これは `docs/` にあった Claude 作成の文書 34 本（仕様書・リリース手順・機能ごとの記録・設計メモ・過去のレビュー）を 1 つにしたもの。**古くなっていた記述は、いまの実装に合わせて直した**。元の文書は git の履歴に残っている（コミット 36c4358 に全部ある。`git show 36c4358:docs/<ファイル名>`、一覧は `git ls-tree --name-only 36c4358 docs/`）。
- `docs/` に残したもの：`ARCE.AI企画書.txt`（利用者の企画書）と `ARCE.AI助言書.txt`（利用者の実装アドバイス・失敗ログ。AI に読ませる運用の文書）。利用者が書いたものなので、まとめの対象にしていない。
- ブランチ・コマンド・壊すと困る約束は `AGENTS.md`。これはツールがファイル名で読み込むので、別ファイルのまま。
- リポジトリ：`keusidan/arce.ai`。

## 目次

1. 何のアプリか・出自・ディレクトリ
2. 作業のルール（利用者の指定）
3. 画面の仕様
4. 中核の仕様（`lib/core`）
5. エンジンと Android の橋渡し
6. データの保存（履歴 DB・KV キャッシュ・添付）
7. クラウドのモデル（プロバイダ）
8. 設定の方針：機密情報以外は全て設定できる
9. コーディングモード（設計モデル＋開発モデル）
10. 外部との連携：MCP・Kaggle・検索
11. 更新とダウンロード
12. リリースと CI
13. 環境の制約と、過去のセッションの環境メモ
14. 確認できていること／できていないこと
15. 設計メモ：アプリ内の Linux 環境（proot）
16. 設計の経緯（機能拡張の草案と、初期の設計レビュー）
17. 版ごとの主な変更
18. 出典

---

## 1. 何のアプリか・出自・ディレクトリ

端末の中だけで動くローカル AI のチャット / コーディングアシスタント。Android・iOS・Windows・macOS・Linux で同じ画面が動く Flutter 製。
推論エンジンは **Android だけ**（llama.cpp と LiteRT-LM）。他の OS は、固定のデモ応答を返す `DemoEngine` で、画面・履歴・設定・更新機能だけが動く。ローカルの推論に加えて、オンラインのモデル（OpenAI 互換のプロバイダ）も、同じ立場の「エンジン」として使える（7 章）。

出自（git の履歴で追える）：
1. `d2147bf`：Kotlin（Jetpack Compose）の Android 専用版。推論、Python/Java 実行、署名付き APK のリリースと更新まで入っていた（`claude/new-session-5wz0e3`）。
2. `50cd4a5`：別の AI が書いた zip（`ARCE.AI-source_1.zip`）を、そのまま取り込んだスナップショット。
3. `6f22301` 以降：Flutter で書き直し（`claude/great-lovelace-3lg7st`）。デザインは HTML 製の試作 APK（`ARCE_AI_MVP.apk`）と、デスクトップのモック画像に合わせた。Kotlin の `core/` は Dart に移植し、テストも移した。
4. 以降は `main` が最新（作業ブランチは利用者が指定する。通常は `main`）。上の 2 つのブランチは履歴として残してあり、どちらも `main` に含まれている。

### ディレクトリ

| 場所 | 内容 |
|---|---|
| `lib/core/` | 画面に依存しない中核。チャット制御、エージェント、プロンプト、ツール呼び出しの解釈、ストリーム分割、プロトコル（ツール定義）、設定の仕様（`settings_spec.dart`）、検索、天気、モデルカタログ、リリース解析、Artifact 抽出、添付、コーディングの計画 |
| `lib/ai/` | プロバイダ抽象（`provider.dart`）、OpenAI 互換の通信（`openai_compatible.dart`）、`CloudEngine`、ChatML の分解（`chatml_bridge.dart`）、`RoutingEngine`、`CodingEngine`、モデルの上限と推奨（`model_info.dart`、`model_hints.dart`）、思考の送り方（`thinking_config.dart`） |
| `lib/engine/` | `InferenceEngine` の実装：`NativeEngine`（Android への橋渡し）、`DemoEngine`、`HybridEngine`（読み込み済みなら native、なければ demo） |
| `lib/data/` | 会話の DB（`llm_db.dart`、`conversation_snapshot_store.dart`、旧 JSON の取り込み）。Flutter に依存しない |
| `lib/services/` | 設定、プロバイダの保存、会話 DB・検索、KV スナップショット、モデルの管理とダウンロード、共通のダウンローダー、更新、差分更新（`bspatch.dart`）、端末情報、HTML プレビューのサーバー、全体をまとめる `app_controller.dart` |
| `lib/mcp/` | MCP クライアント（Streamable HTTP）と、サーバーのツールをアプリの道具に変換する部分 |
| `lib/ui/` | 画面。トークンは `theme.dart`、アイコン（SVG）は `svg_icons.dart` |
| `android/` | ネイティブ側。`src/main/cpp`（llama.cpp の JNI）、`kotlin/ai/arce/app/engine`（エンジン）、`bridge`（Flutter との橋渡し）、`service`（前面サービス）、`update`（APK インストーラー） |
| `third_party/llama.cpp` | サブモジュール（Android のビルドにだけ必要） |
| `third_party/proot` | サブモジュール（Termux の fork の proot、v5.1.107.101。15 章。`.github/workflows/proot-build.yml` だけが使う） |
| `test/` | `core/`（Kotlin から移したテスト＋追加）、`ai/`、`data/`、`mcp/`、`services/`、`ui/`（約 460 件） |
| `docs/` | この文書と、利用者の企画書・助言書 |
| `.github/` | `ci.yml`、`release-<OS>.yml` ×5、共通の `actions/prepare`・`actions/publish`、`proot-build.yml`（リリースではない。proot をビルドして artifact に残すだけ） |
| `assets/` | アイコン（`icon/`）、同梱フォント Noto Sans JP（`fonts/`、SIL OFL） |

---

## 2. 作業のルール（利用者の指定）

`AGENTS.md` に、壊すと困る約束がまとまっている。ここには、その背景と、AGENTS.md に載せていないものを書く。

- 返答は日本語。時刻は**日本時間**で書く（UTC のまま書いて混乱させたことがあった）。
- 略称は初出で「略称(正式名称)」。英語由来の技術用語は英単語のまま。説明には出典を付ける。
- 新しい docs のファイル名の末尾に `Claude-MM-dd-yyyy_HH-mm-ss` を付ける（既存のファイルの編集は元の名前のまま。ツールがファイル名で読むもの — `AGENTS.md`・`README.md` など — は付けない）。コードのファイルには付けない。
- PR は、頼まれるまで作らない。push するブランチは利用者が指定する（通常は `main`）。ブランチは、頼まれるまで作らない・消さない。
- コミットの末尾に、Co-Authored-By と Claude-Session の 2 行（セッションごとに指示される値）。
- 署名鍵（`*.jks`）をリポジトリに入れない（`.gitignore` 済み）。
- **すべての版を 5 つの OS で確かめる**：版を上げて push したら、Android・iOS・Windows・macOS・Linux の結果をすべて読む。赤い OS は、次のパッチ版で先に直す（Windows は 0.8.8〜0.8.15 の間、テストが Windows のパスを想定しておらず赤のまま、誰も見ていなかった）。テストは `/` をパス区切りと決めつけない。リストして得たパスが、入力したパスと同じ文字列になるとも決めつけない。
- **`main` を常に最新に**：5 つの OS で緑になった版を、リリースが終わってから `git push origin HEAD:main`（強制しない）で `main` に進める。最初の push と同時にやらない（版が上がる push が `main` にあると、リリースがもう一度始まる）。
- 5 つの OS のリリースは、それぞれ別の workflow で**並行**に動く。OS 間に `needs:` や `workflow_run` を置かない。同時実行のグループも共有しない（同じ OS の実行どうしだけ順番になる）。
- 外部から patch やコードを取ってきて当てる workflow、コミットを push する workflow は作らない（`apply-version.yml` がそれをして、毎回失敗していたので削除した）。
- 待ち合わせに固定の `sleep` を使わず、GitHub の応答で状態を確認する。
- 初期のレビューで決めた、利用者の判断：非公開・個人利用のためライセンス対応は不要（ただし GPL / AGPL の部品を同梱するときは別。15 章）、Google Play Store には出さない、EXE の生成は対象外、Termux 関連は実装しない。

---

## 3. 画面の仕様

- **配置**：幅 900px 以上はデスクトップ配置（左サイドバー 280px、上バー 56px）、未満はスマホ配置（上のヘッダー＋下のナビ 4 つ）。`lib/ui/shell.dart`。左上のハンバーガーが、スマホではドロワー（履歴の検索つき）を、デスクトップではサイドバーの開閉を担う。
- **ページ**：チャット、モデル管理、生成物、詳細設定、チャット履歴（`AppPage`）。
- **チャット**（0.8.18 で Claude のような文書型にした）：
  - 返信は、アイコン・名前・エージェント名・時刻・吹き出しの枠が無い。思考・ツールの表示・本文・操作ボタン（コピー・再試行・続行）を、上から幅いっぱい（最大 920px）に並べる。ユーザーの発言だけが吹き出し（右寄せ、幅は画面の 88% まで）。左右の余白は 12。
  - 歓迎画面（4 つのチップ）、思考プロセス（折りたたみ）、ツールの結果（検索はリンク付きで折りたたみ）、`ask_user` の質問カード、承認カード（設定の変更・MCP の書き込み・プロバイダの追加）、エラーと注意の帯。
  - 生成中は「考えています…」のカード（エージェント名は出さない）。アイコンは 5 種（基本・リング・パルス・ドット・ローテーション）から設定で選ぶ。
  - 入力欄：ファイル添付（画像と UTF-8 のテキスト。6 章）、思考・検索・分担（コーディングモード）のスイッチ、送信/停止。**モデルのボタンは無い**（モデルの管理は下のタブとヘッダーのモデル名から）。デスクトップは Enter で送信、Shift+Enter で改行。
  - コードブロックはコピーできる。HTML は「プレビュー」で、`PreviewServer`（127.0.0.1）経由でシステムのブラウザに表示する（サンドボックス付き）。
- **生成物**：会話の中の完成したコードブロックの一覧（コピー・保存・HTML プレビュー）。無いときはサンプルを出す。
- **モデル管理**：現在の状態、基本モデルの 1 タップ導入、カタログ、ダウンロード（一時停止・再開・SHA-256 検証・整合性チェック・削除）、ファイルからの取り込み、メモリ不足の警告。Android 以外ではカタログを表示するだけ。
- **詳細設定**：押した項目だけがその下に開くアコーディオン（同時に開くのは 1 つ。以前の「1 つの縦長の画面にスクロール」は、ほかの設定が混ざる原因だったので廃止した）。サイドバーなど外から開くときも、その項目だけを開く（`AppController.openSettings`）。項目：プロバイダ、オンラインモデル、ローカルモデル、コーディングモード、上限とタイムアウト、MCP、**モデル全般設定**（ローカルとオンライン共通：Thinking 表示・回答の口調・速度⇔精度・エージェント・返信の長さ・最大トークン・再試行・ツール呼び出しの上限）、**検索設定**（SearXNG のアドレス・検索結果の件数・検索 API の一覧）、表示（文字の大きさを含む）、アップデート。値の保存は `SettingsStore`（JSON 1 つ）。
- **文字**：Noto Sans JP を同梱している（日本語の字形が中国語の字形にならないように）。**文字の大きさ**（`fontScale`、0.7〜2.0。設定の選択肢は 85〜200%）は、アプリ全体に効き、端末の文字サイズの設定に**重ねて**効く（端末 130% × アプリ 150% で約 195%）。
- **チャット履歴の検索**：**タイトル**（大文字小文字を区別しない）と**本文**（全文検索。3 文字未満は `instr()`）。結果は会話ごとに 1 件にまとめ、一致した行を強調する（`conversation_search.dart`）。同じ部品（`HistoryPanel`）を、ドロワーとサイドバーで使う。
- **編集画面（プロバイダ・モデル・MCP・検索 API）**：下から出るシートの下の余白は、キーボードの高さかシステムのバーの高さの大きい方（`sheetBottomPadding`）。3 ボタンのナビゲーションバーが「試す」「保存」に重ならないように。
- **コーディングモードのモデル選択**：欄を押すと画面の幅いっぱいの一覧が下から開き、名前を省略せずに書く（以前は狭い一覧で「Google Gemini · gemini-2.5-fl…」のように切れて、同じ名前に見えた）。

---

## 4. 中核の仕様（`lib/core`）

- **チャット制御**（`chat_controller.dart`）：1 回の返信は「エージェントを選ぶ → プロンプトを作る → エンジンから流れてくる文字を `StreamSegmenter` で思考・本文・ツール呼び出しに分ける → ツール呼び出しなら実行して続ける、`ask_user` なら質問カードを出して待つ」の繰り返し。ツール呼び出しが途中で切れたら、設定の回数だけ書き直す。最大ツール回数を超えたらエラー。**同じ道具・同じ引数が 3 回続いたら**「同じ道具を繰り返し呼んでいます」で止める。会話は返信の開始時（生成中フラグ付き）と終了時に保存する。
- **状態**（`TaskState`）：waiting / search / thinking / userWait / generation / completed / error / cancelled。遷移は `GenerationTask` が検査する。
- **エージェント**：General Chat / Coding / Research / Artifact / File Analysis。キーワードで選び、迷うときだけ（設定が有効で、モデルが読み込み済みなら）モデルに厳密な JSON で選ばせる。ユーザーが指定すればそれが最優先。5 つ全部に `get_settings` / `update_settings` / `add_provider` を許可している。
- **プロンプト**：Qwen3 の ChatML。口調は `<tone>` で囲み、制御用の文字列を取り除く（200 文字まで）。
- **ツール**：`ask_user`、`web_search`、`get_weather`（Open-Meteo）、`get_time`（`timezone` パッケージ）、`get_settings`、`update_settings`、`add_provider`、MCP のツール（`mcp_<サーバー id>__<ツール名>`）。
  - 検索の順：SearXNG のアドレス（入れていれば）→ 登録した検索 API（一覧の順、有効なもの）→ DuckDuckGo Instant Answer。10 章。
  - 道具の定義が変わったので `Protocol.schemaVersion` は 4。
- **JSON の方針**（初期のレビューからの決定）：JSON は GBNF（llama.cpp の文法）で縛る。ただし、縛るのは**構造が必要な部分（質問タイル・tool call）だけ**で、本文は Markdown のまま。決まった合図（`<tool_call>`）が出たところから文法を効かせる（lazy grammar）ので、Thinking と本文は自由に書ける。Tool と質問の定義は JSON Schema で書き、llama.cpp の変換で文法にする。形式が崩れたときは修復せず、途中切断のときだけ再生成する。意味のチェック（`options` が空でない、など）は別に行う。Schema にはバージョン番号を付ける。出典：16 章の経緯と、18 章の llama.cpp の文書。
- **モデルカタログ**：基本は Qwen3.5-0.8B（Q8_0）。Qwen3 の 0.6B〜14B（GGUF）と、LiteRT-LM の 4 種。NPU 用は、その SoC の端末にだけ出す。GGUF と `.litertlm` は形式が違うので、エンジンごとに別の一覧。
- **Kotlin 版からの違い**：Coding エージェントの説明から、Python/Java の実行とビルドの記述を外した（Flutter 版には無いため）。

---

## 5. エンジンと Android の橋渡し

- Dart の `NativeEngine` と、Kotlin の `EngineBridge` は、`ai.arce.app/engine`（メソッド）と `ai.arce.app/engine/events`（イベント）でつなぐ。
- メソッド：`devices`、`load`（`kvType` ＝ 0 F16 / 1 Q8_0 / 2 Q4_0）、`generate`（`id` を渡す）、`cancel`、`unload`、`saveState` / `loadState`（KV キャッシュのファイル保存。6.2）。
- イベント：`{id, type: piece|done|error, text/reason/message}`。1 本のストリームを、`id` で振り分ける。
- 端末情報と APK のインストールは `ai.arce.app/system`（`memory`、`freeStorage`、`soc`、`canInstall`、`requestInstall`、`install`、`baseApk`、`startForeground`、`stopForeground`）。
- **前面サービス**（`GenerationService`、通知つき。システムにプロセスを止められにくくする）：返信の生成、アプリの更新のダウンロード、モデルのダウンロードの 3 つの種類。MANIFEST は `foregroundServiceType="dataSync"`。
- llama.cpp の JNI（`arce_llama.cpp`）は Kotlin 版のまま。JNI の関数名がパッケージ名（`ai.arce.app.engine.LlamaNative`）に結びついているので、**このパッケージ名を変えない**。
- `applicationId` は `ai.arce.app`、最小は Android 12（API 31。「最新から 5 年前まで」の決定）、`targetSdk` は最新。native library は 16KB ページに対応してリンクする（Android 15 以降の端末向け）。
- ネイティブのビルドには NDK 29.0.13113456 と CMake 3.22.1。GPU（Vulkan / OpenCL）は `gradle.properties` の `arce.ggml.vulkan` / `arce.ggml.opencl` を `true` にすると有効になる（実機で未検証のため既定は OFF）。llama.cpp は固定のコミット（81bc6b8）。

---

## 6. データの保存

### 6.1 会話の履歴：SQLite（`arce_llm.db`）

これまで 1 会話 1 ファイル（`conversations/<id>.json`）だったものを、SQLite に移した（0.4.2）。

- 層：画面（`history_page.dart`、ID は UUID の `String`）→ `conversation_database.dart`（DB を開く・旧 JSON の取り込み・`list/save/get/delete/clearGenerating/search`）→ `conversation_snapshot_store.dart`（画面のスナップショット `messages/history/nextId` を読み書き。Flutter 非依存）→ `llm_db.dart`（スキーマと DAO）。
- テーブル：`conversations`、`messages`、`parts`、`assets`、全文検索の `messages_fts`（FTS5 の `trigram`。日本語の部分一致が効く。3 文字未満は索引できないので `instr()` で補う）。WAL モード。DB は **schema 3**（`turns` に思考を持つ `reasoning` 列を足した。`ALTER TABLE` なので前の DB は思考なしで読める）。
- **決めたこと**：
  1. 保存は追記ではなく**置き換え**（`replaceMessages`）。画面は返信の開始時と終了時に会話全体を渡すので、追記だと生成中の返信が 2 行になる。メッセージ ID は位置（`<会話ID>@<seq>`）から作り、何度保存しても行が増えない。
  2. アプリが落ちた中断は `finish_reason = 'interrupted'` と書き、読み戻すときに `cancelled` にする。起動時の「続きから再開」が効くように、利用者の「停止」と見分ける。
  3. 旧 JSON の取り込みは毎起動でよい（ID が `legacy-<元の id>` なので冪等。ファイルは消さない）。
  4. モデル履歴（`turns` の user/assistant/tool）も DB に入れる。
  5. **設定・プロバイダ定義・API キーは DB に入れない**（設定 JSON と secure storage）。DB は会話データ専用。
- 保存の形式を SQLite 以外にするかを検討して、**SQLite のまま**にした：Isar（元のプロジェクトはもう積極的には開発されず fork に分かれた）、Realm（Atlas Device SDK が 2024-09 に deprecated、2025-09-30 に終了予定）、ObjectBox（検索した範囲では組み込みの全文検索が見つからず）、Hive / sembast（全文検索が無い）、専用の全文検索（Tantivy。履歴の規模では過剰）は選ばなかった。
- **巨大な塊（KV キャッシュ、モデルのファイル）はファイルに置き、索引だけを SQLite の `assets` に持つ**（`AGENTS.md` の規則）。

### 6.2 KV キャッシュ（0.8.1）

- 追加したもの：KV の型に **Q4_0**（F16 : Q8_0 : Q4_0 ＝ 64 : 34 : 18 バイト／32 値。既定は F16）。JNI の `nativeLoad` の最後の引数は `Boolean kvQ8` から `Int kvType`（0/1/2）に。量子化した V キャッシュには flash attention が要る。
- **ファイル保存**（設定「ローカルモデル → KV キャッシュをファイルに保存」。**既定はオフ**）：`llama_state_seq_save_file` / `llama_state_seq_load_file`（組み込み用の C API）を JNI から呼ぶ。保存するのは**最後のプロンプトの分だけ**（返信の分は次のプロンプトで再利用できないので捨てる）。
  - 保存先 `<アプリのデータ>/kv/<会話ID>.<指紋>.kv`。`.tmp` に書いてから rename。
  - 索引は `assets` の 1 行（`mime = application/x-llama-kv-state`）。会話を消すと行もファイルも消える。合計の上限（既定 1024 MB）を超えたら、最後に使った時刻が古い会話から消す（LRU）。行のないファイル・ファイルのない行は、保存のたびに片付ける。
  - **指紋**：モデルのファイル名・サイズ・文脈長・KV の型・アプリの版。1 つでも違うと読まない（llama.cpp の保存形式は版で変わりうる）。アプリを更新すると、保存済みは使われなくなり LRU で消える。
  - 保存するとき：会話の切り替え・新しい会話・バックグラウンドに回るとき。復元するとき：履歴から会話を開くとき（復元の直前に、利用者がもう書き始めていたら復元しない）。
  - 保存しないとき：プロンプトが短い（既定 512 トークン未満）、再帰・ハイブリッド系のモデル（Qwen3.5 など）、LiteRT-LM。
- 容量の目安：1 トークンあたり `2 × 層 × KV ヘッド × ヘッド次元 × 要素のバイト数`。Qwen3-14B 相当の F16 は 160 KiB/トークン（4096 トークンで約 640 MiB）。数百 MB になりうるので既定はオフ。
- 貼ってもらった方法のうち PagedAttention・RadixAttention・LMCache・vLLM は、サーバー向けで 1 台のスマホで llama.cpp を埋め込むこのアプリにはそのまま当てはまらない。prefix の再利用は、すでに `arce_llama.cpp` の `reuse_prefix` にある。

### 6.3 添付ファイル（画像とテキスト）

- 中身を**ファイルの先頭のバイト**で見て決める（拡張子は見ない）：画像（PNG / JPEG / GIF / WebP）、UTF-8 のテキスト（SVG・ソース・Markdown など）、それ以外は断る。画像は、画像に対応するモデルには画像として送り、対応しないモデル（端末のモデルを含む）には理由を出して断る（バイト列をテキストとして渡さない）。
- 上限は、画像が 1 枚 4 MB（Anthropic の 5 MB が最も低いため）、添付は 5 ファイルまで、テキストは 1 ファイル 8000 文字・合計 16000 文字（いずれも設定にした）。
- 「画像に対応する」は、モデルごとの設定（`ModelConfig.vision`、「画像を送る」スイッチ）。触っていないモデルは、名前から推測する（`gpt-4o`・`claude`・`gemini`・`llava`・`-vl` など。外れたらスイッチで直す）。送り方は OpenAI 互換の `image_url`（`data:` URL に base64）。
- 画像は、プロンプトの本文に目印 `<image id="…" name="…"/>` として置き、バイトは `GenerateRequest.images`（id → バイト）で別に運ぶ。id は中身の SHA-256 の先頭 16 文字。対応しないプロバイダには `[画像: ファイル名]` に置き換える。
- 制限：画像のバイトは**会話を開いている間だけ**メモリにある（開き直すと目印だけが残り `[画像: ファイル名]` として見える。保存するには `assets` とファイルへ書く必要がある）。画像は縮小しない。添付のチップは画像でもファイル名だけ。Anthropic など OpenAI 互換でない API の画像形式には未対応。

---

## 7. クラウドのモデル（プロバイダ）

### 7.1 構成

- `AiProvider`（`lib/ai/provider.dart`。Flutter 非依存）が、`Delta`（本文・思考・ツール呼び出し・使用量・停止理由）の流れを返す。`openai_compatible.dart` が chat-completions の SSE を読む：chunk の境界で切れた行の復元、`reasoning_content`（または `reasoning`）の分離、分割で届く関数呼び出しの引数の組み立て、`usage`、`finish_reason`。接続先ごとの差は headers / body の上書きで吸収。失敗は日本語で原因別。
- `CloudEngine implements InferenceEngine`：プロバイダを普通の推論エンジンとして扱う。`RoutingEngine` が、端末のエンジンとクラウドを要求ごとに振り分ける。`local` は予約 id（端末のモデルは、並んだプロバイダの 1 つ）。
- **決めたこと**：
  1. プロンプトは **1 本の ChatML のまま**。どちらのエンジンでも同じものを作り、クラウドに送るときだけ `ChatMlBridge` がメッセージ列に分解する。
  2. **続行**は、書けている本文を最後の assistant メッセージとして送り、「その続きから書く。繰り返さない」という user メッセージを足す（OpenAI 互換の API には prefill の口が無いため）。
  3. **API キーは設定に持たせない**（`provider_key.<id>`、実体は `flutter_secure_storage`）。設定 JSON のコピーや QR で、キーは出ない。
  4. **黙って乗り換えない**：選んだプロバイダが失敗したら、その失敗を見せる（端末で答え直さない）。画面の回答元と、実際に答えた相手がずれないように。
- **複数のプロバイダと、1 つに複数のモデル**（0.8.0）：`ProviderConfig.models`（`ModelConfig { id, name, params, prompt, … }`）と `activeModel`。前の「model 1 つだけ」の保存は、読み込み時に 1 件へ移行する。
- **ツールをクラウドへ渡す**（0.5.2）：以前は `CloudEngine` が `AiRequest.tools` を詰めておらず、プロバイダに道具の定義が一度も送られていなかった。`GenerateRequest.tools` を足して直した。`provider.capabilities.tools` が false のときは送らない。
- **思考**：クラウドは `reasoning_content` を読んで `<thinking>` として流す。モデルが返さない場合（`deepseek-chat` のような非 reasoning モデル）は出ない。端末は、速度⇔精度が 0.25 未満だと思考しない。続行の返信は思考を飛ばす。

### 7.2 モデルごとの上限と、公式の推奨（0.8.2）

きっかけ：DeepSeek V4.1 Flash が「少ししかいじらない」「指示を読めない」。調べると、最大トークンの既定が 2048（`effectiveMaxTokens` ＝ `maxTokens × (0.5 + 速度精度)`）で、思考の分で途中で切れていた。temperature / top_p も Qwen3 用の値のまま。

- `ModelConfig` に**コンテキスト長**（`contextTokens`）と**最大出力**（`maxOutputTokens`）。
- 最大トークンの決め方（強い順）：**モデルごとの設定 ＞ 設定画面でユーザーが決めた値 ＞ 公式の推奨 ＞ アプリの既定**。結果は、モデルの最大出力と、文脈に残った分（コンテキスト − 入力の見積もり − 512）に収める。temperature・top_p も同じ順。ユーザーが選んだ小さい値は下限で持ち上げない。
- **公式の推奨があるのは、モデルカードのあるバージョンだけ**：DeepSeek V4／V4.1（temperature 1.0・top_p 1.0・max_tokens ≥ 256K・文脈 1M）、GLM-5 以降（temperature 1.0・top_p 0.95・最大 64K〜128K）。それ以外は従来どおり。モデルの編集の「公式の推奨を入れる」で値が入る。`lib/ai/model_hints.dart`。
- 上限の引き上げ：モデルごとの最大トークン 131072 → 1,048,576。
- **自動取得**：①プロバイダの `GET /models`（文脈＝`context_length`・`context_window`・`max_context_length`・`max_model_len`・`inputTokenLimit`、出力＝`top_provider.max_completion_tokens`・`max_completion_tokens`・`outputTokenLimit`、画像・ツールの対応。**曖昧な `max_tokens` は読まない**）、②Hugging Face の `config.json`（モデル名が `owner/name` のとき、文脈長だけ。`max_position_embeddings`、`text_config` の中も読む。**モデル名だけ**を送る。設定でオフにできる）。いつ：使い始めたとき（モデルごとに 1 回）、プロバイダの「取得」、モデルの編集の「上限を取得」。**ユーザーが入れた値は、自動では消さない**。
- 確認の対象：DeepSeek V4.1 Flash の公式モデルカードと `encoding/README.md`、`deepseek-ai/deepseek-recipe`（既定の max_tokens は 8192／65536／131072）、GLM-5.3 の公式モデルカード。「DeepSeek Harness」は実在する公式（`deepseek-ai/deepseek-harness`、`dsh`、MIT、developer preview）だが、harness は agent を動かす側で、アプリが従うべき通信の仕様書ではない（仕様にあたるのはモデルカードの `encoding` と `deepseek-recipe`）。`HenryZ838978/deepseek-harness` は非公式の再実装、`deepseekharness.dev` など公式を名乗るサイトの数字は根拠にしない。

### 7.3 思考（推論）をプロバイダへ届ける（0.8.3）

モデルごとに**「思考の送り方」**（モデルの編集 →「思考（推論）」）。**既定は「送らない」**（提供元の既定で動く。DeepSeek も GLM も既定で思考する）。この間、チャットの思考スイッチはこのモデルに届かない（トーストで伝える）。

| 送り方 | 足す項目 |
|---|---|
| DeepSeek の API | `thinking: {type: enabled/disabled}`、思考オンなら `reasoning_effort` |
| Z.ai の API（GLM） | `thinking: {type, clear_thinking}`、思考オンなら `reasoning_effort` |
| chat template のサーバー（vLLM・SGLang・Together・DeepInfra など） | `chat_template_kwargs: {thinking, enable_thinking, thinking_mode, reasoning_effort, clear_thinking}` |
| OpenAI の形 | `reasoning_effort`（low/medium/high。max は high。オフは表せないので足さない） |
| 送らない | なし |

- 思考のオン/オフ：自動（チャットのスイッチと速度⇔精度に従う。速い側の端はオフ）／常にオン／常にオフ。推論の強さ：入れた値が先（`low`/`high`/`max` または 1〜100）、空欄はスライダーから（0.5 未満 `low`、0.85 未満 `high`、以上 `max`）。
- GLM の `clear_thinking`：GLM-5.3 のモデルカードが「チャットでは true を明示」と書いているので、GLM の「おすすめの送り方を入れる」は true を入れる。
- 「おすすめの送り方を入れる」：名前から選ぶ（`owner/name` は vLLM 系 → chat template、素の名前はメーカー自身の API）。**ボタンを押したときだけ**入る。
- 項目は、生成した項目のあと・プロバイダの「追加のリクエスト項目」より前に入る。同じ名前は、プロバイダの上書きが勝つ。
- コーディングモードの役は思考のスイッチを持たないので、「自動」を「思考オン（スライダーは中ほど）」として扱う。

### 7.4 ツールの会話の形と、思考を返す（0.8.4）

- モデルごとの**「ツールの送り方」**：自動（既定。提供元が対応していれば function calling、していなければテキスト形式）／function calling（`tools` に定義、呼び出しは `tool_calls`、結果は `tool` メッセージ。システムプロンプトから `# Tools` の説明を外す）／テキスト形式（Qwen 形式。`tools` は送らない）。どちらでも、ツールの説明は 1 回だけ。端末のモデルの会話は変わらない（変換は provider に渡す直前の `ChatMlBridge` だけ）。結果が返らなかった呼び出し（途中で止めた会話）は、テキストに戻して送る。
- **思考を返す**：各返信の思考を `AssistantTurn.reasoning` に残し（DB schema 3）、プロンプトの文字には入れず、`GenerateRequest.assistantReasoning` を通して provider の assistant メッセージの `reasoning_content` にする。モデルの設定「過去の思考を返す」：自動（DeepSeek・GLM で、ツールが function calling のとき）／常に返す／返さない。根拠は、DeepSeek の `encoding`（ツールを宣言すると過去の思考を全部残す）と、GLM の `clear_thinking: false`。

### 7.5 チャットからプロバイダーを追加する（0.8.5）

- 道具 `add_provider`（`name`・`base_url`・`models`・`tools`）。呼ぶと確認カードが出て、「追加する」を押したときだけ保存する。保存は必ず**新しい id の追加**で、既存のプロバイダーは変えない。使用中のプロバイダーも切り替えない。
- **既存のプロバイダーを変える道具は作っていない**（編集は設定画面だけ）。理由：チャットに紛れ込んだ指示で、API キーが保存済みのプロバイダーの URL を書き換えられると、キーが別のサーバーに送られるため。
- API キーの欄は無い（スキーマにも入れていない）。`base_url` に `user:pass@`・`?api_key=`・`#…` があれば拒否する。`/chat/completions` まで貼ってあれば落とす。ヘッダーと追加のリクエスト項目も、この道具では入れない。確認カードは URL をそのまま出す（キーを後で入れたときの送り先を、利用者が見て確かめられる）。

### 7.6 モデルの一覧・フォールバック・トークンの事前チェック・思考のメニュー（0.9.0）

- **SSE の UTF-8**：本文は `Utf8Decoder`（ストリーム版）で読む。以前は chunk ごとに復号していて、日本語（3 バイト）が chunk の境目で切れると `FormatException: Unfinished UTF-8 octet sequence` で返信が止まった（Gemini と、分担で多発）。境目を 1・2 バイトずらした 2 つのテストで再現する。
- **モデルの一覧（`catalog`）と、使うモデル（`models`）は別**。`catalog` は `/models` で取れた一覧（`ProviderConfig.catalog`、取得時刻 `catalogAt`）、`models` は上限・思考・プロンプトなどを設定した、使うモデル。一覧から選ぶと、`ProviderStore.selectModel` が `models` に写す。何百件もの一覧を、設定を持つ `models` に入れないため。
- **自動取得**：設定「モデル一覧を自動で読む」（`modelListAutoFetch`）と「再取得の間隔（時間）」（`modelListRefreshHours`）。起動時に、古くなった一覧を背景で読む。プロバイダを保存したとき（そのプロバイダの欄「一覧を自動で読む」が入っていれば）、すぐ読む。MCP サーバーを保存したときは、すぐ道具の一覧を読み（`probeMcp`）、その大きさ（トークン数の見積もり）を知らせる。
- **ツリー表示と検索**（`lib/ai/model_catalog.dart`、`model_tree.dart`、`lib/ui/model_tree_view.dart`）：モデル名の作者（`anthropic/`・`google/`・`deepseek-ai/` など、接頭辞）で分けて、Claude・Gemini・DeepSeek …の折りたたみにする。8 件以下の提供元は分けない。検索欄は大文字小文字を区別せず、空白で区切った語をすべて含むものが残る（`claude opus`）。提供元の名前にも当たる（`orca claude` は Orca の Claude 系）。検索中はすべての折りたたみを開く。コーディングモードの選択画面は、上に「最近使った」（`ProviderStore.recentRefs` 順。`markUsed` が返信を作るたびに記録。数は設定 `recentModelCount`、0 で出さない）と、提供元ごとのツリー。
- **フォールバック**（`lib/ai/fallback.dart`）：ルール `FallbackRule { from, targets, statuses }`。`from` と `targets` は `provider|model`、`provider|*`、`*` のどれか。具体的なルールが優先（モデル > 提供元 > `*`）。切り替える失敗の既定は 401・403・404・408・429、5xx すべて、接続の失敗。**返信の最初の 1 文字が来る前の失敗だけ**切り替え、書き始めたあとは切り替えない（途中まで書いたモデルのまま）。切り替えると、チャットに「A が 403 のため B に切り替えました」と出す。設定「フォールバックを使う」（`fallbackEnabled`）で一括して止められる。コーディングモードの設計・開発の役割にも効く。
  - **ルールの編集は設定画面（詳細）だけで、チャットからは変えられない**。会話の内容が別の提供元に送られるため、チャットの指示で送り先を足されると、プロンプトインジェクションで会話が外に出せてしまう（`add_provider` と同じ理由。7.5）。
- **トークンの事前チェック**（`lib/ai/token_budget.dart`）：送る前に、指示とツール定義の長さを見積もる（UTF-8 のバイト数 ÷ 3。目安）。モデルの文脈（`contextTokens`）がわかるモデルだけ。(1) 指示＋ツールが文脈の「割合」（設定 `tokenOverheadPercent`、既定 80%）を超える、または (2) 会話＋余白 256 が文脈を超える、のとき、**送らずに**エラーにする。エラーには、どの MCP サーバーのツール定義が大きいかを含める。設定 `tokenPrecheck` で止められる。見積もりは目安で、モデルのトークナイザとは違うので外れうる（割合を上げるか、チェックを止めて使う）。**実際のモデルとの照らし合わせは未**。
- **道具の呼び出しの繰り返し**：以前は「ラウンド数」（既定 4）で止めていて、検索を言い換えて 4 回するだけで「4 回を超えた」と止まった。いまは、**同じ道具・同じ引数の呼び出し**が繰り返されたときだけ止め、引数が違えば止めない。ラウンドの上限（`maxToolRounds`）は暴走の安全弁で、既定 30（保存済みの 4 は 30 に上げる）、最大 200。
- **思考の表示**：返信の上の「思考プロセス」を、既定で**開いたまま**にした（設定 `thinkingExpanded`。オフにすると、返信が始まったあとは折りたたむ。タップで開閉）。見出しに文字数を出す。`reasoning_content` または `reasoning` の欄を読む（7.1）。出さないモデルや、思考の送り方が未設定のモデルでは、出ないことがある。
- **入力欄の「思考」ボタン**（`lib/ui/thinking_sheet.dart`。RikkaHub の推論の選択に近づけた）：押すとシートが開く。オンラインのモデル：「考える量」（オフ／自動／その送り方が書いている強さ：DeepSeek・Z.ai は 低・高・最大、そのほかは 低・中・高）、「送り方」（`ThinkingFormat`）、送り方が未設定のときは提供元のアドレス・モデル名からの推測のボタン。選ぶと、そのモデルの `ThinkingConfig` に保存される（詳細の設定と同じ）。端末のモデル：思考のスイッチと、速度⇔精度のスライダー。送り方を変えると、新しい形が知らない強さ（DeepSeek の `medium` など）は外れる。
- **OpenRouter 形**（`ThinkingFormat.openRouter`）：`reasoning: {effort: low|medium|high}`、オフは `reasoning: {enabled: false}`。OpenRouter の公式 docs をこの環境から開けず、**リクエストの形は未確認**。実際のリクエストで確かめること（違えば「追加のリクエスト項目」で上書きできる）。
- **「詳細」画面**（`lib/ui/model_detail_page.dart`）：提供元ごとの一覧の取得、フォールバックのルール、トークンの事前チェック、MCP のコストの確認。入口は、モデルの一覧のシートと、思考のシートの「モデルの詳細設定」。
- 表示の言い換え：「モデル未導入」は「ローカルモデル未導入」（端末のモデルが無いとき。オンラインのモデルを使っているときは、そのモデルの名前を出す）。

---

## 8. 設定の方針：機密情報以外は全て設定できる

- **設定できないのは機密情報だけ**：API キー、GitHub トークン、MCP トークン、検索 API のキー。これらは安全な領域（`flutter_secure_storage`）に置き、設定の JSON・バックアップ・チャットのどこにも出さない。プロバイダの追加ヘッダーに `Authorization` や `x-api-key` のような（機密になりうる）名前は書けない。
- **それ以外は全て、設定画面から変えられる**。上限・タイムアウト・件数・サンプリング・プロンプト・モデルの選択・プロバイダのヘッダーとボディ。**コードに固定の数字を足すときは、設定も足す**。これまで固定だった値の例：添付（ファイル数・文字数・画像の MB）、検索結果の件数、通信・MCP・オンラインモデルのタイムアウト、ツールの繰り返し検出、更新ダウンロードの試行回数と無通信の判定、DRY。
- **チャットからも変えられる**（`update_settings`。変更はカードで見せ、承認してから反映）。対象は `AgentSettings.specs`（`lib/core/settings_spec.dart`）。チャットから変えさせないものは `blocked`（`lastModelPath`・`updateRepo`・`kvCache`）に理由つきで置く。プロバイダーは、**チャットからは追加だけ**できる（7.5）。
- **設定の読み書きの道具**（0.5.x）：
  - `get_settings`：変更できる設定を、現在値・ラベル・選択肢（日本語ラベル付き）・範囲つきで返す。プロバイダ構成・モデル一覧・MCP サーバー（URL・有効/無効・ツール名）・検索 API（名前・URL の `?` より前・有効か・キーの有無）も読める。**キーとトークンは伏せる**。承認は不要。
  - `update_settings`：1〜6 件の変更を提案し、**承認するまで何も書かない**（毎回）。承認待ちは `UiMessage.settings` として会話に保存され、再起動しても残る。適用は `withSettings(current, changes)` が JSON に書いて `AppSettings.fromJson` に型を決めさせるだけ（キーごとのコードは無い）。モデルに返す文には、いま何になったか（`theme=ダーク` など）と、「次にモデルを読み込んだときから有効」な項目（`contextLength` など）を入れる。
  - API キーを変える口は作らない（読み書きとも不可）。
- **ローカルとオンラインは別々**：端末のモデルは `local*`（temperature・top_p・top_k・min_p・DRY・最大トークン・追加プロンプト）、オンラインは `online*`（temperature・top_p・最大トークン・追加プロンプト）。優先順位は、オンライン＝モデルごとの設定 ＞ `online*` ＞ 既定、ローカル＝`local*` ＞ 既定。端末専用：コンテキスト長・スレッド・HyperLoad・GPU・KV キャッシュ・Force Execution。`AppSettings.toGeneration(modelParamsB, cloud: engine.isCloud)` が、答えるモデルの側を選ぶ。
- モデルごとに **画像を送る** スイッチ（6.3）。プロバイダには、ツール呼び出しの対応・追加ヘッダー・追加のリクエスト項目（JSON）の編集画面。
- 主な設定の例：`downloadConnections`（ダウンロードの同時接続数、既定 4）、`updateUseDelta`、`resumeDownloadsOnStart`、`fontScale`、`autoInstallUpdate`、`maxToolRounds`。

---

## 9. コーディングモード（設計モデル＋開発モデル）

設計モデルが開発モデルに指示し、複数のモデルで分担して安く実装する。

```
依頼（Coding エージェント）
  └ 設計モデル：JSON の計画（要約 + タスク）を返す  ← 高性能・短い出力
       ├ 開発モデル：タスク1 ┐
       ├ 開発モデル：タスク2 ├ 同時に書く（設定の数まで。端末のモデルは1つずつ）
       └ 開発モデル：タスク3 ┘
  └ 設計モデル：結果をレビュー → 直すところがあれば、そのタスクだけ書き直させる（回数は設定）
  └ 計画の順に結果を並べて返す
```

- 安くなる理由：長いコードを書くのは開発モデル（安い・端末のモデルなら無料）。設計モデルの出力は短い計画とレビューだけ。開発モデルには、会話の全体ではなく**依頼・計画の要約・そのタスク**だけを送る。
- 設計モデルが JSON の計画を返さないとき（質問・小さな依頼）は、その答えをそのまま返す（開発モデルは呼ばない）。1 つのタスクが失敗しても、ほかの結果は返す。
- 使うのは、Coding エージェントの**新しい返信**のときだけ（続きは元のエンジン）。オフ・役のモデル未選択・端末のモデル未読み込みのときは、いつもどおり 1 つのモデル。
- 役には、オンラインの各モデルも端末のモデルも選べる（`provider|model`、端末は `local|`）。
- 設定：オン/オフ、設計モデル、開発モデル、タスクの最大数（既定 4）、同時数（既定 3）、レビュー回数（既定 1。0 でレビューなし）、役ごとの最大トークン（**0 ＝ 自動**。モデルの推奨と上限に合わせる。推奨が無ければ 設計 8192／開発 16384）。チャットの入力欄に「分担」ボタン。
- 実装：`lib/core/coding_plan.dart`、`lib/ai/coding_engine.dart`（`CodingEngine`・`ProviderRole`・`LocalRole`）、`RoutingEngine.coding`。
- 既知の制限：開発モデルの出力は、全員が終わってから計画の順に出す（途中経過は「設計」「開発:」「レビュー」の行だけ）。トークンの使用量・費用の表示はまだない。Coding エージェントには、ファイルを読み書きする道具が無い（MCP でつなぐか、アプリに足す。未対応）。

---

## 10. 外部との連携：MCP・Kaggle・検索

### 10.1 MCP（外部ツール。0.6.0 → 複数サーバー 0.8.0）

- `lib/mcp/mcp_client.dart`：JSON-RPC 2.0 over HTTP（Streamable HTTP）。`initialize` → `notifications/initialized` → `tools/list` / `tools/call`。応答は JSON でも SSE（`data:` 行）でも読む。認証は `Authorization: Bearer <token>`。
- `lib/mcp/mcp_tools.dart`：サーバーのツールをアプリの `ToolDefinition` に変換する。名前は `mcp_<サーバー id>__<ツール名>`（id に `__` は使わせない。衝突を避ける）。`tools/list` はサーバーごとにキャッシュ。失敗したサーバーは、そのターンだけ外す（チャットは止めない）。呼び出しの失敗は `tool_response` としてモデルに返す。
- 設定：`mcpServers: [{id, name, url, enabled, approveWrites}]`。トークンは `mcp_token_<id>` で secure storage。旧 `mcpUrl` は `id=default` の 1 台に移行する。MCP サーバーの追加画面に「Kaggle を入れる」「GitHub を入れる」のひな形、「確認」ボタン（つながるか・道具の一覧が取れるか）。
- **書き込みの道具は、実行の前に確認カード**（`ToolApproval.needsApproval`）。道具の名前を**単語ごと**に分け（`create_or_update_file` も `CreateBenchmarkTaskFromPrompt` も）、書き込みを表す単語（create・update・delete・submit・start・cancel・stop・run・upload・publish・save・post・send ほか。`ToolApproval.writeVerbs`）に当たるかで判定する。以前の部分文字列の判定は、`ListDatasets` が「set」で確認になり、Kaggle の `Submit` / `Start` / `Cancel` が確認にならなかった。サーバー自体の id は読まない。サーバーごとの「書き込みの前に確認する」スイッチは既定オン。
- 端末のモデル（llama.cpp）では、MCP の複雑な JSON Schema が GBNF に重いので、**クラウドのモデル推奨**。stdio トランスポートは Android では難しい。
- 未対応：OAuth（GitHub のホスト型サーバーは OAuth 前提のことが多い。いまは PAT をベアラーで送るだけ）。

### 10.2 Kaggle（0.8.17）

- Kaggle には**公式の MCP サーバー**がある（URL `https://www.kaggle.com/mcp`、Kaggle のブログによる）。道具の分野：ノートブック（管理・実行の開始と中止・出力）、コンペ（検索・メタデータ・データ・提出）、データセット、モデル、ベンチマーク。アプリはこの MCP で、Kaggle の機能をまとめて使う。トークンは、Kaggle の設定 → API の「Generate New Token」。
- **未確認**：認証の方式。第三者の表では「OAuth 2.0 またはトークン、`npx mcp-remote` が必要」とある。アプリの MCP は**ベアラートークンだけ**で、ブラウザで承認する OAuth の流れには非対応。Kaggle のトークンがベアラーとして受け付けられるかは、実際に「確認」を押して確かめる必要がある。受け付けなければ OAuth への対応が要る。Kaggle の道具の実際の名前も未確認。
- **GPU の操作**：公式 MCP にノートブックの実行の道具があるかは未確認。アプリ内のモデルが `kaggle` コマンドを実行するには、アプリ内の Linux 環境（15 章）が要る。ほかの道：Raspberry Pi 5 に Kaggle 操作用の小さな MCP サーバーを置く、アプリに Kaggle の REST API を直接叩く道具を足す。
- まだ：Kaggle Models から**モデルのファイルを直接ダウンロードして端末で動かす**こと（いまのモデル一覧は Hugging Face。`kagglehub` のファイルの取り方が必要）。

### 10.3 オンライン検索（0.8.6〜0.8.12）

- きっかけ：「検索に失敗（ローカル AI のみで回答）: DuckDuckGo Instant Answer: no results」。検索の順が SearXNG（アドレスを入れたときだけ）→ DuckDuckGo Instant Answer で、Instant Answer は百科事典のような要約と関連項目だけを返す API（普通のキーワード検索の結果一覧は返らない）。アドレスが空だと、ほぼ空の答えだけが残っていた。
- **検索 API を自由に登録できる**（設定 → 検索設定）：1 件の項目＝名前、URL、メソッド（GET / POST）、ヘッダー（JSON）、本文のひな形（POST）、API キー、「結果の場所」、題名・URL・概要の項目名、1 回の件数の上限（`maxCount`）、使う／使わない。URL・ヘッダー・本文の `{query}` が検索語、`{count}` が件数、`{key}` が API キーに入れ替わる（本文の中は JSON の文字列／数字として安全に入る）。結果の場所と項目名はドット区切り（`web.results` など。答えそのものが一覧なら空）。本文が JSON にならないときは保存の前に分かる。「試す」で、保存の前に 1 回検索して読み取れた件数を表示する。
- API キーは secure storage（`search_key_<id>`）。名前が機密らしいヘッダーは、値を `{key}` にしないと保存できない。**チャットからの追加・変更はできない**（URL を書き換えられると、保存済みのキーが別のサーバーに送られるため）。
- ひな形 13 件：Brave、Google カスタム検索、Tavily、Exa、Serper、Perplexity、Ollama、智谱（Zhipu）、Firecrawl、LinkUp、博查（Bocha）、Jina、秘塔（Metaso）。SearXNG は「SearXNG のアドレス」で使う。Tavily・Exa・Serper・Perplexity・Ollama・智谱は第三者の資料で形式が揃って見つかったもの、Firecrawl・LinkUp・Bocha・Jina・Metaso は一部の項目名が確かめられなかったので名前に「要確認」を付けた。
- RikkaHub（Android の LLM アプリ）の検索サービスの一覧と比べて、**まだ対応していないもの**：Bing（検索ページを読む方式）、CustomJs、DeepSeek・Doubao・Grok（モデルに検索させる方式）、RikkaHub 自前、Tinyfish。使わなかった方法：DuckDuckGo の HTML ページの取得（公式の API ではなく、ブロックされやすい）。
- 検索のオン/オフは、チャットの入力欄の「検索」ボタン（設定の「Search」の切り替えと、チャットのハンバーガーメニューの「詳細設定」は、重なるので消した）。

---

## 11. 更新とダウンロード

### 11.1 アプリ内更新

- `UpdateService`：リリースの一覧（`/releases?per_page=50`）を読み、**自分の OS のタグ**の中で最も新しい版を選ぶ。起動時と、起動中は設定の間隔（既定 12 時間）で確認する。ダウンロードは、手動の確認では利用者が承認してから。`<ファイル>.sha256` で検証してから、インストール。
- **自動で更新する**（`autoInstallUpdate`、既定オン、0.5.2）：自動のチェックで新しい版を見つけたら、そのまま download → 検証 → install まで進む。手動の「確認する」は従来どおり（カードの「ダウンロード」を押してから）。iOS は自動では動かさない。Android は初回だけ、システムの画面で「この提供元を許可」が必要（許可前は `UpdateReady` のまま残り、許可後に「インストール」で入る）。失敗は `UpdateFailed` に理由が残り、画面に出る。
- Android は PackageInstaller（同じ署名鍵の APK だけ受け付けられる）。Windows・macOS・Linux は、展開して、アプリの終了を待ち、ファイルを入れ替えて、再起動するスクリプトを走らせる（`desktop_installer.dart`。アプリを置いたフォルダに書き込めることが条件。`C:\Program Files` のような場所では入れ替えに失敗して元の版のまま再起動する）。iOS はリリースページを開くだけ。macOS は、自己更新のために App Sandbox を切っている（`macos/Runner/*.entitlements`）。
- 非公開リポジトリのときは、設定の「GitHub トークン」（`Contents: read`）が要る。アセットのダウンロードは、リダイレクト先にトークンを送らないよう、手でリダイレクトを追う。トークンは端末の安全な領域に保存される。
- 起動時に、いま動いている版のダウンロードと古い版のファイルを削除する。再開に使える新しい版の `.part` は残す。デスクトップは展開完了後にアーカイブを削除する。
- 同じ署名鍵で更新すれば、モデル・DB・設定はそのまま引き継がれる。

### 11.2 ダウンロードの部品（0.8.8〜0.8.16）

**起きたこと**：Android で、ブラウザなら 100 Mbps 出る回線で、アプリのダウンロードが 1 Mbps ほどしか出なかった（更新もモデルも）。両方が遅いので、1 本の接続そのものが遅いと考えた（1 本の TCP は、パケットが落ちる回線や往復が長い回線で大きく遅くなる）。**本当の原因は端末で測れていない**。以下は、この仮説への対策。

- `FileDownloader`（`lib/services/file_downloader.dart`）：**モデルのダウンロードと更新が共有する**部品（0.8.15。以前は別々に同じ処理を持ち、0.8.13 のモデル側の直しが更新に入っていなかった）。1 つのファイルを、範囲要求（`Range`）に答える取得元から、大きければ**複数接続**で、途中のファイルから続きを、失敗したら**自動で取り直して**埋める。完成済み・長すぎる部分ファイル・サーバーが範囲を無視（200）・416 の扱い、無通信の判定、最後まで届かなかったことの検出、別 isolate での SHA-256 もここ。
- `SegmentedDownload`：同じ大きさの部分に分け、部分ごとに別の接続で取り、各部分を `<名前>.part.seg<番号>of<個数>` に書き、最後に連結する。1 部分は 4 MB 以上（小さいファイルは分けない）。中断しても部分ごとに取れた分が残る。接続数を変えたら前の部分ファイルは捨てる。サーバーが `Range` を無視したら 1 本に戻る。**部分ファイルは、パスの文字列ではなく、ファイルの名前で見分ける**（Windows では同じフォルダが `/` でも `\` でも書ける）。
- `DownloadErrors`（`CancelToken`、取り直す失敗の判定 `isTransient`、画面に出す文 `explain`）：取り直すのは、通信の失敗とサーバーが忙しいとき（HTTP 5xx・429）だけ。404 や 403、一時停止は取り直さない。エラーの文からは、CDN の署名付き URL（数百文字）を消す。
- 設定：「ダウンロードの同時接続数」（既定 4、1〜16。1 で従来どおり）、「ダウンロードの試行回数」（既定 3）、「ダウンロードの無通信の判定」。
- モデル側（`ModelDownloader`）に残るのは、Hugging Face のどこにあるか・大きさと SHA-256 を聞くこと・チェックして置くこと。更新側に残るのは、GitHub の API からの転送先の辿り方・`.sha256` の確認・差分更新・インストール。別のまま：HTTP クライアント（`http.Client`）は、モデルの取得・更新・検索・天気がそれぞれ持つ。
- **モデルのダウンロードが止まる問題**（0.8.13）：完成済みの `.part` に「続きから」の範囲要求を出して HTTP 416 で断られていた → 同じ大きさなら再取得せずチェックへ、長ければ捨てて最初から。接続を閉じられると手で「再開」が要った → 自動で取り直す。SHA-256（数 GB）を画面と同じスレッドから別 isolate に移した。
- **アプリを閉じているあいだも続ける**（0.8.14）：以前は、返信の生成と更新のダウンロードだけが前面サービスに載っていて、モデルのダウンロードは載っておらず、他のアプリを開くとプロセスが止められていた → モデルのダウンロードも前面サービスに載せた（通知「モデルをダウンロード中」）。**アプリを閉じて（最近使ったアプリから消して）止まったダウンロード**は、次の起動で取れた分から自動で続ける（設定「止まったダウンロードを次の起動で続ける」、既定オン）。ダウンロード中は、モデルの隣に目印のファイル（`<モデル名>.running`）を置き、終わる・一時停止すると消す。残っていれば、閉じて止まったもの。起動時、途中までのファイルがある未完成のモデルは「再開」の状態で出す。
  - **まだできないこと**：最近使ったアプリから**消した瞬間**、Android は画面と Flutter のエンジン（Dart のコード）を壊す。前面サービスはプロセスを残すが、ダウンロードをしている Dart のコードは止まる。消している間も進めるには、ダウンロードを Kotlin のサービスの中で行う（または Flutter のエンジンをサービスが持ち続ける）必要がある。実機で試せない環境では、起動できなくなる危険があるので入れていない。

### 11.3 差分更新（0.8.9・Android）

- **リリース側**：新しい APK を作ったあと、直近 3 つの前のリリースの APK から新しい APK への **bsdiff** のパッチを作り、同じリリースに載せる。名前は `ARCE.AI-v<新>-android.apk.from-<旧>.patch`。パッチが APK の半分より大きければ載せない。作るのに失敗しても、リリースは止めない（`continue-on-error`）。0.8.19 から、これは別ジョブ `patches`（12 章）。例：v0.8.19 のリリースには 0.8.16 / 0.8.17 / 0.8.18 からのパッチが付き、0.8.18 → 0.8.19 のパッチは 10 KB、0.8.17 → 0.8.18 は約 1.1 MB（APK は約 138 MB）。
- **アプリ側**（`UpdateService._tryDelta`）：①このリリースに、今の版向けのパッチがあるか調べる（なければ全体）。②インストール済みの APK の場所を聞く（`SystemBridge.kt` の `baseApk`。分割 APK でインストールされていれば無し）。③パッチをダウンロード（複数接続・再開は同じ経路）。④今の APK にパッチを当てて、新しい APK を作る（`lib/services/bspatch.dart`、別 isolate）。⑤新しい APK の SHA-256 を、リリースの `.sha256` と比べる。**一致したときだけ**使う。一致しない・途中で失敗した・土台が違う、のどれでも、作りかけは消して、**これまでどおり全体をダウンロード**する。
- パッチの形式は BSDIFF40（`bsdiff` や Python の `bsdiff4` が作る標準の形式。bzip2 の読み取りに `archive` パッケージ）。設定：「差分だけダウンロードする」（`updateUseDelta`、既定オン）。
- 確認済み：実際の `bsdiff4` が作ったパッチを、Dart が 1 バイトも違わずに適用できる。土台が違うとき・壊れたパッチを拒否する。
- **未確認**：インストール済みの `base.apk` が、リリースの APK とバイト単位で同じか（同じでなければ SHA-256 が合わず全体を取る）。実機で `baseApk` が読めるか。大きな APK にパッチを当てるときの時間とメモリ（古い APK・新しい APK・パッチを全部メモリに載せる）。ネイティブのライブラリ（`.so`）が毎回違うバイト列になると、パッチは小さくならない（実際には上のとおり小さくなっている）。
- 「キャッシング（差分更新）」は、この差分更新のこと。ビルドのキャッシュは別（12 章）。

---

## 12. リリースと CI

### 12.1 タグと Release（プラットフォームごとに別）

| OS | タグ | ファイル |
|---|---|---|
| Android | `vX.Y.Z` | `ARCE.AI-vX.Y.Z-android.apk`（arm64 と x86_64 を 1 つにした署名付き）＋ `.sha256` ＋ 差分パッチ |
| iOS | `ios-vX.Y.Z` | `ARCE.AI-vX.Y.Z-ios-unsigned.ipa`（未署名） |
| Windows | `windows-vX.Y.Z` | `ARCE.AI-vX.Y.Z-windows-x64.zip`（`Release` フォルダの中身＋ VC++ ランタイム DLL） |
| macOS | `macos-vX.Y.Z` | `ARCE.AI-vX.Y.Z-macos.zip`（`ARCE.AI.app`。ad-hoc 署名・公証なし） |
| Linux | `linux-vX.Y.Z` | `ARCE.AI-vX.Y.Z-linux-x64.tar.gz` |

- **Android のタグだけ接頭辞なしで、「Latest」にする**：前の Kotlin 版のアプリ（v0.3.x が端末に入っている）が `releases/latest` の `vX.Y.Z` と `.apk` を読むため。他の OS は `--latest=false`。Flutter 版のアプリは、`releases` の一覧から自分の OS の接頭辞のタグの中で最も新しい版を選ぶ。
- どのファイルにも `sha256sum` 形式の `.sha256`。
- 版は `X.Y.Z` のみ（Windows が版を数字として埋め込むため `-beta` は使えない）。
- **Android の `versionCode` ＝ 主版 × 1,000,000 ＋ 副版 × 1,000 ＋ 修正版**（0.4.0 は 4000）。ワークフローの実行番号を使うと、分けたときに 1 から始まり、以前の APK（14 以下）より小さくなって、Android が更新を拒否する。

### 12.2 ワークフロー

- `ci.yml`：push と PR で `flutter analyze` と `flutter test`。
- `release-android.yml` / `-ios.yml` / `-windows.yml` / `-macos.yml` / `-linux.yml`：それぞれ、判定（`.github/actions/prepare`）→ 解析とテスト → ビルド → 公開（`.github/actions/publish`：その OS の Release にアップロード。Release が無ければ作る）。5 つは**同時並行**で別々に動く（2 章）。同じ OS の実行どうしだけ `release-<os>-publish` で順番になり、待ちは最新の 1 つだけ残る（**push の間隔が詰まると、古い待ちの実行が取り消される**。0.8.7 と 0.8.8 の 1 回目が Android に出なかったのはこのため。次の版は、前の Android の実行が動き始めてから push する）。
- **Android は 5 つのジョブ**（0.8.19 から）：`prepare`（4 秒）→ **`test`（解析とテスト、約 73 秒）と `android`（ビルド、約 5 分）が並行** → `publish`（15 秒。`test` が成功、または `reuse_run` で省略したときだけ）→ `patches`（別ジョブ。差分パッチを、前の 3 つの版ごとに並行して作り、リリースに足す。約 68 秒。失敗しても全体は赤にならない。`continue-on-error`）。以前は test → build → patches を直列で行い、約 9 分かかっていた。他の 4 つは、ビルドのジョブの最後のステップで公開する。
  - 公開だけが失敗したら「Re-run failed jobs」で公開だけをやり直せる（25 分のビルドとそのキャッシュは無駄にならない）。`reuse_run` に実行番号を入れた手動実行は、ビルドを省いて、その実行の APK（Artifact `android`、7 日間）を公開する（版が違う APK は拒否する）。
  - Android のジョブは、最初に使わないソフト（.NET、Haskell など）を消して、ディスクを空ける（llama.cpp のコンパイルで容量が足りなくなったため）。ccache は `cache/restore` と `cache/save`（`if: !cancelled()`）に分けて、ビルドが失敗しても保存する（`save-always` は非推奨で動かなかった）。NDK のキャッシュ、Gradle のキャッシュ、Flutter / pub のキャッシュも使う。他の OS は Flutter SDK と pub のキャッシュだけ。
  - 一度、「Set up ccache」の apt で 26 分以上止まったことがあり、取り消して再実行した（以降は正常）。
- きっかけ：`pubspec.yaml` の変更を push（どのブランチでも）、OS ごとのタグ、手動実行（dry run あり）。Android は `release-android.yml` と `prepare` / `publish` の変更でも動く（失敗後の再試行。workflow を直して push すると、その版の Android が動き直す）。判定：その OS の Release に、その OS のファイルが既にあれば、push では何もしない（`main` への fast-forward で起動した実行が数秒で終わるのはこのため）。
- 各ワークフローは、自分のビルドの前に解析とテストを行い、通らなければ公開しない。

| 方法 | 動作 |
|---|---|
| `pubspec.yaml` の `version:` を上げて push | 5 つが動き、自分の Release にまだ無いファイルだけをビルドする。失敗した分は、修正を push すれば足りない分だけ作り直される |
| `git tag v0.5.0 && git push origin v0.5.0` | Android だけが動く（iOS は `ios-v0.5.0` など、OS ごとのタグ） |
| Actions タブ →「Release Android」などで「Run workflow」 | 選んだワークフローだけ、入力した版（空なら `pubspec.yaml` の版）で動く |
| Android の「Run workflow」で `reuse_run` を入力 | ビルドせず、その実行の APK を公開 |
| 「dry run」にチェック | Release は作らず、ビルド結果を Artifact（7 日間）に残すだけ |

### 12.3 最初に 1 回だけ行うこと

- **Android の署名鍵**：Secrets `ARCE_KEYSTORE_BASE64`・`ARCE_KEYSTORE_PASSWORD`・`ARCE_KEY_ALIAS`（登録済み。Kotlin 版と同じ鍵）。Flutter 版も同じ `applicationId` と鍵で署名するので、端末の Android 版（v0.3.x）に上書きインストールできる。Secrets が無いと、署名なしの APK では更新できないので、workflow はエラーで止まる（dry run を除く）。
  - 鍵の作り方：`keytool -genkeypair -v -keystore arce-release.jks -keyalg RSA -keysize 4096 -validity 36500 -alias arce`。**`arce-release.jks` と鍵のパスワードは、なくすと二度と更新を配れなくなる**。PC とは別の場所にもバックアップを取る。リポジトリには置かない。
  - Secrets への登録：`base64 -w0 ~/arce-release.jks | gh secret set ARCE_KEYSTORE_BASE64`、`gh secret set ARCE_KEYSTORE_PASSWORD`（入力を求められる）、`gh secret set ARCE_KEY_ALIAS --body arce`。ブラウザなら Settings → Secrets and variables → Actions → New repository secret。
  - debug 版からの切り替え：debug 鍵で署名された版は、release の APK で上書きできない。一度アンインストールする（アプリ内のモデルも消える）。
- **Actions の権限**：Release の作成には `contents: write` が要る（workflow に書いてある。組織の設定で読み取り専用に固定されていたら Settings → Actions → General → Workflow permissions を確認）。ビルドのジョブは読み取りだけで、書き込みは公開のジョブだけ。
- 無料枠：非公開リポジトリの Actions は、無料プランで月 2,000 分。macOS のランナーは実行時間が 10 倍で数えられる。

### 12.4 `.github/workflows/` を変えたコミットにはタグを付けられない

`GITHUB_TOKEN` は `workflows` 権限を持てないので、`.github/workflows/` のファイルを追加・変更したコミットには、タグ（＝Release）を付けられない（API は `403 Resource not accessible by integration`、`git push` は `refusing to allow a GitHub App to create or update workflow ... without workflows permission`）。ただし**ブランチの先頭のコミットは対象外**（2026-10-04 に、使い捨ての検証用ワークフロー（実行 37194771866 / 37194843041 / 37195030866）で切り分けて確認した）：

| 条件 | 結果 |
|---|---|
| 先頭のコミットを指定（push 起動でも手動起動でも） | 成功 |
| ワークフローを変えた古いコミットを指定（`gh release create`、API、`git/refs`、`git push`） | すべて失敗 |
| ワークフローを変えていない古いコミットを指定 | 成功 |
| `--target` にブランチ名（＝先頭）を指定 | 成功 |

- 25 分のビルドの途中で同じブランチに push すると、ビルド中のコミットは先頭でなくなる。そのコミットが workflow を変えていると、公開が断られる（v0.1.0 と v0.4.0 の最初の試行がこれで失敗した）。
- 直し方（`.github/actions/publish`）：まずビルドしたコミットにタグを付け、断られたらその時点のブランチの先頭に付け直す（Release の本文に「ビルドしたコミット」を書く）。
- 自分でタグを押すときは、workflow を変えていないコミット（例：版を上げただけのコミット）に付ける。workflow を直して push したあとは、ビルド中にさらに push しないほうが確実。
- 未確認：人が先に押したタグ（`git push origin vX.Y.Z`）に対する公開。

### 12.5 OS ごとの注意

| OS | 注意 |
|---|---|
| macOS | Apple Developer ID で署名・公証していないため、初回は右クリック → 開く、または「システム設定 → プライバシーとセキュリティ」で許可が要る。自己更新のため App Sandbox は切ってある。 |
| iOS | 未署名の ipa。実機に入れるには、AltStore や Sideloadly などで自分の Apple ID で署名する。TestFlight / App Store 配布には Apple Developer Program（有料）が要る。 |
| Windows | SmartScreen が「不明な発行元」と表示することがある（コード署名証明書が無いため）。 |
| Linux | 実行には GTK 3 と libsecret（GNOME Keyring など）が要る。無い環境でも動くが、GitHub トークンは保存されない。 |
| 推論 | Android 以外は推論エンジンが無い（デモ応答のみ）。 |

### 12.6 ローカルでの確認

```bash
flutter analyze && flutter test
flutter build linux --release        # このPCのOS用（Linux のパッケージは README.md）
```

Android のビルドには `third_party/llama.cpp`（サブモジュール）と Android SDK / NDK 29.0.13113456 が必要。初期の Kotlin 版は `./gradlew :core:test`（SDK 不要）でテストできた。

---

## 13. 環境の制約と、過去のセッションの環境メモ

**この文書を書いた時点のクラウドのセッション**：
- GitHub の操作は `mcp__github__*` のツール（`gh` コマンドは無い）。Actions の実行は `actions_run_trigger`、状態は `actions_list`、ログは `get_job_logs`（実行中のジョブのログは取れない）。
- 外部への接続はプロキシで制限されている。届いたもの：`storage.googleapis.com`（Flutter SDK）、`repo.maven.apache.org`、`raw.githubusercontent.com`、GitHub のツール経由。**届かなかったもの**：`dl.google.com`、各社の公式 docs の一部（Brave・Kaggle・Google の検索 API、`api-docs.deepseek.com`、`docs.z.ai`、`alpinelinux.org`、`docs.flutter.dev`、`docs.github.com`）。そのため、公式で確かめられていない事柄は、各章に「未確認」と書いてある。
- Flutter SDK はセッションの作業用フォルダ（一時）に置く。消えていたら `storage.googleapis.com/flutter_infra_release/releases/stable/linux/` の stable の tar.xz から取り直し、`git config --global --add safe.directory '*'` を行う。ローカルで `flutter pub get` を走らせると `pubspec.lock` が変わるので、コミットしない（`git checkout -- pubspec.lock`）。
- Linux でビルド・画面確認するには `apt install clang cmake ninja-build pkg-config libgtk-3-dev libsecret-1-dev libjsoncpp-dev xvfb xdotool imagemagick fonts-noto-cjk`。画面は `xvfb-run` で起動し、`xdotool` で操作して `import -window root` で撮れる。

**以前のセッションの環境（変わりうる）**：作業場所が aarch64 の proot の Ubuntu で、Flutter SDK が動かず（arm64 版が無く、x86_64 版は qemu でも `flutter_tools.snapshot` が Illegal instruction）、`flutter analyze` / `flutter test` は CI を検証手段にしていた。純 Dart のファイル（`lib/data`、`lib/ai`、`lib/core` の一部）は、小さな作業用パッケージにコピーして `package:flutter_test` を `package:test` に置換すれば、手元の `dart analyze` / `dart test` で回せた。GitHub API は未認証だと 1 時間 60 回で、ポーリングで使い切ったことがある。ジョブログは読めなかった（403）が、アノテーション（`/check-runs/{id}/annotations`）は読め、`::error::` を出すとアノテーションになる。

---

## 14. 確認できていること／できていないこと

**確認済み**
- `flutter analyze` と `flutter test`（約 520 件）が CI で成功。5 つの OS のリリースの workflow が、v0.8.19 で全部成功。
- Linux のリリースビルドと起動、デスクトップ配置とスマホ配置の見た目（Linux 上で撮影）、Linux の自己更新スクリプト。
- Android の APK が GitHub Actions 上でビルド・署名の検証・公開まで通る（現在は約 7 分、ccache 有効）。
- Kotlin のエンジンと橋渡しは、Android と Flutter の API だけ stub にしたコンパイルで型検査。C++（`arce_llama.cpp`）は、固定した llama.cpp のコミットのヘッダに対して `g++ -Wall -fsyntax-only` が警告なしで通る。
- リリースのパッチ（実際の Release で、v0.8.18 / v0.8.19 に付いている）と、`bsdiff4` が作ったパッチを Dart が適用できること。

**未確認（実機で確かめる必要がある）**
- 0.9.0 の、実際のオンラインのモデルとの往復：フォールバックが 403・429 で本当に切り替わるか、トークンの事前チェックの見積もり（実トークン数との差）、OpenRouter 形の思考のリクエスト、Gemini の思考（OpenAI 互換の応答に思考が出るか）、モデル一覧の自動取得。
- 実機の Android での、モデルの読み込みと推論、KV キャッシュの保存・復元、前面サービス、差分更新、ダウンロードの速度（複数接続で速くなるか。接続数 1 と 8 の比較の結果は未報告）、他のアプリを開いても続くか、チャットの見え方（長い返信、コードのカードの幅、文字 200% のときの設定画面）、3 ボタンのナビゲーションバーでの編集画面の余白。
- 実際のオンラインのモデルとの往復：ツール呼び出し（`reasoning_content` を**リクエストで受け取る**項目名、DeepSeek・Z.ai の HTTP の引数名は、公式 docs を開けず未確認。選んだ形で 400 が返るときは、プロバイダの「追加のリクエスト項目」で上書きする）、コーディングモードの設計→開発→レビューの往復、画像の送信、`/models` の応答（DeepInfra・Groq の欄名は公式で確認できなかった）。
- 小さい端末のモデル（0.8B）が、`update_settings` の `changes` 配列や `add_provider` を正しく書けるか。この形の JSON Schema が llama.cpp の `json_schema_to_grammar` を通るか。
- Brave・Google などの検索 API のひな形の項目名（公式で確かめていない）。Kaggle MCP の認証と道具の名前（10.2）。
- iOS・Windows・macOS の実機での自己更新と、DB の読み書き。旧 JSON から DB への取り込みを実データ量（数百会話）で試していない。
- 外部 URL（出典の一部）は、この環境から開けず未確認のものがある（18 章に注記）。

**未対応・今後**
- Kotlin 版にあった Python / Java の実行とビルド（サンドボックス）、WorkManager による更新の通知は、Flutter 版に移していない。Android 以外の推論（llama.cpp を FFI で各 OS に入れるなど）。iOS の署名と TestFlight、macOS の公証、Windows のコード署名。
- 履歴の画像の保存、送信前プロンプトのプレビュー（機能拡張の草案 P2）、使用量・費用の記録（`prompt_tokens` / `completion_tokens` / `cost_micros`。列はあるが書いていない）。
- アプリ内の Linux 環境（15 章）、OAuth の MCP、Kaggle Models の直接ダウンロード、アプリを消している間も続くダウンロード、Coding エージェントのファイルの読み書きの道具。

---

## 15. 設計メモ：アプリ内の Linux 環境（proot）

状態：**段階 1 の前半（proot のビルド）まで**。アプリ（`lib/`・`android/`）には、まだ proot・rootfs のコードは入っていない。CI で proot が arm64 向けにビルドできることは確認した（15.7）。機能拡張の草案の P7「エージェント環境」の続き。利用者の決定（2026-10-26）：**rootfs は Ubuntu を使ってよい。このままの方針で進める。**

### 15.1 目的

アプリ内のモデルが、端末の中で shell のコマンド（`git`、`python`、`pip`、`kaggle` など）を実行できるようにする。いまは MCP サーバーとオンライン検索しか外に出る手段が無く、`kaggle kernels push` のような操作ができない。

### 15.2 確認できたこと・できていないこと

| 事項 | 状態 | 出典 |
|---|---|---|
| Android 10 以降で `targetSdk` が 29 以上のアプリは、アプリのホーム領域のファイルを `execve()` できない。「APK に埋め込んだバイナリだけを読み込む」ことが求められている | 確認済み | [Android 10 の動作変更](https://developer.android.com/about/versions/10/behavior-changes-10) |
| PRoot のライセンスは GPL-2.0-or-later。ビルドには libtalloc（と libarchive）が要る | 確認済み | [proot-me/proot](https://github.com/proot-me/proot) |
| Termux は自前の fork（`termux/proot`、版 5.1.107.101、GPL-2.0）を、libtalloc と libandroid-shmem を付けてビルドしている。loader は実行のたびに展開せず別ファイルとして置く（`PROOT_UNBUNDLE_LOADER`） | 確認済み | [termux-packages の proot/build.sh](https://raw.githubusercontent.com/termux/termux-packages/master/packages/proot/build.sh) |
| RikkaHub は proot の本体と loader を `.so` の名前で同梱し、rootfs をダウンロードして展開する。ライセンスは AGPL-3.0 | 前の調査で確認（GitHub の画面の要約） | [rikkahub/rikkahub](https://github.com/rikkahub/rikkahub) |
| NDK 29 で proot（Termux の fork v5.1.107.101）を arm64 向けにビルドできる。`libproot` は約 270 KiB、loader は約 17 KiB。依存は `libc.so` と `libdl.so` だけ（libtalloc は静的に入れた）。16KB ページに揃っている | **確認済み**（`proot-build.yml` の実行。15.7） | CI の実行 |
| Ubuntu の rootfs（aarch64）の配布元・URL・版・SHA-256 | **未確認**（この環境から配布元に届くか未検証。Alpine の公式サイトには届かなかった） | — |
| proot が実機（Android 12 以降、各メーカーの seccomp 設定）で動くか | **未確認** | — |
| `useLegacyPackaging = true`（`.so` を APK の中で圧縮し、インストール時に端末へ展開する）にしたときの APK サイズ・端末内のサイズ・差分更新のパッチの大きさ | **測定済み**（15.8。APK は 131 MB → 68 MB、端末内の合計は約 117 MB で今より小さい、パッチは 1.1 MB → 5.9 MB） | `proot-package.yml` の実行 |

### 15.3 設計

```
モデル --(tool: run_command)--> ShellTool --(MethodChannel)--> Kotlin: ProotRunner
                                                                   |
                                  nativeLibraryDir/libproot.so  <--+   (APK に同梱した実行ファイル)
                                  filesDir/workspace/rootfs/        (ダウンロードして展開)
                                  filesDir/workspace/home/          (/workspace として見せる)
```

- **実行ファイル**：proot 本体と loader を `libproot.so`、`libproot_loader.so` の名前で `jniLibs/arm64-v8a/` に置き、起動時は `nativeLibraryDir` から `ProcessBuilder` で実行する。
- **rootfs**：初回に利用者が「Linux 環境を入れる」を押したとき、既存の `FileDownloader`（再開・複数接続・SHA-256 検証）でダウンロードし、Kotlin 側で展開する。APK には入れない。**Ubuntu**（`pip` や `apt` が使いやすい。容量は Alpine より大きい）。
- **展開**：`..` や絶対パスを含む名前は拒否する。シンボリックリンクが展開先の外を指さないか確かめる。
- **仕上げ**：`/etc/resolv.conf`（公開 DNS）、`/etc/hosts`、`/etc/hostname`、ロケールを書き込む。
- **実行**：`proot --kill-on-exit --link2symlink -r <rootfs> -w <cwd> -b <home>:/workspace` の中で、`env -i` で環境を空にしてからシェルを起動する。標準出力・標準エラー・終了コードを別々に返す。127 は「proot または rootfs が使えない」。
- **互換モード**：端末の seccomp で起動に失敗したとき `PROOT_NO_SECCOMP=1` で再試行する（設定で切り替え可）。
- **proot の入手**：`termux/proot` の特定の版（タグ）を**サブモジュール `third_party/proot` に固定**し、CI で**ソースからビルド**して `.so` として APK に入れる（libtalloc は、apt が署名を確認する Ubuntu のソースパッケージからビルドする）。出所がソースまで辿れ、GPL のソース提供がリポジトリで済む。Termux の配布 `.deb` から取り出す案は、バイナリの出所が第三者になり、方針（公式の一次情報だけを土台にする）に合わないので採らない。
- **パッケージングへの影響（測定済み。15.8）**：`android/app/build.gradle.kts` は `useLegacyPackaging = false`（`.so` を無圧縮で APK に置き、APK から直接読み込む）。この設定だと `nativeLibraryDir` に実ファイルが展開されず、`execve()` できない。実行ファイルを使うには `useLegacyPackaging = true`（`extractNativeLibs`）が要るが、llama.cpp の `.so` も展開されて端末内の容量が増える。asset に入れて起動時にコピーする方法は、上の W^X の制限で `execve()` できないので使えない。測定した（15.8）。

### 15.4 安全面

モデルが shell を実行できるようになるため、次を設定にし、既定は厳しくする（8 章の方針）。

- 確認カード：既定は毎回確認する（`run_command` は任意のコマンドなので、単語判定では足りない）。確認カードには、モデルの説明ではなく、実際のコマンドを表示する。
- 作業フォルダ：`/workspace` だけが端末のファイルに繋がる。アプリの他のデータ（設定、API キー、DB）は見せない。
- 時間の上限と出力の上限（設定項目）。
- ネットワーク：rootfs の中は端末の回線で外に出られる。通信を止める設定を用意する（既定は許可。`kaggle` などに必要）。
- API キー・MCP の token は rootfs に渡さない。Kaggle の token は、利用者が確認カードを見て、環境変数として明示して渡す。
- 外部の文章（検索結果、MCP の返答）に書かれた命令では実行しない。

### 15.5 ライセンス

- このリポジトリには LICENSE ファイルが無い。
- proot は GPL-2.0-or-later。実行ファイルを別プロセスとして同梱する形なので、APK に入れる場合は対応するソース（版とパッチ）を提供する必要がある。proot を CI でビルドするなら、リポジトリにビルドの手順とタグを置くことで足りる。**これは私の理解であり、法的な判断ではない。公開の前に、利用者が確認すること。**
- RikkaHub は AGPL-3.0。**コードは取り込まない**。仕組みの理解だけを使い、自前で書く。
- Ubuntu の rootfs は、配布元の条件に従う（個々のパッケージに、それぞれのライセンスがある）。
- Termux の terminal-emulator（Apache-2.0）は、対話ターミナル（段階 4）で使う候補。

### 15.6 段階

| 段階 | 内容 | 検証 |
|---|---|---|
| 1a | CI で proot をビルドする（`proot-build.yml`） | **完了**（15.7） |
| 1b | `useLegacyPackaging` の影響を測る（**完了**、15.8）。Android のビルドで proot を `jniLibs` に入れ、`useLegacyPackaging` を有効にし、起動だけを確かめる（`proot --version`） | CI のログ。実機での起動は利用者の確認が要る |
| 2 | rootfs（Ubuntu）のダウンロード・展開・仕上げ（Kotlin）と、設定画面の「Linux 環境」 | 展開のテストは単体で。実機での起動は利用者の確認が要る |
| 3 | `run_command` ツール（確認カード、時間・出力の上限、設定項目、`AgentSettings` との対応） | Dart の単体テスト |
| 4 | 対話ターミナル、`kaggle` の導入手順（`pip install kaggle`） | 実機 |

各段階は、1 つのバージョンとして出す。Android 以外は影響を受けない（他の OS は `run_command` を出さない）。


### 15.7 段階 1a の結果：proot のビルド（`proot-build.yml`、2026-10-26）

- 手順：NDK 29.0.13113456（sdkmanager）の clang（`aarch64-linux-android31`）で、①Ubuntu 24.04 のソースパッケージ `talloc`（2.4.2）を waf でクロスコンパイルして静的ライブラリにし、②サブモジュールの proot を、ソースフォルダのコピーの中でビルドする（`make proot loader/loader`）。結果は workflow の artifact `proot-arm64-v8a`（14 日）と、実行のアノテーションに出る。
- 結果：`libproot.so`（proot 本体）280,368 バイト、`libproot_loader.so`（loader）17,632 バイト（どちらも strip 後）。proot の動的な依存は `libdl.so` と `libc.so` だけ。PIE、`BIND_NOW`、LOAD の整列は 0x4000（16KB ページ対応）。loader は proot の中に埋め込まず別ファイル（`PROOT_UNBUNDLE_LOADER`）。実行時は環境変数 `PROOT_LOADER` でその場所を教える（fork のソース `src/execve/enter.c` で確認。未設定なら、ビルド時に決めた固定のパスを見に行く）。
- ビルドで必要だった回避（ソースは変えていない）：
  1. libtalloc の configure は、クロスコンパイルでは実行できない検査の答えを `cross-answers.txt` で求める。答えを入れた検査：uname、rpath、`--version-script`（FAIL）、getconf の大きなファイル、`HAVE_SECURE_MKSTEMP`、`C99 vsnprintf`、`strptime`、`HAVE_IFACE_*`、mmap 系（`HAVE_SHARED_MMAP`・`HAVE_MMAP`・`HAVE_MREMAP`・`HAVE_INCOHERENT_MMAP`）、`HAVE_FCNTL_LOCK`、`HAVE_FTRUNCATE_EXTEND`、`HAVE_BROKEN_READDIR`、`HAVE_WORKING_GETCWD`、`strtoll`。bionic（Android の libc）に当てはまる答えを、私の理解で入れた（実機で talloc を動かしての確認はまだ）。
  2. proot の makefile は、ソースフォルダの外でビルドすると VPATH のせいでパスが二重になる。→ ソースフォルダをコピーして、その中でビルドする。
  3. `src/extension/ashmem_memfd/ashmem_memfd.c` が `<string.h>` を読まずに `strcmp` / `memset` を使う。NDK 29 の clang は暗黙の関数宣言をエラーにする。→ `-Wno-error=implicit-function-declaration`（警告に戻す。リンク時に bionic の関数に解決される）。`-include string.h` を全体に付けると、自前で `basename()` を定義する loader が壊れる。
  4. `libandroid-shmem`（System V の共有メモリ）は使わない（任意の依存。無くてもビルドできる。`shmget` などは proot の中では動かない可能性がある。未確認）。
- **まだ確認していないこと**：実機での起動（`libproot.so` を `nativeLibraryDir` から実行して `--version`）、seccomp の設定が厳しい端末での動き、proot を APK に入れたときの `useLegacyPackaging` の影響（1b）。


### 15.8 段階 1b の測定：`.so` を展開する方式のコスト（`proot-package.yml`、2026-10-26）

実行ファイルは、ディスク上の実ファイルからしか起動できない。そのため proot を入れるには `useLegacyPackaging = true`（`android:extractNativeLibs`）が要り、アプリの**すべての** `.so` が、APK の中で圧縮され、インストール時に端末へ展開される。`proot-package.yml`（手動。何もビルドせず、実際のリリース 2 つを使う）で測った。

| 項目 | 今（`.so` を無圧縮で APK に置く） | 展開する方式 |
|---|---|---|
| APK のサイズ（ダウンロード） | 131.4 MB | **68.0 MB**（約半分） |
| 端末内の合計（APK ＋ 展開した arm64 の `.so`） | 約 131 MB | 約 117 MB（68.0 ＋ 48.8）。x86_64 と armeabi-v7a の分は圧縮のまま APK の中にあるだけで、展開されない |
| 差分更新のパッチ（0.8.17 → 0.8.18、UI の変更） | 1.1 MB | 5.9 MB（約 5 倍。圧縮された `libapp.so`（7.5 MB）の中の変更が、圧縮の流れ全体に広がるため。それでも全体の 68 MB の約 9% で、全体より十分に小さい） |
| 0.8.18 → 0.8.19（コードの変更なし） | 10 KB | 3 KB |

- arm64 の `.so` の内訳：`liblitertlm_jni.so` 20.8 MB、`libflutter.so` 11.2 MB、`libapp.so` 7.5 MB、`libarce_llama.so` 6.6 MB、`libsqlite3.so` 1.7 MB、`libomp.so` 0.9 MB。proot は約 0.3 MB を足す。
- 結論：**展開する方式にしても、ダウンロードも端末内の合計も、今より小さくなる**。代わりに、差分更新のパッチが大きくなる（それでも全体より小さい）。**未確認**：端末での起動時間の変化（インストール時に展開するので、起動のたびの展開はない）、更新のインストールにかかる時間の変化。
- 統合の方法（利用者の提案）：Android のビルドで、アプリのビルドの前に proot をビルドして（`.github/actions/proot`。サブモジュールの commit でキャッシュ）、できた `libproot.so` と `libproot_loader.so` を `android/app/src/main/jniLibs/arm64-v8a/` へ直接コピーし、`useLegacyPackaging` を有効にする。proot の成果物を別の場所に置いてあとで取りに行く形にはしない。

---

## 16. 設計の経緯

### 16.1 機能拡張の草案（2026-10-20。P0〜P7）

方針（決定済み）：①UI は現行の ARCE.AI のまま（`theme.dart` のトークンを維持）、②ローカル推論とクラウドを両方メインとして扱う（どちらも第一級のプロバイダ。会話単位・メッセージ単位で切り替え）、③チャット履歴は LLM 専用のデータベースに保存、④送信前にプロンプトをプレビューできるようにする。

組み込む機能（18 項目）：複数プロバイダ、送信前プロンプトプレビュー、マルチモーダル入力（画像・テキスト・PDF・Docx）、Markdown 描画（コードハイライト・LaTeX・表・図）、検索、MCP、Skills、エージェント編集、ファイルベースメモリ、プロンプト変数、キャラクターカード取込、設定の QR 共有（秘密情報は含めない）、カスタム HTTP ヘッダー／ボディ、メディア生成、AI 翻訳、音声（TTS / STT）、エージェント環境（proot）、Web access。

アーキテクチャの要点：①`AiProvider` に能力を申告させ、UI はフラグだけ見る（プロバイダ追加時に画面を触らなくて済む）、②ツール呼び出しの戦略を分離する（ローカルは文法で JSON を書かせる、クラウドは各社のネイティブな関数呼び出し。既存のローカル経路を壊さないため）。

**送信前プロンプトプレビュー（未実装）の設計**：入力欄の目アイコン（長押しで「プレビューして送信」、設定「送信前に必ず確認する」）。ボトムシートの 3 タブ：概要（エージェント／プロバイダ／モデル／有効なツール／添付／推定トークンの内訳／コンテキスト上限に対する割合／「端末内」か「外部送信」か）、プロンプト（実際に渡る文字列。制御用ブロックを強調）、送信ペイロード（POST する JSON。認証情報はマスク）。**プレビューと本送信が同一の `PromptAssembler` と `buildRequest()` を通る**構造にする（別実装にすると必ず乖離するため）。プレビュー画面からの編集は入れない（「プレビュー＝送信内容」の保証が崩れるため）。トークン推定は概算であることを画面に明記する。

フェーズ：P0 データ基盤（完了）→ P1 プロバイダ基盤（完了）→ P2 プロンプト基盤（プレビュー。未）→ P3 会話品質（マルチモーダル、Markdown 強化、プロンプト変数）→ P4 外部連携（検索・MCP は完了。Skills は未）→ P5 パーソナライズ（エージェント編集、メモリ、カード取込、QR、カスタムヘッダー）→ P6 生成系 → P7 環境（proot。15 章）。各フェーズのゲートは `flutter analyze` / `flutter test` / CI の APK ビルド。

履歴 DB のスキーマ案（`conversations` / `messages` / `parts` / `assets` / `messages_fts`）と書き込み方針（送信時に 1 トランザクション、生成中は 500ms 間隔のドラフト、論理削除）は、6.1 の実装のもとになった（実装では drift ではなく `sqlite3` を直接使い、書き込みは「置き換え」にした）。

未確定のまま：Web access を Flutter Web 同梱にするか軽量 UI を自作するか、トークン推定の精度、メモリ機能をファイルのままにするか DB 内のテーブルにするか。

### 16.2 初期の設計レビュー（2026-09-26。Kotlin 版の企画書 v1〜v3 と ARCEv2 まで）

利用者の企画書（`ARCE.AI企画書.txt` の前の版）に対して行った技術レビューの要点。決定事項は 2 章と各章に反映済み。

- **配布方法**：GitHub 配布（Play Store には出さない）に決まり、端末上でのビルドの道が開けた。Play Store の自動更新が無いので、GitHub Releases の API で新しい版を確認し、署名鍵を管理する更新機能が要る（11 章）。Android の開発者確認制度（Google が 2026 年から段階的に導入。Play Store 以外の配布も、確認済みの開発者の署名が要る）は、日本で配るときまでに登録が要る可能性がある。
- **サンドボックスの限界**：Android の権限はアプリ単位なので、同じアプリの中で動かしたコード（Chaquopy の Python、Termux 環境）は、モデル・履歴 DB・トークンを読み書きできる。本当に隔離できるのは `android:isolatedProcess="true"` の Service（承諾したファイルだけを `ParcelFileDescriptor` で渡す方式）か、別 APK（別 UID）だけ。「完全サンドボックス」ではなく、段階を分けて定義する（Artifact は WebView で強く隔離、生成コードは別プロセス＋専用の作業フォルダ＋実行前に承認で中程度）。WebView の機能を広げるときも `addJavascriptInterface` ではなく `WebViewCompat.addWebMessageListener` で、許可した origin と操作を 1 つずつ決める。
- **Termux を使わない道**：決定は「Termux 関連は実装しない」。Termux のパッケージは `/data/data/com.termux/files/usr` を前提にビルドされているので、別アプリでは動かない（自前のビルドが要る）。Termux のアプリ本体のコードは GPLv3。代わりの方法として、APK に `lib*.so` として同梱したプログラムは Android 10 以降も実行できるので、ECJ（Java のコンパイラ）→ D8 → aapt2（native 同梱）→ apksig（署名）を、アプリ内で順に呼ぶ独自のビルドを考えた（Gradle は使わない）。Python は Chaquopy（pip のパッケージはアプリのビルド時にしか入れられない）。EXE の生成は対象外（ソースコードの生成まで）。Flutter 版では、これらはまだ入っていない。
- **JSON の方針**：「全出力を JSON に縛る」と、回答の質が下がる（「Let Me Speak Freely?」の報告）、Qwen3 の `<think>` と衝突する、ストリーミング表示が難しくなる、Artifact を JSON の文字列に入れるとエスケープで小さいモデルほど品質が落ちる。→ 文法は構造が必要な部分だけ（lazy grammar）、本文は Markdown、Artifact は「JSON のメタ情報＋ code fence の本体」。
- **Search**：複数方式を併用するなら、順番を決める（Raspberry Pi 5 の SearXNG → 別の検索 API → ローカルだけで続ける）。結果の重複をまとめる。
- **Agent の自動選択**：選択自体が推論になり、1.7B クラスは間違えやすい。→ ルールで絞り、迷うときだけ AI。手動変更はいつでも可能。最低モデルサイズを満たさないときはユーザーに確認する。
- **Force Execution**：メモリ不足で強制実行すると、LMK（Low Memory Killer）が捕まえられないまま終了させる。生成の状態を先に保存し、次の起動で「前回は強制実行中に終了した」と出せるようにする。
- **NPU**：LiteRT は GGUF を読めない。NPU 経路には `.litertlm` と LiteRT-LM が要る（モデル一覧は別）。実装は最初は後回し、対応端末と対応モデルを確認してから。
- **端末のテスト**：GPU の系統（Adreno と Mali）の両方で機能テストを行う。
- **開発順序**：一番難しい部分（端末上のビルド、推論のストリーミング）を先に小さく試作して確かめる。Phase 0 の試作（llama.cpp → Qwen3 → ストリーミング → Thinking → JSON / GBNF → チャット UI）は、`:core` のテスト 35 件、llama.cpp と JNI のコンパイル、生成した GBNF が llama.cpp の文法パーサーで読めること（56 ルール）まで確認した。
- **アップデート機能の仕様**：定期確認（WorkManager、最短 15 分は Android の制限）、GitHub API の最新リリース、版の比較、通知、承認後のダウンロード（Wi-Fi のみの設定、続きから再開）、SHA-256 の照合、`PackageInstaller` の Session API、同じ署名鍵でないと拒否される（鍵のバックアップ）。非公開リポジトリは access token が要り、Android Keystore で暗号化して保存する。初回だけ「提供元不明のアプリ」の許可が要る。
- **その他の指摘**：同じ設定が 2 つの画面にあった（強制実行・エラー再試行回数）→ Developer Settings だけに置く。HyperLoad と Full Performance は別機能として分けず、性能優先モードとして統合する。Qwen3 2507 版の注意と 16KB ページサイズ対応（5 章に反映）。PDF で日本語が表示されない不具合（企画書 v2 修正版）。

---

## 17. 版ごとの主な変更

| 版 | 内容 |
|---|---|
| 0.1〜0.3.x | Kotlin 版（Android 専用）。署名付き APK の自動リリース（実行番号を `versionCode` にしていた） |
| 0.4.0 | Flutter 版の初版。5 つの OS のリリースと、アプリ内更新 |
| 0.4.2〜0.4.4 | 会話履歴を SQLite へ。更新のダウンロードを途中から再開。クラウド連携の土台（`AiProvider`、`CloudEngine`、`RoutingEngine`） |
| 0.5.x | 設定の読み書きの道具（`get_settings` / `update_settings`）、クラウドへの道具渡し、自動更新（0.5.0 は古い main から作ってしまった版で、使わない。0.5.2 が正しい系譜） |
| 0.6.0 | MCP 対応 |
| 0.7.0 | 設定が「一覧 → 詳細」に。下のバーは 4 つ |
| 0.8.0 | 複数のプロバイダと、1 つに複数のモデル。MCP の複数サーバー。前面サービスのバックグラウンド実行。同じ道具の繰り返しで止める（0.9.0 から、同じ引数のときだけ） |
| 0.8.1 | KV キャッシュの Q4_0 とファイル保存 |
| 0.8.2 | モデルごとの上限・公式の推奨・自動取得 |
| 0.8.3 / 0.8.4 | 思考をプロバイダへ届ける／ツールの会話の形と思考を返す |
| 0.8.5 | チャットからプロバイダーを追加（`add_provider`） |
| 0.8.6〜0.8.10 | オンライン検索：Brave、検索 API の自由な登録、POST、ひな形 13 件 |
| 0.8.8 | 複数接続のダウンロード |
| 0.8.9 | 差分更新（bsdiff） |
| 0.8.11 / 0.8.12 | 設定画面の整理（モデル全般設定・検索設定）、編集画面の余白、コーディングモードのモデルの選び方 |
| 0.8.13〜0.8.15 | モデルのダウンロードの失敗の修正、アプリを閉じても続くダウンロード、ダウンロード部品の共通化 |
| 0.8.16 | Windows のビルド（0.8.8 から赤だった）を直す |
| 0.8.17 | Kaggle（MCP のひな形）、書き込みの確認を単語ごとの判定に |
| 0.8.18 | チャットを文書型に、モデルのボタンの削除、文字の大きさの設定 |
| 0.8.19 | Android のリリースを高速化（test と build の並行、パッチの別ジョブ化）。`apply-version.yml` を削除 |
| 0.9.0 | SSE の UTF-8 の修正（Gemini・分担）。モデル一覧の自動取得・ツリー・検索、最近使った順、フォールバック、トークンの事前チェック、「詳細」画面、思考の表示と入力欄の思考メニュー、道具の繰り返しの判定を引数つきに（7.6） |

---

## 18. 出典

**Android**
- 実行権限（app home の execve）：https://developer.android.com/about/versions/10/behavior-changes-10
- PackageInstaller：https://developer.android.com/reference/android/content/pm/PackageInstaller ／ `setRequireUserAction`：https://developer.android.com/reference/android/content/pm/PackageInstaller.SessionParams#setRequireUserAction(int)
- アプリの署名：https://developer.android.com/studio/publish/app-signing ／ Keystore：https://developer.android.com/privacy-and-security/keystore ／ apksigner：https://developer.android.com/tools/apksigner
- 16KB ページ：https://developer.android.com/guide/practices/page-sizes ／ 前面サービスの種類：https://developer.android.com/develop/background-work/services/fgs/service-types ／ 通知の権限：https://developer.android.com/develop/ui/views/notifications/notification-permission
- isolatedProcess：https://developer.android.com/guide/topics/manifest/service-element#isolated ／ アプリのサンドボックス：https://source.android.com/docs/security/app-sandbox ／ 開発者確認：https://developer.android.com/developer-verification
- Flutter のビルドと配布：https://docs.flutter.dev/deployment ／ ビルド名・番号：https://docs.flutter.dev/deployment/android#reviewing-the-gradle-build-configuration ／ flutter_secure_storage（macOS）：https://pub.dev/packages/flutter_secure_storage#macos ／ macOS の App Sandbox：https://developer.apple.com/documentation/security/app-sandbox

**GitHub**
- Actions の課金（OS ごとの倍率）：https://docs.github.com/en/billing/managing-billing-for-your-products/managing-billing-for-github-actions/about-billing-for-github-actions
- `GITHUB_TOKEN` の権限（`workflows` の項目は無い。この環境から開けず中身は未確認）：https://docs.github.com/en/actions/security-for-github-actions/security-guides/automatic-token-authentication ／ 拒否の一次情報は、Actions の実行 37195030866 のログ（`X-Accepted-Github-Permissions: contents=write; contents=write,workflows=write`）
- `save-always` は非推奨：https://github.com/actions/cache/blob/main/save/README.md
- Releases API：https://docs.github.com/en/rest/releases/assets#get-a-release-asset ／ latest：https://docs.github.com/en/rest/releases/releases#get-the-latest-release
- Secrets：https://docs.github.com/en/actions/security-for-github-actions/security-guides/using-secrets-in-github-actions ／ `gh secret set`：https://cli.github.com/manual/gh_secret_set
- ランナーのイメージ：https://github.com/actions/runner-images/blob/main/images/ubuntu/Ubuntu2404-Readme.md

**モデル・プロバイダ**
- DeepSeek-V4.1-Flash-1017 モデルカード：https://huggingface.co/deepseek-ai/DeepSeek-V4.1-Flash-1017 ／ `encoding/README.md`：https://huggingface.co/deepseek-ai/DeepSeek-V4.1-Flash-1017/blob/main/encoding/README.md
- deepseek-recipe：https://github.com/deepseek-ai/deepseek-recipe ／ DeepSeek Harness（公式）：https://github.com/deepseek-ai/deepseek-harness ／ 非公式の再実装（根拠にしない）：https://github.com/HenryZ838978/deepseek-harness
- GLM-5.3 モデルカード：https://huggingface.co/zai-org/GLM-5.3
- OpenRouter の `/api/v1/models`：https://openrouter.ai/docs/sdks/typescript/models/modelslistresponse ／ Mistral のモデル一覧の項目：https://apis.io/schemas/mistral/mistral-model/ ／ Groq のモデルごとの上限：https://console.groq.com/docs/models
- OpenAI 互換の画像入力：https://platform.openai.com/docs/guides/images-vision ／ Anthropic の画像の上限（1 枚 5 MB）：https://docs.claude.com/en/docs/build-with-claude/vision ／ PNG の先頭バイト：https://www.w3.org/TR/png/#5PNG-file-signature ／ WebP：https://developers.google.com/speed/webp/docs/riff_container
- Qwen3 の推奨サンプリング設定と Thinking の切り替え：https://huggingface.co/Qwen/Qwen3-8B

**llama.cpp・推論**
- `llama_state_seq_save_file` / `llama_state_seq_load_file`、`LLAMA_STATE_SEQ_VERSION`：https://raw.githubusercontent.com/ggml-org/llama.cpp/81bc6b83f827df746eb129235488d325c49cae52/include/llama.h ／ KV の型：同 `common/arg.cpp` https://raw.githubusercontent.com/ggml-org/llama.cpp/81bc6b83f827df746eb129235488d325c49cae52/common/arg.cpp
- GBNF と JSON Schema：https://github.com/ggml-org/llama.cpp/blob/master/grammars/README.md ／ lazy grammar：https://github.com/ggml-org/llama.cpp/blob/master/docs/function-calling.md ／ OpenCL：https://github.com/ggml-org/llama.cpp/blob/master/docs/backend/OPENCL.md ／ Android の例：https://github.com/ggml-org/llama.cpp/tree/master/examples/llama.android
- 出力形式の制約と推論性能（Let Me Speak Freely?）：https://arxiv.org/abs/2408.02442 ／ LiteRT-LM：https://github.com/google-ai-edge/LiteRT-LM
- PagedAttention：https://ar5iv.labs.arxiv.org/html/2309.06180 ／ SGLang（RadixAttention）：https://arxiv.org/pdf/2312.07104 ／ vLLM の量子化 KV：https://docs.vllm.ai/en/latest/features/quantization/quantized_kvcache/ ／ LMCache：https://docs.lmcache.ai/developer_guide/architecture.html
- JNI の修正 UTF-8：https://docs.oracle.com/en/java/javase/21/docs/specs/jni/types.html#modified-utf-8-strings

**データ保存**
- SQLite FTS5 の trigram（3.34.0、3 文字未満は索引できない）：https://sqlite.org/forum/forumpost/76b444bebe?t=c ／ https://docs.bitfount.com/api/bitfount/cache/migrations/indexes/create_patients_search_index
- Isar の fork：https://pub.dev/packages/isar_db ／ https://pub.dev/documentation/isar_community/latest/ ／ Realm の deprecated：https://pub.dev/documentation/realm/latest/ ／ https://mongodb.com/docs/realm ／ flutter_tantivy：https://pub.dev/documentation/flutter_tantivy/latest/

**ダウンロード・更新**
- Mathis ほか「The macroscopic behavior of the TCP congestion avoidance algorithm」（1997）：https://dl.acm.org/doi/10.1145/263932.264023 ／ HTTP の範囲要求（RFC 9110 §14）：https://www.rfc-editor.org/rfc/rfc9110.html#name-range-requests
- Colin Percival, "Naive differences of executable code"（bsdiff）：https://www.daemonology.net/bsdiff/ ／ bsdiff4（Python）：https://github.com/ilanschnell/bsdiff4 ／ archive パッケージ（BZip2）：https://pub.dev/packages/archive

**検索・Kaggle・MCP**
- Brave Search API：https://api.search.brave.com/app/documentation/web-search/get-started ／ 認証：https://api-docs.search.brave.software/guides/authentication ／ Google Programmable Search：https://developers.google.com/custom-search/v1/overview
- RikkaHub の検索サービスの一覧：https://github.com/rikkahub/rikkahub/tree/master/search/src/main/java/me/rerere/search ／ Tavily：https://help.tavily.com/articles/4840311948-tavily-search-api ／ Ollama：https://lzw.me/docs/ollama/zh-CN/capabilities/web-search.html ／ Perplexity：https://docs.perplexity.ai/guides/search-quickstart ／ Exa：https://docs.exa.ai/reference/getting-started-with-curl ／ 智谱：https://docs.bigmodel.cn/api-reference/%E5%B7%A5%E5%85%B7-api/%E7%BD%91%E7%BB%9C%E6%90%9C%E7%B4%A2.md ／ SearXNG：https://docs.searxng.org/
- Kaggle の公式 MCP サーバー（ブログ）：https://www.kaggle.com/blog/kaggles-official-mcp-server ／ 公式のリモート MCP の URL の記載（第三者の README の要約）：https://github.com/Galaxy-Dawn/kaggle-mcp ／ Kaggle のコマンドライン：https://github.com/Kaggle/kaggle-cli/blob/main/docs/README.md ／ kagglehub：https://github.com/Kaggle/kagglehub

**proot**
- [proot-me/proot](https://github.com/proot-me/proot) ／ [termux-packages の proot/build.sh](https://raw.githubusercontent.com/termux/termux-packages/master/packages/proot/build.sh) ／ [rikkahub/rikkahub](https://github.com/rikkahub/rikkahub)

**設計レビュー（16.2）**
- Termux の fork の注意：https://github.com/termux/termux-app#forking ／ パッケージのビルド：https://github.com/termux/termux-packages/wiki/Building-packages ／ Termux のライセンス：https://github.com/termux/termux-app/blob/master/LICENSE.md ／ termux-api：https://github.com/termux/termux-api
- ECJ：https://github.com/eclipse-jdt/eclipse.jdt.core ／ D8：https://developer.android.com/tools/d8 ／ apksig：https://android.googlesource.com/platform/tools/apksig/ ／ Chaquopy：https://chaquo.com/chaquopy/ ／ `addWebMessageListener`：https://developer.android.com/reference/androidx/webkit/WebViewCompat#addWebMessageListener(android.webkit.WebView,java.lang.String,java.util.Set%3Cjava.lang.String%3E,androidx.webkit.WebViewCompat.WebMessageListener) ／ `PerformanceHintManager`：https://developer.android.com/reference/android/os/PerformanceHintManager ／ WorkManager の定期実行：https://developer.android.com/develop/background-work/background-tasks/persistent/getting-started/define-work#schedule_periodic_work
