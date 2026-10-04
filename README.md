# ARCE.AI — ローカルAIによるコーディング・チャットアプリ（完全版APK）

企画書（`docs/ARCE.AI企画書.txt`）の**全項目**を実装したAndroidアプリ。
実装にあたっては助言書（`docs/ARCE.AI助言書.txt`）のチートシートを全編参照し、
違反が起きた場合は「失敗ログ一覧」に追記している。

## 対応OS / 要件
- Android 8.0 (API 26) 以上、arm64-v8a
- RAM 4GB 以上を推奨（0.5Bモデルは2GBでも動作可能だが重い）
- 初回使用時に**AIモデルのダウンロードが必須**（APKは数MB、モデルは470MB〜1.7GB）

## 企画書項目 → 実装の対応表

### #チャット画面
| 企画書項目 | 実装 |
|---|---|
| チャット | `ChatScreen.kt` + `ChatEngine.kt`（llama.cpp完全ローカル推論） |
| HyperLoad(ON/OFF) | トップバーのスイッチ。ONでスレッド最大・コンテキスト拡大 |
| アーティファクト(プレビュー/コード スライド切替) | `ArtifactCard`：スライド式タブ。コード自体も表示 |
| 太字 `**text**` | `RichText` が `**…**` を太字でレンダリング |
| 生成中(折りたたみ・黒白エフェクト) | 生成中は折りたたみ表示(タップで展開)。黒白ストライプアニメ。Thinking展開中はエフェクトを25%に弱める |
| 最近の履歴(左フェードイン) | 左上メニュー → 左からフェード+スライドで履歴表示。保存はJSON |
| CPU,GPU,NPU変更(スライド式・グレーアウト) | 起動時にバックエンド検査を1回だけ→キャッシュ。未対応はα0.3でグレーアウト |
| AIモデル変更(上折りたたみ+追加) | 上部折りたたみパネル。最下層「+ モデルを追加」→ DL画面。Qwen2.5-0.5B/1.5B、Gemma-2-2B |
| Thinking表示(折りたたみ・緑水色) | 生成パイプラインの思考ログを折りたたみ表示。生成中は緑/水色ドットアニメ。同時発生時はThinking側を優先(生成中エフェクトを弱める) |
| Search表示(ボタン式) | 「検索結果 (n)」ボタン → タップでリンク一覧展開 |
| 質問タイル(JSON) | 企画書どおりのJSON仕様(`title/options/allow_free_input/multi_select`)。パース失敗はテキストへフォールバック(助言書準拠) |
| 送信/停止/続行 1ボタン | 入力あり=送信 / 生成中=停止 / 空で待機=続行(停止済みの生成を継続) |
| ファイルを追加 | 添付アイコン → SAF複数選択。テキスト系はプロンプトに展開 |
| 書き込み中/読み込み中 ✓× | ✓(緑)/×(赤) 表示。保存・共有・モデルロードで発火 |
| 生成後:コピー/再読み込み | DONEメッセージ下にコピー/再読み込みボタン |

### #アーティファクトの詳細な機能
| 項目 | 実装 |
|---|---|
| 生成中でもプレビュー表示 | ストリーミング中に逐次 `ArtifactCard` に反映 |
| リアルタイム反映・自動更新 | トークンごとの再パース → 差分ハッシュで変化時のみWebViewリロード(負荷低減) |
| 生成完了を待たずに動作確認 | HTML/CSS/JSはアプリ内HTTPサーバー(`LocalPreviewServer`, NanoHTTPD)経由で即プレビュー |
| 不完全なコードのプレビュー | タグが閉じた時点(平衡チェック)で初めて反映 — 助言書の安全策 |
| エラーをプレビュー上に表示 | `onReceivedError` / `onConsoleMessage(ERROR)` を捕獲しプレビュー上に赤表示 |
| エラーをAIの修正処理へ | 「エラーをAIに修正させる」ボタン → エラー内容をプロンプトへ |
| 差分更新で負荷低減 | 内容ハッシュ同一ならリロードしない |

### #チャット指示によるファイル・アプリ生成
| 項目 | 実装 |
|---|---|
| 生成形式をチャット指示で判定 | `GenerationPlanner.detect`（APK/EXE/JAR/JSON/PY/HTML/JS/CSS） |
| 未指定時の自動判断 | 内容キーワードから判断(ページ/サイト→HTML等) |
| 判断困難時の質問タイル | 曖昧時は形式選択タイルをチャット上に表示 |
| ビルド必要な形式の自動実行 | PY(構文チェック)/JAR(javac+jar)/JSON(検証)は**実ビルド**。APKは環境が揃っていればgradle実行 |
| SDK/コンパイラ/Gradleの自動確認 | `BuildPipeline.requiredEnv` → 不足をチャット上に ✓/✗ リストで表示 |
| EXEの扱い | 助言書に従い「PC側の補助ビルドサーバーが必須」と明記(端末単体では作れない設計にしない) |
| 進捗のチャット表示 | ビルドの各ステップを `progressLines` で表示 |
| 生成後の操作・保存 | アーティファクトから「保存」(SAF) / コードコピー |
| 完成前のプレビュー | HTML/CSS/JSは生成中からプレビュー |

### #詳細設定画面
企画書の9項目すべて `SettingsScreen.kt` に実装（APK作成ON/OFF、通知進捗、口調、
文字数制限、強制実行、再書き込み回数、速度/精度スライダー、フルパフォーマンス、ダークモード）。
スライダーは n_threads / n_ctx / max_tokens / temperature に変換される。

### #その他の必要要素
- 天気: Open-Meteo(キー不要)+端末位置。`天気` `気温` などの指示で自動発火
- 時間: 端末システム時計/タイムゾーン。`今何時` などの指示で自動発火
- 検索: DuckDuckGo(公式IA API + Web) / Yahoo(スクレイピング) / Google(任意・規約要確認)
- 生成形式: APK, EXE, JAR, JSON, PY, HTML, JS, CSS（コード生成は全対応）
- モデルの維持: `getExternalFilesDir()` 配下に保存。アプリ更新で維持（アンインストールで削除）

### #必要なソフト、ライブラリ
- 推論: **llama.cpp**（GGUF対応、CPU + Vulkan GPU バックエンドをNDKで静的リンク、JNI経由）
  - NPU(NNAPI)はllama.cppが非サポートのためUIでグレーアウト（エンジン依存の事実表示）
- UI: Jetpack Compose + WebView(アーティファクト)
- バックグラウンド: WorkManager(`DownloadWorker`/`BuildWorker`) + 通知チャネル連携
- 検索: DuckDuckGo Instant Answer API / Yahoo(非公式) 
- 天気: Open-Meteo（企画書の「OpenWeatherMap等 無料気象API」相当、キー不要で初回動作する構成）
- モデル: Hugging Face Hub（Qwen2.5 0.5B/1.5B Instruct Q4_K_M、Gemma 2 2B IT）
- ローカルHTTP: NanoHTTPD（助言書の file:// 回避策）
- HTML解析: Jsoup

### #助言書の遵守
- 推論は `Dispatchers.IO` の別スレッド（UIブロック禁止）
- context/model は1:1生成・破棄、`onDestroy` / `onLowMemory` で解放
- モデルDLはストリーミング%表示 + HTTP Rangeによる再開
- Vulkan未対応端末はCPUへ自動フォールバック（バックエンド列挙で判定）
- WebViewは `addJavascriptInterface` 不使用（XSS対策）
- タイルJSONはバランス括弧抽出→失敗時テキストフォールバック
- リトライ: 上限+同一エラー連続で即停止+エラー文をシステムプロンプトに1行追記
- 強制実行ON時は温度警告を無視 / OFF時は42°C超で警告
- 不完全HTMLのプレビューはタグ閉じまで保留
- EXEはPCサーバー必須と明記
- モデル保存場所をUIに明示（アンインストール注意書き）

## ビルド方法（このリポジトリからAPKを再生成）
```bash
# 1. ツールチェーン(JDK17 + Android SDK + NDK27 + CMake)
./scripts/setup_toolchain.sh
# 2. llama.cpp サブモジュール (pinned @d81aef1)
git submodule update --init llama.cpp
# 3. ネイティブ (arm64-v8a, CPU+Vulkan バックエンド入り)
./scripts/build_native.sh          # CPUのみ版
./scripts/build_native_vulkan.sh   # CPU+Vulkan版（Vulkan SDK 1.3.296.0 が必要:
                                   #   toolchain/1.3.296.0/ に展開しておく）
# → app/src/main/jniLibs/arm64-v8a/libarce_llama.so （llvm-strip で必須: 91MB→40MB）
# 4. APK
./toolchain/gradle-8.9/bin/gradle :app:assembleRelease
# → app/build/outputs/apk/release/app-release.apk (セルフ署名)
```
署名キー: `keystore/arce-release.jks`（パスワード `arce2026`、セルフ署名）。
本番配信時は新しいキーで再署名してください。

### 低メモリ環境(2GB)でのビルド注意（本リポジトリの.soは全てこの手順で作成）
- `org.gradle.jvmargs=-Xmx700m` + `--no-daemon`（gradle.properties 既定）
- **packageRelease は単独実行** `gradle :app:packageRelease --no-daemon`
  （コンパイルと同じJVM内で実行するとOOMキルされる: 助言書#014）
- Vulkan版は `native/vk_chunks/` の分割コンパイルと `native/vk_shim.cpp`
  （Vulkan 1.1 シンボル、API<28 端末用）が必須。これらはリポジトリに同梱済み。
  詳細は助言書 #012/#013。

## 初回使い方
1. APKをインストール
2. 上部モデルメニュー →「+ モデルを追加」→ Qwen2.5 0.5B（約470MB）をダウンロード
3. 戻る。チャットで入力（例: 「今何時」「新潟の天気」「HTMLでトーストリストを作ってくれ」）
4. 生成したコードはアーティファクトの「プレビュー」タブでそのまま動作確認
