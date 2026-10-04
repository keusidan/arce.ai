# ARCE.AI 決定事項（Q1〜Q18）技術レビュー

- 対象：`ARCE_AI________________.pdf`（決定事項の一覧・1ページ）
- 作成日：2026-09-26
- 前提：Q3・Q4・Q8・Q13などは選択肢の本文が手元にないため、ラベル（「機能優先」「複数方式を併用」等）から意味を推定してレビューしている。推定が違う場合は指摘してほしい。
- 結論：前回の最重要事項だった **配布方法がGitHub配布（Q1.A）に決まり**、端末上でのビルドを実現する道筋ができた。多くの項目は前回レビューの推奨どおり。ただし **決定同士がぶつかっている組み合わせが4つ** ある。

---

## 1. そのまま進めてよい決定

| 項目 | 決定 | コメント |
|---|---|---|
| Q5 推論エンジン | llama.cpp主軸、MLC-LLMは`InferenceEngine`配下 | 前回の提案どおり |
| Q6 モデル形式 | エンジンごとに別リスト | 量子化方式の違い（Q4_K_M / q4f16_1）にも対応できる |
| Q7 KV Cache | Developer Settingsで変更可能 | 前回の提案どおり |
| Q9 Agentのモデルサイズ | Agentごとに最低サイズを設定 | 前回の提案どおり |
| Q11 JSONエラー | Grammar厳格化＋失敗・途中切断時のみ再生成 | 前回の提案どおり |
| Q12 HyperLoadの温度管理 | 警告してユーザーが判断 | 13章「設定を勝手に変えない」方針と一致 |
| Q14 UI | Jetpack Compose | ― |
| Q15 履歴DB | Room | ― |
| Q18 テスト | 機能単位＋最終統合テスト | 下の5-②も参照 |

---

## 2. 決定同士がぶつかっている箇所

### ① Q2「完全サンドボックス」は、Androidの仕組み上そのままでは実現できない
- Androidの権限（ネットワーク・ストレージ等）は**アプリ単位**で与えられる。アプリの中で動かしたコードは、同じアプリの権限をすべて持つ。
  - つまり、生成したコードがモデルファイル・履歴DB・HFのaccess tokenを読めてしまう。
- **Chaquopy（Q16）はアプリと同じプロセスの中でPythonを動かす**ため、サンドボックスにはならない。
- 本当に隔離できるのは、`android:isolatedProcess="true"`を指定したServiceだけ。このプロセスは、権限なし・アプリのファイルにアクセス不可・ネットワーク不可になる。
  - ただし、Termuxの環境（アプリのデータ領域にある）も読めなくなるので、ビルドや実行をこの中で行うことはできない。
- **提案**：「完全」ではなく、次のように段階を分けて定義する。

| 実行するもの | 実行場所 | 隔離の強さ |
|---|---|---|
| Artifact（HTML/JS） | WebView（下の②の設定） | 強い |
| 生成したPython・シェル | 別プロセス＋専用の作業フォルダ＋実行前にユーザーが承認 | 中（同じUIDなので完全ではない） |
| ビルド（Gradle等） | 同上 | 中 |

- Source: https://developer.android.com/guide/topics/manifest/service-element#isolated

### ② Q3「WebViewは機能優先」とQ2「完全サンドボックス」の両立
- 機能を優先して`addJavascriptInterface`やfile accessを有効にすると、AIが生成したJavaScriptがアプリ内部の機能やファイルに触れられる。Q2の方針と正反対になる。
- **提案**：機能を広げる場合も、`addJavascriptInterface`の代わりに`WebViewCompat.addWebMessageListener`を使う。
  - 許可したoriginからのメッセージだけを受け取り、アプリ側で「どの操作を許すか」を1つずつ決められる。機能と安全を両立できる。
- Source: https://developer.android.com/reference/androidx/webkit/WebViewCompat#addWebMessageListener(android.webkit.WebView,java.lang.String,java.util.Set%3Cjava.lang.String%3E,androidx.webkit.WebViewCompat.WebMessageListener)

### ③ Q10「特殊記法をすべてJSON Schema / Grammarに統一」は、回答の質とThinkingに影響する
- 太字やArtifactまで含めて**全出力をJSONに縛る**と、次の問題が出る：
  1. **回答の質が下がる**：出力形式を厳しく縛ると、推論の性能が落ちるという研究報告がある。
  2. **Thinkingと衝突する**：Qwen3は回答の前に`<think>…</think>`を出力する。先頭からgrammarで縛ると、この部分が出せなくなる。
  3. **ストリーミング表示が難しくなる**：途中まで生成されたJSONを、少しずつ解析しながら画面に出す仕組みが必要になる。
- **提案**：grammarは**構造が必要な部分（質問タイル・tool call）だけ**に使い、本文はMarkdown（太字`**`、Artifactはcode fence）のままにする。
- Source: https://arxiv.org/abs/2408.02442 （Let Me Speak Freely? 出力形式の制約が推論性能に与える影響）
- Source: https://github.com/ggml-org/llama.cpp/blob/master/grammars/README.md

### ④ Q16「Chaquopy＋Termux Python」の二重持ち
- Pythonの実行環境が2つになり、APKのサイズとバージョン管理の手間が2倍になる。
- さらにChaquopyは、**pipのパッケージをアプリのビルド時にしか入れられない**。AIが生成したコードが新しいパッケージを必要としても、アプリ内では追加できない。
- Q1でTermuxの環境を持つことが決まったので、**Termux Pythonに一本化**するのが合理的。
- Source: https://chaquo.com/chaquopy/doc/current/android.html

---

## 3. Q1「GitHubで配布」で新たに必要になること

### ① Android開発者の本人確認（developer verification）
- Googleは2026年から、**Play Store以外で配布するアプリも、Googleに本人確認済みの開発者が署名したものでないと、認定Android端末にインストールできない**仕組みを段階的に導入している。
  - 2026年9月からブラジル・インドネシア・シンガポール・タイで開始、2027年以降に全世界へ拡大予定。
  - 学生・趣味の開発者向けの区分も用意されると発表されている。
- 日本で配布する時期までに、開発者登録が必要になる可能性が高い。
- Source: https://developer.android.com/developer-verification

### ② targetSdk 28の寿命
- Android 14から、targetSdk 23未満のアプリはインストールできなくなった。今後この下限が引き上げられると、targetSdk 28のアプリもインストールできなくなる。
- これはTermux本体も抱えているリスクなので、Termuxの対応を追いかける前提にしておく。
- Source: https://developer.android.com/about/versions/14/behavior-changes-all#minimum-target-api-level

### ③ アップデートの仕組み
- Play Storeの自動更新がないので、次の2つを仕様に加える：
  - GitHub ReleasesのAPIで新しい版を確認し、ユーザーに通知する機能
  - APKの署名鍵の管理（鍵をなくすと、アップデートを配布できなくなる）
- Source: https://docs.github.com/en/rest/releases/releases#get-the-latest-release
- Source: https://developer.android.com/studio/publish/app-signing

---

## 4. 選択肢はよいが、中身を決める必要がある項目

### Q4 Searchは「複数方式を併用」
- どの方式を、どの順番で使うかを決める。例：
  1. Raspberry Pi 5のSearXNG（VPN経由）
  2. つながらなければ、別の検索API
  3. それも失敗したら、ローカルAIだけで続ける（企画書6章）
- 複数の方式から結果を取る場合、同じページが重複しないようにまとめる処理も必要。
- Source: https://docs.searxng.org/

### Q8 AgentはAIが自動選択
- Agentを選ぶ処理自体が推論になるので、回答の前に1回余分に推論が走る。1.7Bクラスのモデルでは選択を間違えやすい。
- **提案**：
  - キーワードなどのルールで先に候補を絞り、迷ったときだけAIに選ばせる。
  - ユーザーがいつでも手動で変更できるようにする。
  - 選ばれたAgentの最低モデルサイズ（Q9）を、今読み込んでいるモデルが満たさない場合は、13章の方針どおりユーザーに確認する。

### Q13 Force Executionは「A〜Cすべて許可」
- メモリが足りない状態で強制的に実行すると、アプリはLMK(Low Memory Killer)によってその場で終了させられる。エラーとして捕まえることはできない。
- 実行する前にGeneration Taskの状態（10章）を保存しておき、次に起動したとき「前回は強制実行中に終了した」と表示できるようにしておく。
- Source: https://developer.android.com/topic/performance/memory-management

---

## 5. 開発順序（Q17）とテスト（Q18）

### ① 技術的に一番難しい部分を先に確かめる
- 今の順番（UI → AI → … → Build → 最適化）だと、**一番難しいBuild（端末上のGradle）が最後**になる。
- Buildに必要なTermux環境とtargetSdk 28は、アプリの土台を決める条件でもある。最後に作れないと分かると、全体の作り直しになる。
- **提案**：本格的な開発の前に、次の2点だけ小さく試作して確かめておく。
  1. アプリ内のTermux環境で、Hello WorldのAPKがビルドできるか
  2. llama.cppでQwen3が動き、回答を少しずつ表示（ストリーミング）できるか
- UIも、AIの実際の出力（ストリーミング・Thinking・質問タイル）を見ながら作るほうが手戻りが少ない。

### ② テストに使う端末の組み合わせ
- GPUの種類によって動作が変わるので、機能単位のテストはAdreno（Snapdragon）とMali（Dimensity / Exynos / Tensor）の両方で行う。
- Source: https://github.com/ggml-org/llama.cpp/blob/master/docs/backend/OPENCL.md

---

## 6. 決めてほしいこと

1. Q2のサンドボックスの定義（2-①の表で進めてよいか）
2. Q10を「grammarは構造部分のみ」に変えるか
3. Q16をTermux Pythonに一本化するか
4. Q17の前に、2つの試作（Build・推論）を行うか
