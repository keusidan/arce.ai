# ARCE.AI 完全版企画書（ARCEv2）技術レビュー

- 対象：`ARCEv2.txt`（全64章・章番号／行番号は同ファイル基準）
- 作成日：2026-09-26
- 結論：前回レビューの指摘の多くが反映された。特に **Phase 0の技術実証（45・46・61章）、HyperLoadの統合（4章）、Python一本化（23章）、GitHub配布の更新・署名・開発者確認（38〜40章）、Force Execution後の復旧（25.1章）** は良い。一方で、**Prototype 1（端末上のビルド）に大きな落とし穴が1つ**あり、**JSONの方針が以前の決定から逆戻り**している。

---

## 1. 反映状況

| 前回の指摘 | 状況 |
|---|---|
| Phase 0（実機検証）を最初に置く | ✅ 45・46・61章 |
| HyperLoadとFull Performanceの統合 | ✅ 4章 |
| Chaquopyを外してTermux Pythonに一本化 | ✅ 23章 |
| 同じ設定が2つの画面にある | ✅ 設定を基本設定／開発者設定に整理（8章） |
| アップデート通知・署名鍵・開発者確認制度 | ✅ 38〜40章 |
| Force Execution後の復旧 | ✅ 25.1章 |
| Agentのルール＋AI選択・手動変更 | ✅ 17.1章 |
| 検索結果の重複整理・優先順位 | ✅ 10章・37章 |
| 複数GPU系統での端末テスト | ✅ 48章 |
| Termux環境を別APKに分ける | ❌ 採用せず、方針を「バランス型」に変更（3章で説明） |
| ArtifactをGrammarで出させる件 | ❌ 逆方向に変更（4章で説明） |
| 16KBページサイズ対応 | ❌ 未記載 |
| Qwen3 2507版の注意 | ❌ 未記載 |

---

## 2. 最重要：Termuxのパッケージは、そのままでは別アプリで使えない（45・61章 Prototype 1）

Prototype 1は「Termux系環境 → JDK → Gradle → Android SDK → Hello World APK」を検証する計画になっている。ここに、検証の前に知っておくべき制約が2つある。

### ① Termuxのパッケージには、Termuxのインストール先が埋め込まれている
- Termuxのパッケージ（JDK・Python・clang等）は、`/data/data/com.termux/files/usr`というパスを前提にビルドされている。
- ARCE.AIはパッケージ名が違う（例：`/data/data/com.arce.ai/...`）ので、Termuxのパッケージをダウンロードしてもそのままでは動かない。
- 自分のアプリで使うには、**bootstrapと必要なパッケージを、ARCE.AIのパッケージ名で全部ビルドし直す**必要がある。
  - AndroidIDEもこの方法を取っている。
- Prototype 1は、「パッケージを自前でビルドする環境（termux-packagesのビルドスクリプト）を用意する」ところから始まる。所要時間を見積もりに入れておく。
  - ビルドにはDockerが使えるので、Arch LinuxのデスクトップPCで作業できる。
- Source: https://github.com/termux/termux-app#forking
- Source: https://github.com/termux/termux-packages/wiki/Building-packages

### ② Termuxのアプリ本体のコードはGPLv3
- termux-appのコードを取り込むと、ARCE.AI全体もGPLv3(GNU General Public License version 3)で公開する義務が生じる。
- 自前で書く部分とTermuxから流用する部分を分けるか、ARCE.AI自体をGPLv3のオープンソースにするかを決めておく。
  - GitHubで配布するので、GPLv3にする選択肢は取りやすい。
- 各パッケージ（OpenJDK・Gradle等）にも、それぞれのライセンスがある。
- Source: https://github.com/termux/termux-app/blob/master/LICENSE.md

---

## 3. サンドボックス方針（24章）：実装できない項目が1つある

- 「完全サンドボックスを前提にしない」「機能と安全のバランスを取る」という方針への変更は、現実的な判断。
- ただし、基本方針のうち **「重要なアプリデータへのアクセスを制限する」は、同じアプリの中で動かす限り実装できない**。
  - Androidでは同じアプリ内のコードはすべて同じUIDで動き、Room DB・設定・モデルファイルに同じ権限でアクセスできる。
  - Termux環境で動かしたPythonやシェルスクリプトから、これらのファイルを読み書きすることを、仕組みとして止められない。
- 次のどちらかに書き直す：
  1. **別APKに分ける**：UIDが分かれるので、この項目を実装できる。
  2. **同じアプリのまま**：「制限する」ではなく、「実行前にユーザーへ提示し、作業フォルダ外への書き込みを検出したら警告する（完全には防げない）」と書く。
- Source: https://source.android.com/docs/security/app-sandbox

---

## 4. JSONの方針が、以前の決定から逆戻りしている（12・26・60章）

- Q11.Aでは「Grammar厳格化＋途中切断時のみ再生成」と決め、前回の仕様書（11章）もそうなっていた。
- 今回の12章・26章・60章は「**自動修復**＋必要な場合のみ再生成」に戻り、さらに「**通常の文章・Thinking・Artifactも統一された出力構造の中で扱う**」となっている。
- 問題点：
  - Grammarで縛っていれば、形式が崩れたJSONは出ない。「自動修復」の処理を書いても、実際に動く場面がない。
  - Qwen3は回答の前に`<think>`を出力する。全出力をJSONで縛ると、Thinkingが出せないか、JSONの文字列の中に閉じ込める必要がある。
  - Artifact（HTML・コード）をJSONの文字列に入れると、改行や`"`をすべてエスケープする必要があり、小さいモデルほどコードの品質が落ちる。
- 12章の最後に「ストリーミングとの互換性はPrototype 2で検証する」とあるのは良い。
- **提案**：Prototype 2で次の2方式を**両方試して比較**し、その結果で決める。
  - **A. 全出力をJSONで縛る**（今回の案）
  - **B. 本文・Thinking・Artifactは自由に書かせ、tool call・質問タイルの部分だけGrammarで縛る**（llama.cppのlazy grammar）
  - 比較する観点：Thinkingが出るか、Artifactのコードが壊れないか、ストリーミング表示できるか。
- Source: https://github.com/ggml-org/llama.cpp/blob/master/docs/function-calling.md
- Source: https://arxiv.org/abs/2408.02442

---

## 5. NPUが再び入っているが、動かす手段がない（7・41章）

- 7章と41章に「対応端末でのNPU系Backend」が入っているが、41章の使用技術には、GGUFモデルをNPUで動かすライブラリが書かれていない。
- 入れるなら、具体的なライブラリ（例：LiteRT-LMと、それ用の別形式のモデル）を書き、Phase 0の検証項目に加える。入れないなら削除する。
- Source: https://github.com/google-ai-edge/LiteRT-LM

---

## 6. 細かい点

- **16KBページサイズ（40章に追記）**：Android 15以降の16KBページの端末では、llama.cpp等のnative library（`.so`）を16KB境界に揃えてビルドしないと動かない。自前でビルドするTermuxパッケージも同じ。
  - Source: https://developer.android.com/guide/practices/page-sizes
- **targetSdk（40章）**：「継続的に確認する」だけでなく、「targetSdk 28で開始する（ダウンロードしたツールを実行するため）」と現時点の方針を書いておく。
  - Source: https://developer.android.com/about/versions/10/behavior-changes-10#execute-permission
- **推奨モデル（5.1章）**：Thinkingのオン・オフを切り替えるには、Qwen3の最初の版（例：`Qwen/Qwen3-8B`）を指定する。2507版は切り替えできない。
  - Source: https://huggingface.co/Qwen/Qwen3-4B-Instruct-2507
- **使用技術（41章）**：「GGUF」「CPU」「ARM Neon」はライブラリではない（形式・ハードウェア・命令セット）。「対応形式・ハードウェア」として別の見出しに分けると読みやすい。
- **Search（10章）**：方式は設定可能で良い。ただしPhase 3で最初に実装する1つ（例：Raspberry Pi 5のSearXNG＋VPN）は決めておく。
  - Source: https://docs.searxng.org/

---

## 7. 決めてほしいこと

1. Termuxのパッケージを自前でビルドする前提でPrototype 1を進めるか（2-①）
2. ARCE.AIのライセンス（GPLv3にするか）（2-②）
3. 24章の「重要データへのアクセス制限」の書き方（別APKにする／「警告のみ」と書く）（3章）
4. Prototype 2でJSON方式A・Bを比較するか（4章）
5. NPUを残すか（5章）
