# ARCE.AI Phase 0 試作（Prototype 2：ローカルLLM）

- 作成日：2026-09-26
- 対象：企画書 45章 Prototype 2「llama.cpp → Qwen3 → ストリーミング → Thinking → JSON / GBNF → チャットUI」
- Prototype 1（端末上のAPKビルド：ECJ → D8 → aapt2 → apksig）は次の段階で着手する

## 1. 構成

```
arce.ai/
├─ core/                  純Kotlin（JVM）。Androidに依存しないロジック。ここでテスト済み
│  ├─ engine/             InferenceEngine（推論エンジン共通interface）
│  ├─ chat/               ChatController（会話の進行・質問タイル・再生成・続行）
│  ├─ stream/             StreamSegmenter（<think>／<tool_call>の分離。タグの分断に対応）
│  ├─ protocol/           ask_userツール定義、JSON Schema生成、意味チェック
│  ├─ prompt/             Qwen3用ChatMLプロンプト、口調欄のサニタイズ
│  ├─ generation/         Generation Taskの状態遷移、再試行ポリシー
│  ├─ model/              Qwen3モデル一覧、KV cache込みのメモリ見積もり
│  └─ render/             **太字**とcode fenceの簡易パーサー
├─ app/                   Androidアプリ（Jetpack Compose）
│  ├─ src/main/cpp/       JNI（arce_llama.cpp）とCMake
│  └─ src/main/kotlin/    LlamaCppEngine、ChatViewModel、ChatScreen、ModelStore
└─ third_party/llama.cpp  git submodule（タグ b11200 に固定）
```

## 2. 実装した仕様

| 企画書の項目 | 実装 |
|---|---|
| Thinkingの分離・折りたたみ（9章） | `<think>`を別表示。Thinking中はラベルが緑⇔水色で点滅 |
| 生成中の折りたたみ（6章） | 「生成中…」を黒⇔白で点滅、タップで展開 |
| 質問タイル（11章） | `ask_user`ツール → 選択式／複数選択／自由入力のカード。回答するまで停止 |
| GBNF（決定事項2） | ① lazy grammar（`</think>`の後の`<tool_call>`から文法を適用）② JSON Schemaから自動生成 ③ Agentごとのツールだけを許可 ④ 途中切断の検出→再生成 ⑤ 意味チェック ⑥ Schemaのバージョン番号 |
| 送信／停止／続行を1ボタン（12章） | 入力あり＝送信、生成中＝停止、途中停止後で入力なし＝続行 |
| 再生成・コピー（16章） | 同じ文脈から再生成、本文のコピー |
| 口調とシステムプロンプトの分離（51章） | 口調は200文字まで、制御タグを除去して専用の区切り内に配置 |
| 回答の重複防止（55章） | system promptの指示＋DRY sampler |
| 対応Android（決定事項6） | minSdk 31（Android 12）／targetSdk 36 |
| 16KBページ対応 | native libraryを16KB境界でリンク |

## 3. 検証結果

この開発環境（クラウド上のコンテナ）で確認できたもの：

| 確認内容 | 結果 |
|---|---|
| `:core`のユニットテスト（7クラス・35件） | ✅ すべて成功 |
| llama.cpp＋JNIブリッジのコンパイル（ホストのLinux・clang） | ✅ 成功。JNI関数10個をexport |
| 生成したGBNFがllama.cppの文法パーサーで読めるか | ✅ 成功（56ルール） |
| JVMからJNIを呼び出す（文法生成・エラー処理・モデル読み込み失敗） | ✅ 期待どおり動作 |

**未確認のもの（ぽんずさんの環境で確認が必要）：**
- `:app`のビルド全体。このコンテナからはGoogle Maven（`dl.google.com`）への通信がネットワーク設定で拒否されており、Android SDK・NDK・AGP・Composeを取得できなかったため
- 実機での推論（Hugging Faceにも接続できず、モデルを取得できなかったため）
- `libs.versions.toml`のうちGoogle Mavenのライブラリ（AGP 8.13.2・Compose BOM 2025.06.00など）のバージョンは、ここでは存在を確認できていない。ビルドで見つからない場合は新しい版に上げる

## 4. ビルドと実行の手順（Arch Linuxのデスクトップ）

1. **取得**
   ```bash
   git clone --recurse-submodules https://github.com/keusidan/arce.ai.git
   cd arce.ai && git checkout claude/new-session-5wz0e3
   git submodule update --init   # 既にcloneしている場合
   ```
2. **Android SDKの準備**（Android Studioを使う場合は、SDK ManagerでNDK 29.0.13113456とCMake 3.22.1を入れる）
   ```bash
   echo "sdk.dir=$HOME/Android/Sdk" > local.properties
   ```
3. **ビルドとインストール**（端末をUSBデバッグで接続）
   ```bash
   ./gradlew :app:installDebug
   ```
4. **モデルの用意**（例：Qwen3-4B）
   - Hugging Faceの`Qwen/Qwen3-4B-GGUF`から`Qwen3-4B-Q4_K_M.gguf`をダウンロードし、端末へ送る
   ```bash
   adb push Qwen3-4B-Q4_K_M.gguf /sdcard/Android/data/ai.arce.app/files/models/
   ```
   - またはアプリの「Model ▼ → + モデルを追加」から端末内のGGUFを選ぶ（アプリ専用領域にコピーされる）
5. **動作確認の例**
   - Thinking ON で「こんにちは」→ Thinkingが折りたたみで表示されるか
   - 「Webアプリを作って。言語は私に選ばせて」→ 質問タイルが出て、回答後に続きが生成されるか
   - 長い回答を途中で「停止」→ ボタンが「続行」に変わり、続きから生成されるか

- テストだけを実行する場合（SDK不要）：`./gradlew :core:test`
- GPU（Vulkan／OpenCL）は`gradle.properties`の`arce.ggml.vulkan`／`arce.ggml.opencl`を`true`にすると有効になる（実機で未検証のため、既定はOFF）

## 5. 試作の制約（次の段階で対応）

- 毎ターン、プロンプト全体を評価し直している（KV cacheの再利用は未実装）
- Artifact（WebViewでのプレビュー）は未実装。code fenceはソース表示のみ
- 設定画面・履歴保存（Room）・Search・Agent自動選択・更新機能（GitHub Releases）は未実装
- モデルは手動で配置する（アプリ内ダウンロードは未実装）

## 6. ファイル名について

ぽんずさんの設定「ファイル名の後ろにClaude-MM-dd-yyyy_HH-mm-ssを付ける」は、本書のようなドキュメントには適用した。ソースコードとビルド設定のファイルには付けていない。理由：

- `build.gradle.kts`・`AndroidManifest.xml`・`CMakeLists.txt`などは、Gradle・Android・CMakeが決まった名前でしか読み込まない
- Kotlinのソースファイル名に日時が入ると、パッケージ構成が読みづらくなり、ファイルを直すたびに名前を変える必要が生じる

## 7. Source

- llama.cpp Android example：https://github.com/ggml-org/llama.cpp/tree/master/examples/llama.android
- GBNFとJSON Schema変換：https://github.com/ggml-org/llama.cpp/blob/master/grammars/README.md
- lazy grammar（tool call）：https://github.com/ggml-org/llama.cpp/blob/master/docs/function-calling.md
- Qwen3の推奨サンプリング設定とThinking切替：https://huggingface.co/Qwen/Qwen3-8B
- 16KBページサイズ：https://developer.android.com/guide/practices/page-sizes
- JNIと修正UTF-8（4バイト文字を扱えない理由）：https://docs.oracle.com/en/java/javase/21/docs/specs/jni/types.html#modified-utf-8-strings
