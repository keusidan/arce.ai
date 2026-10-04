# ARCE.AI 企画書（全面改訂版）技術レビュー

- 対象：`ARCE_AI____________.txt`（全34章・行番号は同ファイル基準）
- 作成日：2026-09-26
- 結論：構成が大きく改善した。特に **エラー分類（12章）・Generation Taskの状態管理（10章）・再生成の再現性（11章）・性能不足時に設定を勝手に変えない方針（13章）** は、これまでの指摘（⑤など）をきちんと仕様にできている。一方で、**配布とセキュリティに関わる重大な問題** が残っていて、新しく増えた機能にも仕様がまだ書かれていない部分がある。

---

## 1. 最重要：端末上でのビルド（20・21章）と配布方法が両立しない

L236-253は「SDK・Gradle・JDK・コンパイラを必要なときにダウンロードし、Android上で直接ビルドする」仕様。これは次の3つの制約とぶつかる。

### Android 10以降は、ダウンロードしたファイルを実行できない
- targetSdk 29以上のアプリは、自分のデータ領域に置いたファイルを実行できない。
- 回避策は2つしかない：
  - 実行ファイルをAPK内のnative library（`nativeLibraryDir`に置かれるファイル）として同梱する。この場合、あとからダウンロードする方式にはできない。
  - Termuxのように、targetSdkを28に据え置く。
- Source: https://developer.android.com/about/versions/10/behavior-changes-10#execute-permission

### Play Storeの規約で、Play以外から実行コードをダウンロードすることが禁止されている
- Device and Network Abuse policyに違反する。さらに、Play StoreはtargetSdk 28のアプリを受け付けない。
- Source: https://support.google.com/googleplay/android-developer/answer/9888379

### Android SDKのビルドツールには、Android上で動く公式版がない
- aapt2などの公式版は、x86_64のLinux・Mac・Windows向けだけ。
- 端末上でAPKをビルドできている既存のアプリ（AndroidIDEなど）は、Termuxのパッケージを土台にし、有志がビルドしたaapt2を使っている。
- Source: https://developer.android.com/tools/aapt2
- Source: https://github.com/AndroidIDEOfficial/AndroidIDE

### → 「配布方法」を決めることが、仕様全体の前提になる

| 案 | 配布先 | 内容 |
|---|---|---|
| 案X | GitHub等（Play Storeは使わない） | targetSdkを28にし、Termuxのbootstrap（最小限のLinux環境）を取り込む。20章の仕様をほぼそのまま実現できるが、セキュリティ上の責任はすべて自分で負う |
| 案Y | Play Store | ビルドは「ソースコード生成まで」か「PCに任せる」に限られる（以前の案A・B） |

---

## 2. セキュリティの節がない（8・20・28章）

v2の頃より危険になる要素が増えている。AIが生成したコードを「操作」（L125）でき、「適切なランタイム」（L129）で実行し、さらにシェル環境（L348）まで持つため。最低限、次の3点を仕様に入れる。

1. **Artifact用WebViewの設定**：file accessを無効にする、`addJavascriptInterface`を使わない、`WebViewAssetLoader`で読み込む。
   - Source: https://developer.android.com/develop/ui/views/layout/webapps/load-local-content
2. **生成したコードを実行する前の確認**：実行する前に、内容と権限をユーザーに見せて承認をもらう。実行はアプリ専用の領域の中に閉じ込め、共有ストレージやネットワークへのアクセスは既定で許可しない。
3. **「AIの文体」（L302）の欄**：システムプロンプトは固定で文体だけを合成すること、と、prompt injection（システムプロンプトを上書きさせる入力）への対策を明記する。

---

## 3. 検索の実装手段が、今回もどこにも書かれていない（6・27・28章）

- 検索の流れと、失敗したときにローカルAIだけで続ける処理（L104）は良い仕様。
- しかし、どの検索エンジンやAPIを使うのかが、技術スタック（28章）に1つも書かれていない。
- Raspberry Pi 5のSearXNGを使うのか、別の手段にするのかを決める。
- Source: https://docs.searxng.org/

---

## 4. llama.cppとMLC-LLMを「併用」する負荷（3章）

- MLC-LLMはGGUFを読めず、専用の形式に変換したモデルを別に用意する必要がある。
- さらにAndroidでは、モデルの構造ごとに「model library」をコンパイルしてAPKに同梱する必要がある。そのため、アプリをビルドしたあとで、新しい種類のモデルを自由に追加することはできない。
- 量子化方式もエンジンごとに違う（GGUFはQ4_K_Mなど、MLCはq4f16_1など）。2.3章のモデル選択画面は、エンジンごとに表示を分ける必要がある。
- **提案**：llama.cppを主エンジンにし、MLC-LLMは`InferenceEngine`のinterfaceの裏に差し替え可能な形で置く。こうすれば「併用」の方針を保ったまま、実装する順番を調整できる。
- Source: https://llm.mlc.ai/docs/deploy/android.html

---

## 5. Context Lengthとメモリ使用量（2.2章・4.2章）

「推定メモリ使用量を表示する」（L46）はとても良い仕様。ただし、計算にはKV cache（会話の文脈を覚えておくためのメモリ）を含める必要がある。

| モデル | 層数 | KVヘッド数 | 1 tokenあたり（f16） | 16384 tokenのとき |
|---|---|---|---|---|
| Qwen3-8B | 36 | 8 | 約144KiB | 約2.3GiB |
| Qwen3-14B | 40 | 8 | 約160KiB | 約2.5GiB |

- 計算式は「2（KとV）× 層数 × KVヘッド数 × 128（1ヘッドの次元数）× 2byte」。
- たとえばQwen3-14BをQ4で動かし、Context Lengthを16384にすると、合計で約11.5GBになる。16GBの端末でも余裕はあまりない。
- llama.cppにはKV cacheを量子化するオプション（`--cache-type-k q8_0`など）があり、これを使えば約半分に減らせる。開発者設定の候補になる。
- Source: https://huggingface.co/Qwen/Qwen3-14B/blob/main/config.json
- Source: https://github.com/ggml-org/llama.cpp/blob/master/tools/main/README.md

---

## 6. 仕様がまだ書かれていない機能

### AIエージェント（16章）
- 「エージェント＝処理手順・役割」とあるだけで、具体的にどんなエージェントがあるのかが書かれていない。
- 実装としては「system prompt＋使えるtool＋処理手順」を1つのセットにしたものになる（例：コード生成用、調査用、APKビルド用）。
- 1.7Bクラスの小さいモデルでは、toolを使う処理が不安定。エージェントごとに最低限必要なモデルサイズも決めておく。

### 表示用の記法
- 太字の`**<text>**`、Artifactを囲む記法、質問タイルのJSONの例（`allow_free_input`・`multi_select`）が、今回の版では全部消えている。
- これらはsystem promptとGBNF(GGML BNF) grammarに書き込む「アプリとAIの間の決まり事」なので、仕様書に残しておく必要がある。

### JSONの自動修復（L116、L166）
- grammarで出力の形を縛れば、形式が崩れたJSONはそもそも出なくなる。実際に起きるのは、文字数の上限で出力が途中で切れる場合だけ。
- 「修復」ではなく「途中で切れたら、生成だけやり直す」と書けば十分。
- Source: https://github.com/ggml-org/llama.cpp/blob/master/grammars/README.md

### HyperLoad（1.1章）
- 性能優先モードにしたのは分かりやすい整理。
- ただし「端末の安定性を損なわない」（L31）を実装するには、端末の温度状況を取得する必要がある。Androidの`PowerManager.getThermalHeadroom()`などのAPIを使い、発熱で性能が落ちる前に負荷を下げる、と書いておくと実装できる仕様になる。
- Source: https://developer.android.com/reference/android/os/PowerManager#getThermalHeadroom(int)

### 「仕様を無視した強制実行」（L304）
- 何の仕様を無視するのかが書かれていない。「推定メモリ使用量が空きRAMを超えるモデルの読み込みを許可する」のように定義する。

---

## 7. 細かい点

- **推奨モデル（2.1章）**：Thinkingスイッチを使うには、Qwen3の最初の版を指定する必要がある（2507版は切り替えできない）。
  - Source: https://huggingface.co/Qwen/Qwen3-8B
- **使用技術の一覧（28章）**：
  - 「GGUF」「CPU」「ARM Neon」はライブラリではない。
  - 履歴保存（31章）に使うRoom、Python Runtimeに使うChaquopy、検索手段が抜けている。
  - Compose（L337）とXML（L338）は、どちらか一方にするのが普通（Composeを推奨）。
  - Source: https://developer.android.com/training/data-storage/room
- **ベンチマーク（14章）**：llama.cppに付属する`llama-bench`の測定方法（prompt処理速度と生成速度を分けて測る）を参考にできる。
  - Source: https://github.com/ggml-org/llama.cpp/tree/master/tools/llama-bench
- **開発方針（L5、L401）**：「v1で主要機能をすべて搭載」とする場合でも、33章のように機能を分けて作るなら、どの順番で作ってどの段階でテストするかを仕様に書いておくと、完成までの見通しが立つ。

---

## 8. 決めてほしいこと

- **配布方法**（1章）：案X（Play Store以外で配布する） / 案Y（Play Storeで配布する）
  - これが決まると、ビルド機能・Termux環境・targetSdkの仕様が一度に決まる。
