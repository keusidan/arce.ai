# ARCE.AI（Flutter版）仕様書・引き継ぎメモ

- 作成日：2026-10-04（日本時間 18:58 時点の内容）
- 目的：新しいセッションが、会話の履歴なしで、この文書だけを読んで作業を続けられるようにする。コードを読めば分かること（個々の関数の動き）は書かず、**意図・決定・制約・未確認のこと**を書く。
- ブランチ：既定は `main`（2026-10-04 に、作業ブランチ `claude/great-lovelace-3lg7st` の先頭から作り、既定にした）。作業して push するブランチは、利用者が指定する（通常は `main`）。`claude/great-lovelace-3lg7st`（Flutter版の作業ブランチ）と `claude/new-session-5wz0e3`（以前の既定。Kotlin版）は履歴として残してあり、どちらの内容もすべて `main` に含まれている。
- リポジトリ：`keusidan/arce.ai`（非公開）

## 1. 何のアプリか

端末の中だけで動くローカルAIのチャット / コーディングアシスタント。Android・iOS・Windows・macOS・Linux で同じ画面が動く Flutter 製。
推論エンジンは **Android だけ**（llama.cpp と LiteRT-LM）。他のOSは、固定のデモ応答を返す `DemoEngine` で、画面・履歴・設定・更新機能だけが動く。

出自（git の履歴で追える）：
1. `d2147bf`：Kotlin（Jetpack Compose）の Android 専用版。推論、Python/Java 実行、署名付きAPKのリリースと更新まで入っていた。
2. `50cd4a5`：別のAIが書いた zip（`ARCE.AI-source_1.zip`）を、そのまま取り込んだスナップショット。
3. `6f22301` 以降：Flutter で書き直し。デザインは HTML 製の試作APK（`ARCE_AI_MVP.apk`）と、デスクトップのモック画像に合わせた。Kotlin の `core/` は Dart に移植し、テストも移した。

## 2. ディレクトリ

| 場所 | 内容 |
|---|---|
| `lib/core/` | 画面に依存しない中核。チャット制御、エージェント選択、プロンプト、ツール呼び出しの解釈、ストリーム分割、検索・天気・時刻、モデルカタログ、リリース解析、Artifact 抽出 |
| `lib/engine/` | `InferenceEngine` の実装：`NativeEngine`（Androidへの橋渡し）、`DemoEngine`、`HybridEngine`（読み込み済みならnative、なければdemo） |
| `lib/services/` | 設定、履歴、モデル管理とダウンロード、端末情報、更新（`update_service.dart`、`desktop_installer.dart`）、HTMLプレビューのサーバー、全体をまとめる `app_controller.dart` |
| `lib/ui/` | 画面。トークンは `theme.dart`、アイコン（SVG）は `svg_icons.dart` |
| `android/` | ネイティブ側。`src/main/cpp`（llama.cppのJNI）、`kotlin/ai/arce/app/engine`（エンジン）、`bridge`（Flutterとの橋渡し）、`update`（APKインストーラー） |
| `third_party/llama.cpp` | サブモジュール（Androidのビルドにだけ必要） |
| `test/` | `core/`（Kotlinから移したテスト＋追加）、`services/`、`ui/` |
| `docs/` | 企画書・助言書・過去の設計メモ・この文書・リリース手順書 |
| `.github/` | `ci.yml`、`release-<OS>.yml` ×5、共通の `actions/prepare` |
| `assets/` | アイコン（`icon/`）、同梱フォント Noto Sans JP（`fonts/`、SIL OFL） |

## 3. 画面の仕様

- **配置**：幅 900px 以上はデスクトップ配置（左サイドバー 280px、上バー 56px）、未満はスマホ配置（上のヘッダー＋下のナビ4つ）。`lib/ui/shell.dart`。
- **ページ**：チャット、モデル管理、生成物、詳細設定、チャット履歴（`AppPage`）。
- **チャット**：
  - 歓迎画面（4つのチップ）、メッセージ、思考プロセス（折りたたみ）、ツールの結果（検索はリンク付きで折りたたみ）、`ask_user` の質問カード、エラーと注意の帯、コピー・再試行・続行。
  - 生成中は「考えています…」のカード。アイコンは5種（基本・リング・パルス・ドット・ローテーション）から設定で選ぶ。
  - 入力欄：ファイル添付（UTF-8のテキストのみ、最大5件）、思考・検索のスイッチ、送信/停止。デスクトップは Enter で送信、Shift+Enter で改行。
  - コードブロックはコピーできる。HTML は「プレビュー」で、`PreviewServer`（127.0.0.1）経由でシステムのブラウザに表示する（サンドボックス付き）。
- **生成物**：会話の中の完成したコードブロックの一覧（コピー・保存・HTMLプレビュー）。無いときはサンプルを出す。
- **モデル管理**：現在の状態、基本モデルの1タップ導入、カタログ、ダウンロード（一時停止・再開・SHA-256検証・整合性チェック・削除）、ファイルからの取り込み、メモリ不足の警告。Android以外ではカタログを表示するだけで、ダウンロード・読み込みはできない。
- **詳細設定**：基本、回答（口調・速度⇔精度・エージェント・検索サーバー）、表示、開発者、アップデート。値の保存は `SettingsStore`（JSON1つ）。GitHubトークンだけは安全な領域（flutter_secure_storage）。
- **文字**：Noto Sans JP を同梱している（日本語の字形が中国語の字形にならないように）。

## 4. 中核の仕様（`lib/core`）

- **チャット制御**（`chat_controller.dart`）：1回の返信は「エージェントを選ぶ → プロンプトを作る → エンジンから流れてくる文字を `StreamSegmenter` で思考・本文・ツール呼び出しに分ける → ツール呼び出しなら実行して続ける、`ask_user` なら質問カードを出して待つ」の繰り返し。ツール呼び出しが途中で切れたら、設定の回数だけ書き直す。最大ツール回数を超えたらエラー。会話は返信の開始時（生成中フラグ付き）と終了時に保存する。
- **状態**（`TaskState`）：waiting / search / thinking / userWait / generation / completed / error / cancelled。遷移は `GenerationTask` が検査する。
- **エージェント**：General Chat / Coding / Research / Artifact / File Analysis。キーワードで選び、迷うときだけ（設定が有効で、モデルが読み込み済みなら）モデルに厳密なJSONで選ばせる。ユーザーが指定すればそれが最優先。
- **プロンプト**：Qwen3 の ChatML。口調は `<tone>` で囲み、制御用の文字列を取り除く（200文字まで）。
- **ツール**：`ask_user`、`web_search`（SearXNG → DuckDuckGo）、`get_weather`（Open-Meteo）、`get_time`（`timezone` パッケージ）。
- **モデルカタログ**：基本は Qwen3.5-0.8B（Q8_0）。Qwen3 の 0.6B〜14B（GGUF）と、LiteRT-LM の4種。NPU用は、そのSoCの端末にだけ出す。
- **Kotlin版からの違い**：Coding エージェントの説明から、Python/Java の実行とビルドの記述を外した（Flutter版には無いため）。

## 5. エンジンとAndroidの橋渡し

- Dartの `NativeEngine` と、Kotlinの `EngineBridge` は、`ai.arce.app/engine`（メソッド）と `ai.arce.app/engine/events`（イベント）でつなぐ。
- メソッド：`devices`、`load`、`generate`（`id` を渡す）、`cancel`、`unload`。
- イベント：`{id, type: piece|done|error, text/reason/message}`。1本のストリームを、`id` で振り分ける。
- 端末情報とAPKのインストールは `ai.arce.app/system`（`memory`、`freeStorage`、`soc`、`canInstall`、`requestInstall`、`install`）。
- llama.cpp のJNI（`arce_llama.cpp`）は Kotlin 版のまま。JNIの関数名がパッケージ名（`ai.arce.app.engine.LlamaNative`）に結びついているので、**このパッケージ名を変えない**。
- `applicationId` は `ai.arce.app`、最小は Android 12（API 31）。

## 6. 更新機能

- `UpdateService`：リリースの一覧（`/releases?per_page=50`）を読み、**自分のOSのタグ**の中で最も新しい版を選ぶ。起動時と、起動中は設定の間隔で確認する。ダウンロードは利用者が承認してから。`<ファイル>.sha256` で検証してから、インストール。
- Androidは PackageInstaller（同じ署名鍵のAPKだけ受け付けられる）。Windows・macOS・Linuxは、展開して、アプリの終了を待ち、ファイルを入れ替えて、再起動するスクリプトを走らせる（`desktop_installer.dart`）。iOSはリリースページを開くだけ。
- 非公開リポジトリのため、トークンが要る。アセットのダウンロードは、リダイレクト先にトークンを送らないよう、手でリダイレクトを追う。
- macOS は、自己更新のために App Sandbox を切っている（`macos/Runner/*.entitlements`）。

## 7. リリースとCI

### 7.1 タグとRelease（プラットフォームごとに別）

| OS | タグ | ファイル |
|---|---|---|
| Android | `vX.Y.Z` | `ARCE.AI-vX.Y.Z-android.apk` |
| iOS | `ios-vX.Y.Z` | `ARCE.AI-vX.Y.Z-ios-unsigned.ipa` |
| Windows | `windows-vX.Y.Z` | `ARCE.AI-vX.Y.Z-windows-x64.zip` |
| macOS | `macos-vX.Y.Z` | `ARCE.AI-vX.Y.Z-macos.zip` |
| Linux | `linux-vX.Y.Z` | `ARCE.AI-vX.Y.Z-linux-x64.tar.gz` |

- **Androidのタグだけ接頭辞なし、かつ「Latest」にする**：前のKotlin版のアプリ（v0.3.x が端末に入っている）が `releases/latest` の `vX.Y.Z` と `.apk` を読むため。他のOSは `--latest=false`。
- 各ファイルに `.sha256`。

### 7.2 ワークフロー

- `ci.yml`：push と PR で `flutter analyze` と `flutter test`。
- `release-android.yml` / `-ios.yml` / `-windows.yml` / `-macos.yml` / `-linux.yml`：それぞれ、判定（`.github/actions/prepare`）→ 解析とテスト → ビルド → 公開（`.github/actions/publish`：そのOSのReleaseにアップロード。Releaseが無ければ作る）。
- **Androidは「ビルド」と「公開」が別ジョブ**（`android` と `publish`）。公開だけ「Re-run failed jobs」で再実行できる。`reuse_run` に実行番号を入れた手動実行は、ビルドを省いてその実行のAPK（Artifact `android`、7日間）を公開する。他の4つは、ビルドのジョブの最後のステップで公開する。
- きっかけ：`pubspec.yaml` の変更をpush（どのブランチでも）、OSごとのタグ、手動実行（dry run あり）。Androidは `release-android.yml` と `prepare` の変更でも動く（失敗後の再試行）。
- 判定：そのOSのReleaseに、そのOSのファイルが既にあれば、pushでは何もしない。
- 版は `X.Y.Z` のみ（Windowsが版を数字として埋め込むため）。
- **ビルド番号（Androidの versionCode）＝ 主版×1,000,000 ＋ 副版×1,000 ＋ 修正版**（0.4.0 は 4000）。ワークフローの実行番号を使うと、分けたときに1から始まり、以前のAPK（14以下）より小さくなって、Androidが更新を拒否するため。
- Secrets（Android署名）：`ARCE_KEYSTORE_BASE64`、`ARCE_KEYSTORE_PASSWORD`、`ARCE_KEY_ALIAS`（登録済み。Kotlin版と同じ鍵）。
- Androidのジョブは、最初に使わないソフトを消してディスクを空ける。最初の実行が「No space left on device」で失敗したため。ccache は、`cache/restore` と `cache/save`（`if: !cancelled()`）に分けて、ビルドが失敗しても保存する（`save-always` は非推奨で、動かなかった）。
- 詳しい手順：`docs/ARCE_AI_flutter-release_Claude-10-04-2026_08-46-00.md`。

## 8. 確認できていること／できていないこと

**確認済み**
- `flutter analyze`、`flutter test`（70件）。CIでも成功。
- Linux のリリースビルドと起動、デスクトップ配置とスマホ配置の見た目（このセッションのLinux上で撮影）。
- Linux の自己更新スクリプト（置き換えと再起動）。
- AndroidのKotlin（橋渡しとインストーラー）は、Android 14 の API と Flutter の埋め込みに対して**型検査**だけ通した（LiteRT-LM はスタブに置き換え）。
- 古いAPK版のリリースの失敗の原因を特定して修正（ディスク不足）。
- AndroidのAPKがGitHub Actions上でビルドでき、署名の検証まで通ること（run 37192843146。約25分、132 MB）。

**未確認**
- **公開の修正後の動き**：`reuse_run` の経路と、タグを先頭に付け直す経路は、実際のReleaseで動いた（7.3）。**未確認**：ビルドと公開を1回の実行で通す普通の経路（次の版を出すときに初めて動く）、人が先に押したタグに対する公開、iOS・Windows・macOS・Linux の公開（共通の公開手順に差し替えたあと、一度も動いていない）。
- Windows・macOS・iOS のビルドと、各OSの自己更新の実機での動き。
- 実機のAndroidでの、モデルの読み込みと推論。
- GitHub のドキュメントなどの外部URL（`docs/` に載せた出典の一部）は、この環境から開けず未確認。

### 7.3 リリースの状況と、公開が断られた原因（2026-10-04 19:30 JST 時点）

**v0.4.0 のAndroid は公開済み**（https://github.com/keusidan/arce.ai/releases/tag/v0.4.0 ）。`ARCE.AI-v0.4.0-android.apk`（131,994,622 バイト、SHA-256 は `584a5a5a…bc3a4`）と `.sha256` が載り、「Latest」になっている。

- ビルド：run 37192843146（18:43〜19:08 JST、約25分）。署名の検証まで成功したが、**公開だけが `403 Resource not accessible by integration` で失敗**した。
- 公開：run 37195273978（19:24 JST。`release-android.yml` の手動実行で `reuse_run=37192843146`）。ビルドはせず、上のAPKをArtifactから取って公開した。ビルドしたコミット（60bb9ec）にはタグを付けられず、**タグはブランチの先頭に付いた**（Releaseの本文に、ビルド元のコミットを書いてある）。

**原因（切り分けて確認済み）**：`GITHUB_TOKEN` は `workflows` 権限を持てず、**`.github/workflows/` のファイルを追加・変更したコミットにはタグを付けられない**（APIは403、`git push` は `refusing to allow a GitHub App to create or update workflow ... without workflows permission`）。ただし**ブランチの先頭のコミットは対象外**。この run のコミット（60bb9ec）は `release-android.yml` を新規追加したコミットで、ビルド中にこちらが push したため、先頭ではなくなっていた。切り分けの結果（使い捨ての検証用ワークフローで実施。実行 37194771866 / 37194843041 / 37195030866）：

| 条件 | 結果 |
|---|---|
| 先頭のコミットを指定（push 起動でも手動起動でも） | 成功 |
| ワークフローを変えた古いコミットを指定（`gh release create`、API、`git/refs`、`git push`） | すべて失敗 |
| ワークフローを変えていない古いコミットを指定 | 成功 |
| `--target` にブランチ名（＝先頭）を指定 | 成功 |

v0.1.0（2026-09-26）が失敗した理由も同じ。以前の v0.1.1〜v0.3.1 が成功したのは、ビルド中に誰も push しなかったから。

**直し方**（`.github/actions/publish`、`release-android.yml` に反映済み）：公開を共通化し、ビルドしたコミットに付けるのを断られたらブランチの先頭に付け直す（本文に元のコミットを書く）。Androidは公開を別ジョブにし、`reuse_run` で、ビルド済みのAPKを再ビルドなしで公開できるようにした。
**未確認**：人が先に押したタグ（`git push origin vX.Y.Z`）に対する公開。ワークフローを変えたコミットへのタグは、この環境からは押せず（`remote end hung up`）、試せなかった。

- iOS・Windows・macOS・Linux の新しいワークフローは、まだ一度も動いていない。
- 状況は GitHub の Actions タブか、`mcp__github__actions_list` などで確認する。この節は古くなりやすいので、**鵜呑みにせず最新を見る**こと。

## 9. このセッションの環境の制約（次回も当てはまる可能性がある）

- 外部への接続は、プロキシで制限されている。**届かない**もの：`dl.google.com`（Android SDK、Google Maven）、`github.com` の他のリポジトリ（llama.cpp のソース等）、`docs.flutter.dev`、`docs.github.com`。**届く**もの：`storage.googleapis.com`（Flutter SDK）、`repo.maven.apache.org`、`raw.githubusercontent.com`、`fonts.googleapis.com`。
- Flutter SDK は、セッションの作業用フォルダ（一時）に置いていた。消えていたら、`storage.googleapis.com/flutter_infra_release/releases/stable/linux/flutter_linux_3.47.6-stable.tar.xz` から取り直す。`git config --global --add safe.directory '*'` が要る。
- Linux でビルド・画面確認するには `apt install clang cmake ninja-build pkg-config libgtk-3-dev libsecret-1-dev libjsoncpp-dev xvfb xdotool imagemagick fonts-noto-cjk`。画面は `xvfb-run` で起動し、`xdotool` で操作して `import -window root` で撮った。
- GitHub の操作は `mcp__github__*` のツール（`gh` コマンドは無い）。Actionsの実行は `actions_run_trigger`、状態は `actions_list`、ログは `get_job_logs`（実行中のジョブのログは取れない）。

## 10. 未対応・今後

- Kotlin版にあった **Python / Java の実行とビルド**（サンドボックス）、**バックグラウンド生成の前面サービス**、**WorkManager による更新の通知**は、Flutter版に移していない。
- Android以外の推論（llama.cppをFFIで各OSに入れる等）。
- 画面からのモデル選択の改良（モデルを別の画面でなく、チャットから切り替える等）。
- iOS の署名とTestFlight。macOS の公証。Windows のコード署名。
- 実機での検証（Android）。

## 11. 作業のルール（利用者の指定）

- 返答は日本語。時刻は**日本時間**で書く（UTC のまま書いて混乱させたことがあった）。
- 略称は初出で「略称(正式名称)」。英語由来の技術用語は英単語のまま。説明には出典を付ける。
- ファイル名の末尾に `Claude-MM-dd-yyyy_HH-mm-ss` を付ける（`docs/` の文書や、送る画像）。コードのファイルには付けない。
- PR は、頼まれるまで作らない。push するブランチは利用者が指定する（通常は `main`）。ブランチは、頼まれるまで作らない・消さない。
- コミットの末尾に、次の2行を付ける：
  `Co-Authored-By: Claude Sonnet 5.5 <noreply@anthropic.com>` と `Claude-Session: https://claude.ai/code/session_01DdPAuGoyns9ay81WpKxBKm`
- 署名鍵（`*.jks`）をリポジトリに入れない（`.gitignore` 済み）。
