# 確認できていること／できていないこと、環境の制約

現行の状態だけを書く（1.0.1 時点）。実機で確かめるのは利用者の作業。

## 確認済み
- `flutter analyze`（問題なし）と `flutter test`（約 1,200 件）が CI で成功。5 つの OS（Android・iOS・Windows・macOS・Linux）のリリースの workflow が、1.0.0 と 1.0.1 で全部成功。
- Linux のリリースビルドと起動、デスクトップ配置とスマホ配置の見た目（Linux 上で撮影）、Linux の自己更新スクリプト。
- Android の APK が GitHub Actions 上でビルド・署名の検証・公開まで通る（約 7 分、ccache 有効）。APK の中の proot の 2 つの `.so` が、ビルドしたものと同じバイト列であることも CI が確かめる。
- Kotlin のエンジンと橋渡しは、Android と Flutter の API だけ stub にしたコンパイルで型検査。C++（`arce_llama.cpp`）は、固定した llama.cpp のコミットのヘッダに対して `g++ -Wall -fsyntax-only` が警告なしで通る（`nativeStart` の変更は構文検査のみ。APK はこの環境では作れない）。
- リリースのパッチ（実際の Release に付いている）と、`bsdiff4` が作ったパッチを Dart が適用できること。
- アプリ内のモデルが、`docs` と `settings_spec.dart` の日本語を化けずに読めること（MCP の応答の UTF-8 復号が効いた）。
- 文字の大きさ 1.0〜2.0 倍・3 つの幅で、主要な画面と設定の全グループがあふれないこと（`test/ui/text_scale_test.dart`）。

## 未確認（実機・実際のサービスで確かめる必要がある）
**Linux 環境・セッション・秘密**
- rootfs のダウンロード・展開・`bash` の起動、`apt`・`pip`・`git`・`kaggle` の動作、`/proc` の bind、ハードリンクの作成（SELinux）、時間と容量の上限、承認カードの見え方（`linux_environment`）。proot が実機（各メーカーの seccomp 設定）で起動できるか（設定の「proot の確認」ボタン）。
- proot の中で `script` が疑似端末を作れるか。opencode・agy が動くか（`shell_sessions`）。
- 秘密のプレースホルダー：承認カード・画面・proot での書き換え・実際の Gemini などでの呼び出し・`git push` などが環境変数で認証できること（`secrets`）。
- `ci_status` の実機・実トークンでの表示、`Actions: Read` が無いトークンでの 403 の文言、非公開リポジトリ。
- 通知（Android 13 以降の許可の質問、通知の見え方。`screens`）、生成中の別チャットへの移動（オンラインの 2 つの同時生成と端末のモデルの排他）、承認カードの「実行する」で前面サービスが落ちないこと。

**モデル・プロバイダ**
- 実際のオンラインのモデルとの往復：フォールバックが 403・429 で本当に切り替わるか、トークンの事前チェックの見積もり（実トークン数との差）、OpenRouter 形の思考のリクエスト、Gemini の思考（OpenAI 互換の応答に思考が出るか）、Gemini の思考署名で 400 が直るか、`reasoning_content` を受け取る項目名・DeepSeek・Z.ai の HTTP の引数名（選んだ形で 400 が返るときは、プロバイダの「追加のリクエスト項目」で上書きする）、画像の送信、`/models` の応答（DeepInfra・Groq の欄名）。
- Gemini の `models.list`（address・`x-goog-api-key`・`supportedGenerationMethods`。記憶による）、無料枠のキーでのモデルの確認、`prompt_cache_key` が当たりを良くするか、キャッシュのトークン数の欄（`providers`）。
- 小さい端末のモデル（0.8B）が、`update_settings` の `changes` 配列や `add_provider` を正しく書けるか。この形の JSON Schema が llama.cpp の `json_schema_to_grammar` を通るか。MCP の「探す → 読む → 呼ぶ」の順を守れるか。会話の要約の質。
- 実機の Android での、モデルの読み込みと推論、KV キャッシュの保存・復元、前面サービス、差分更新（`base.apk` が同じバイト列か。時間とメモリ）、ダウンロードの速度（複数接続で速くなるか。接続数 1 と 8 の比較）、他のアプリを開いても続くか、チャットの見え方（長い返信、コードのカードの幅、文字 200% のときの設定画面）、3 ボタンのナビゲーションバーでの編集画面の余白、Markdown の見え方（テストは構造と例外のみ）。
- 分担（コーディングモード）：プランナーが図とタスクの id を正しく合わせて書くか、複数の開発モデルでの速さ。
- 検索 API のひな形の項目名（Brave・Google など。公式で確かめていない）、Kaggle MCP の認証と道具の名前。
- iOS・Windows・macOS の実機での自己更新と、DB の読み書き。旧 JSON から DB への取り込みを実データ量（数百会話）で試していない。
- 実際の GitHub への Issue 送信（エラー報告）、GitHub App の bot（`github_bot`。最初は dry run で確かめる）。
- 外部 URL（`sources`）の一部は、この環境から開けず未確認。

- 端末のモデル（Qwen3-8B Q4_K_M）で、指示が約 4,000 トークンのとき、最初の言葉が出るまでの時間（実機の報告では 4 分半たっても出なかった）。読み込みの速さ（トークン/秒）は未測定。

## 未対応・今後
- Kotlin 版にあった Python / Java の実行とビルド（サンドボックス）、WorkManager による更新の通知は、Flutter 版に移していない（シェルの道具で同じことができる）。Android 以外の推論（llama.cpp を FFI で各 OS に入れるなど）。iOS の署名と TestFlight、macOS の公証、Windows のコード署名。
- 履歴の画像の保存、送信前プロンプトのプレビュー、使用量・費用の記録（`prompt_tokens` / `completion_tokens` / `cost_micros` の列はあるが書いていない）。
- OAuth の MCP、Kaggle Models の直接ダウンロード、アプリを消している間も続くダウンロード、通知から会話を開くこと、上のバーのモデル名のチップに使えないモデルの印を出すこと、フォールバックで切り替わった分を通信回数に数えること。
- 人間が打つ端末の画面（対話セッションはモデルが読む形だけ）。

## 既知の制限（直せない・直していない）
- **proot が境界でない**ことは直せない（Android のアプリは namespace や chroot を使えない）。確認とカードで守る（`linux_environment`）。
- コマンドの**通信を止められない**（proot にその機能が無い）。外部の文章に誘導されたコマンドが、ワークスペースの中身を外へ送れる。確認（外部を読んだあと）が、唯一の備え。
- 会話履歴の DB は暗号化していない（アプリの専用領域に置く、ふつうの扱い）。端末が root 化されていれば読める。
- `http_request` の DNS rebinding の隙間（`secrets`）。スクリプトの中の宛先は検査できない。
- **点検していない範囲**：`bspatch`（壊れた差分への耐性）、`ApkInstaller`、MCP クライアントのリダイレクトの扱い、`desktop_installer` のスクリプト、Hugging Face のダウンロード、**依存パッケージの既知の脆弱性**（`pub` の一覧を調べていない）、iOS/macOS の権限設定。
- 点検して**問題が見つからなかったもの**：`allowBackup=false`・サービスは `exported=false`・公開しているのは MainActivity だけ・PendingIntent は immutable・SQLite の全文検索は引数を束縛して検索語を組み立てている・デスクトップの更新の展開は SHA-256 を確かめたアーカイブだけを渡す・設定の JSON にキーやトークンは入らない・エラー報告は送る前に隠す。

## 環境の制約（作業するセッションで起きること）
- クラウドのセッション：GitHub の操作は `mcp__github__*` のツール（`gh` コマンドが無いことがある）。Actions の実行は `actions_run_trigger`、状態は `actions_list`、ログは `get_job_logs`（実行中のジョブのログは取れない）。GitHub API は未認証だと 1 時間 60 回で、ポーリングで使い切ることがある（認証つきなら多い）。ジョブログが 403 で読めないときも、アノテーション（`/check-runs/{id}/annotations`）は読める。
- 外部への接続はプロキシで制限される。届いたもの：`storage.googleapis.com`（Flutter SDK）、`repo.maven.apache.org`、`raw.githubusercontent.com`、`api.github.com`、GitHub のツール経由。**届かなかったもの**：`dl.google.com`、各社の公式 docs の一部（`ai.google.dev`、`platform.openai.com`、`api-docs.deepseek.com`、`docs.z.ai`、`infisical.com`、`git-scm.com`、`docs.github.com`、`docs.flutter.dev`、`alpinelinux.org`、Brave・Kaggle・Google の検索 API の docs）。そのため、公式で確かめていない事柄は、各ファイルに「未確認」と書いてある。**このセッションの git の経路は、タグの push とブランチの削除を 403 で拒否する**（方針による拒否。回り道はしない。必要なら利用者が GitHub 上で行う）。
- Flutter SDK は作業用フォルダ（一時）に置く。消えていたら `storage.googleapis.com/flutter_infra_release/releases/stable/linux/` の stable の tar.xz から取り直し、`git config --global --add safe.directory '*'` を行う。arm64 の proot の Ubuntu では Flutter SDK が動かないことがある（arm64 版が無く、x86_64 版は qemu で `flutter_tools.snapshot` が Illegal instruction）。その場合、`flutter analyze` / `flutter test` は CI を検証手段にする。純 Dart のファイル（`lib/data`、`lib/ai`、`lib/core` の一部）は、小さな作業用パッケージにコピーして `package:flutter_test` を `package:test` に置換すれば、手元の `dart test` で回せる。
- **アーカイブを展開したフォルダを、シンボリックリンクをたどる削除（Kotlin の `File.deleteRecursively()` など）で消さない。敵対的なアーカイブを展開するテストは、失っても困らない環境で動かさない**。過去に、`TarGz` のテスト（`a -> /` のリンクと `a/x` のファイル）が出力フォルダにリンクを残し、次の手順の `deleteRecursively()` がリンクをたどって、クラウドのコンテナのファイルシステム全体を消した（GitHub は無事。未 push の作業が全部消えた）。`DiskUsage.delete` / `DiskUsage.clear`（リンクをリンクとして消す）を使い、使い捨てのフォルダで、サンドボックスの中で走らせ、壊れる操作の前に push する。
- 待ち合わせに固定の `sleep` を使わず、GitHub の応答で状態を確認する。
