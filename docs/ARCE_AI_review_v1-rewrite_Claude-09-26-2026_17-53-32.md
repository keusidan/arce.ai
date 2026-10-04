# ARCE.AI 企画書（v1で1から修正版）技術レビュー

- 対象：`ARCE.AI___1.txt`（行番号は同ファイル基準）
- 作成日：2026-09-26
- 結論：質問タイルのJSONと太字記法は正しい形に戻った。一方で、**v2・v3で決めた内容の多くが消えていて、元の問題が再発している箇所**がある。

---

## 1. 直っている点

- **⑭ 太字記法（L17）**：`**<text>**`に戻った。
- **⑯ 質問タイルのJSON（L26、L28）**：値と型の入った正しいJSONに戻った。
- **L61「Thinkingが可能なモデルのみThinkingを許可」**：前回の⑧（モデルごとに「切替可能 / 常時ON / 非対応」の3状態で管理）と同じ考え方で、良い追加。
- **L81 grammar/JSON schema、L82 WorkManager/Foreground service、L84 Open-Meteo**：v2で決めた内容が引き継がれている。
- **ダークモード（L50、L69）**：切替を復活させたことで、「ライトモード時は黒か藍色の文字」という記述と矛盾しなくなった。

---

## 2. v2・v3から消えて、元の問題に戻った箇所

### A. 検索がGoogle・Yahoo・DuckDuckGoに戻っている（L58）
- どれも実用できるAPIがない、という問題が再発する。技術スタックからも検索の項目が消えている。
- 「DockDockGo」も綴りが間違ったまま（正しくはDuckDuckGo）。
- 3つのエンジンを使い続けたいなら、Raspberry Pi 5上のSearXNGでまとめて検索する構成が必要。
- Source: https://docs.searxng.org/

### B. Open-Meteoに「検索用」と書いてある（L84）
- Open-Meteoは天気専用のAPIで、Web検索はできない。
- Source: https://open-meteo.com/en/docs

### C. NPUのスイッチはあるのに、NPUを動かす技術がない（L20 vs L75-87）
- NNAPIは削除されたが、代わりのLiteRTも書かれていない。今のままだとNPUは常にグレーアウトされる。
- 「NPUをUIから外す」か「LiteRTを追加する（推論エンジン2系統）」のどちらかに決める必要がある（前回の要決定①）。

### D. GPUがOpenCLだけになっている（L76、L79）
- 前回の②と同じ問題。Mali系GPUやPixelの端末ではGPUが使えず、CPUで動くことになる。Vulkanをfallbackとして書き加える。
- Source: https://github.com/ggml-org/llama.cpp/blob/master/docs/backend/OPENCL.md

### E. 端末上でのビルドが戻っている（L42、L86）
- 案A（ソース生成まで）と案B（PCに委譲）のどちらにするかが消えて、「Termux相当のシェル環境」に戻っている。
- 新しい問題：**Android 10以降、アプリのデータ領域に置いたファイルは実行できない**（targetSdk 29以上のアプリが対象）。
  - Termuxがこの制限を避けられているのは、targetSdkを28に据え置いているから。
  - Play Storeは新しいtargetSdkを要求するので、同じ方法ではPlay Storeで配布できない。
- Source: https://developer.android.com/about/versions/10/behavior-changes-10#execute-permission
- Source: https://github.com/termux/termux-app#google-play-store-experimental-branch

### F. セキュリティとシステムプロンプトの方針が丸ごと消えている
- 次の内容が消えている：
  - WebViewの設定（file access無効化、`addJavascriptInterface`を使わない、`WebViewAssetLoader`で読み込む）
  - 「口調の要求」欄からのprompt injection（システムプロンプトを上書きさせる入力）への対策
  - 「システムプロンプトは変更不可で、口調だけを合成する」という方針
- 今は「口調の要求（テキスト）」（L44）しか書かれていない。AIが生成したJavaScriptを表示するアプリなので、この節は必須。
- Source: https://developer.android.com/develop/ui/views/layout/webapps/load-local-content

### G. 処理フローの節がなくなっている
- 「検索 → Thinking → 質問 → 生成」の順番、質問タイルの回答を待つ間は止めること、エラー時にどこからやり直すか、がすべて消えている。
- L47の「再書き込み許可回数」が、何の回数の上限なのか分からなくなっている。

### H. HyperLoadの定義がない（L9）
- 名前しか書かれていない。v2で決めた定義（AIが自分に質問し、自分で答えることを繰り返して精度を高める）を戻す。

### I. 「モデルの再ダウンロードを禁止」（L80）
- 技術スタックではなく機能要件。また、「禁止」だとファイルが壊れたときにも入れ直せない。
- 「HF(Hugging Face)が公開しているSHA256と一致すれば再ダウンロードしない、不一致なら入れ直す」と書くのが正確。
- Source: https://huggingface.co/docs/hub/storage-backends

---

## 3. 細かい点

- **L20**：「使用不可な**モデル**はグレーアウト」は、正しくは「使用不可な**チップ**」（CPU・GPU・NPUを切り替える項目のため）。
- **L11**：`Programing`は`Programming`の綴り間違い（前回の⑮）。
- **L86**：Python同梱ランタイムにはChaquopyなどのSDK(Software Development Kit)が必要（前回の⑬）。
  - Source: https://chaquo.com/chaquopy/

---

## 4. L56「どのモデルを搭載するかは生成AIが決める」への提案

決めた条件：

1. Thinkingスイッチが使えること（Qwen3の切替対応の初期版で、2507版ではない）
2. ライセンスがApache 2.0で、HFのaccess tokenがなくてもダウンロードできること
3. スマホの搭載RAM(Random Access Memory)で動くこと

| 区分 | モデル（HF repo） | GGUF Q4_K_Mのファイルサイズの目安 | 対象の搭載RAM | Thinking |
|---|---|---|---|---|
| 軽い | `Qwen/Qwen3-1.7B-GGUF` | 約1.1GB | 4〜6GB | 切替可 |
| 普通 | `Qwen/Qwen3-4B-GGUF` | 約2.5GB | 8GB | 切替可 |
| 少し重い | `Qwen/Qwen3-8B-GGUF` | 約5GB | 12GB | 切替可 |
| 重い | `Qwen/Qwen3-14B-GGUF` | 約9GB | 16GB以上 | 切替可 |

- 32B級の「とても重い」段階は、スマホの搭載RAMでは動かないため外した。
- ファイルサイズは目安。動かすときはこれにKV cache（会話の文脈を保持するメモリ）が加わるので、対象RAMには余裕を持たせている。
- Gemma 3nは推奨から外した：
  - llama.cppで動かす場合、PLE(Per-Layer Embeddings)による省メモリの効果が得られず、E2Bでも実際には約5B（50億）パラメータ分を読み込む。
  - HFのaccess tokenも必要になる。
  - 入れるなら「Thinkingなし・軽量ではない」扱いの追加枠がよい。
- 区分は端末の搭載RAM（`ActivityManager.MemoryInfo.totalMem`）で自動判定し、その端末で推奨できない区分はグレーアウトする。
- Source: https://huggingface.co/Qwen/Qwen3-8B-GGUF
- Source: https://huggingface.co/Qwen/Qwen3-8B （thinking・non-thinkingの切替について）
- Source: https://ai.google.dev/gemma/docs/gemma-3n （E2Bの実パラメータ数が5Bであることについて）
- Source: https://developer.android.com/reference/android/app/ActivityManager.MemoryInfo

---

## 5. 確認事項

- 「1から修正」は、v2・v3の決定をいったん白紙に戻す意図か、それとも書き直す際の抜け落ちか。
- 抜け落ちであれば、2章の内容を戻した清書版を作成する。
