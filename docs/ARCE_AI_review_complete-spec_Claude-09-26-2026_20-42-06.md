# ARCE.AI 企画書（完全版・全面改訂実装仕様書）技術レビュー

- 対象：`ARCE.txt`（全70章・章番号は同ファイル基準）
- 作成日：2026-09-26
- 結論：決定事項（Q1〜Q18）と、これまでのレビューの大半が反映された、実装に進める水準の仕様書になった。特に **WebViewの境界分離（18章）・実行前の承認（19・44章）・口調とシステムプロンプトの分離（20章）・「実機で検証していない技術的可否を確定事項として扱わない」原則（64章・69章-11）** は良い。残る問題は、**セキュリティの穴が1つ**、**仕様書の中での重複・矛盾が3つ**、**GitHub配布で必要になる項目の未記載**。

---

## 1. 反映状況

| 前回までの指摘 | 状況 |
|---|---|
| 配布方法 | ✅ GitHub配布（2章） |
| WebViewの設定と「機能優先」の両立 | ✅ ネイティブAPIとの境界を分離（18章） |
| 実行前の承認・既定の制限 | ✅（19・44・57章） |
| 口調とシステムプロンプトの分離・prompt injection対策 | ✅（20章） |
| Grammarの適用範囲 | △ 本文はMarkdownのまま、特殊形式だけに限定（5・10章）。ただしArtifactとThinkingに課題（3-②） |
| JSONエラーは修復せず再生成 | ✅（11・46章） |
| エンジンの抽象化・エンジン別のモデル一覧 | ✅（22・23・59章） |
| KV cacheを含めたメモリ表示・KV cacheの量子化 | ✅（25・26章） |
| Agentの定義・最低モデルサイズ | ✅（16章） |
| Compose一本化・Room | ✅（54・47章） |
| EXE生成の限界の明記 | ✅（41章） |
| Termux環境とサンドボックスの分離 | △ 方針はある（42章）が、Androidの仕組み上まだ分離できていない（2章） |
| Python二重持ち | △ 役割は分けた（43章）が、Chaquopyの用途が仕様内にない（3-③） |
| 開発順序 | ❌ Buildが最後のまま（3-④） |
| GitHub配布で必要になること | ❌ 未記載（4章） |
| Qwen3 2507版の注意 | ❌ 未記載（5章） |

---

## 2. セキュリティの穴：Termux環境はアプリ本体と同じ権限を持つ（42・57章）

- 42章は「サンドボックスと開発用Shell環境を分離する」、57章は「AI自身がアプリの権限やセキュリティ設定を変更できない構造にする」としている。
- しかしAndroidでは、**同じアプリの中で動くものは、すべて同じUID（ユーザーID）で動く**。
  - Termux環境で動かしたコード（AIが生成したPythonやシェルスクリプトを含む）は、アプリ本体のファイル（モデル・Room DB・設定）を読み書きできる。
  - つまり、生成コードが履歴DBや設定を書き換えることを、仕組みとして防げない。
- **提案：Termux環境を別のAPKに分ける**
  - 例：本体`ARCE.AI`と、ビルド・実行環境の`ARCE Build Env`（Termux:APIと同じ考え方）。
  - Androidはアプリごとに別のUIDを割り当てるので、Build Env側のコードは本体のファイルに一切触れられない。
  - 本体とはIntentやbound serviceで通信し、送るのはソースコードと成果物だけにする。
  - `sharedUserId`は使わない（使うと同じUIDになり、分けた意味がなくなる）。
- Source: https://source.android.com/docs/security/app-sandbox
- Source: https://github.com/termux/termux-api

---

## 3. 仕様書の中の重複・矛盾

### ① 同じ設定が2つの画面にある（35・51・52章）
- 「強制実行」：35章と51章はDeveloper Settings、52章は詳細設定にも入っている。
- 「エラー再試行回数」：51章（Developer Settings）と52章（詳細設定の「エラー再書き込み回数」）の両方にある。
- 35章は「危険性を伴うため通常設定から分離する」としているので、**Developer Settingsだけに置く**のが一貫する。

### ② ArtifactをGrammarで出させる場合の課題（10章）
- 10章はArtifactも「JSON Schema / Grammarで統一」の対象にしている。
- ArtifactはHTMLやコードそのものなので、JSONの文字列に入れると、改行や`"`をすべてエスケープ（`\n`、`\"`）して出力する必要がある。**小さいモデルほど、この書き方でコードの品質が落ちる**。
- またQwen3は回答の前に`<think>`を出すので、Grammarを最初から効かせるとThinkingが出せない。
- **提案**：
  - Artifactは「JSONのメタ情報（種類・ファイル名）＋code fenceで囲んだ本体」にする。
  - Grammarは、決まった合図の文字列が出たところから効かせる（llama.cppのlazy grammar／grammar triggerの仕組み）。こうすればThinkingや本文は自由に書かせ、tool callや質問タイルの部分だけを縛れる。
- Source: https://github.com/ggml-org/llama.cpp/blob/master/docs/function-calling.md
- Source: https://arxiv.org/abs/2408.02442

### ③ HyperLoadとFull Performanceが再び2つに分かれている（31・32章）
- 前回の版（1.1章）では「別機能として分けず、性能優先モードとして統合する」と決めていた。
- 今回は31章（HyperLoad）と32章（Full Performance）に分かれ、違いは「可能な範囲で積極的」と「常に最高性能」だけ。実装でどう変えるのかが決まらない。
- 統合に戻すか、違いを具体的に書く（例：HyperLoad＝スレッド数とGPU offloadを最大化、Full Performance＝それに加えて`PerformanceHintManager`で高クロックを要求）。
- Source: https://developer.android.com/reference/android/os/PerformanceHintManager

### ④ Chaquopyの用途が仕様内にない（43章）
- 43章ではChaquopyを「アプリ内部のPython処理」としているが、仕様書のどこにもPythonで行う内部処理がない（検索・JSON処理・DB操作はKotlinで書ける）。
- Chaquopyを入れるとAPKが数十MB増え、アプリのビルド時にしかパッケージを入れられない。用途がなければ外すのが合理的。
- Source: https://chaquo.com/chaquopy/doc/current/android.html

### ⑤ 開発順序でBuildが最後のまま（62章）
- 64章の「実機検証が必要な項目」には、targetSdk・Termux bootstrap・aapt2・APK Buildが入っている。これらはアプリの土台を決めるので、**Phase 1より前**に確認しないと、最後に全体を作り直すことになりかねない。
- **提案**：62章に「Phase 0：実機検証（Termux環境でHello WorldのAPKをビルド、llama.cppでQwen3のストリーミング表示）」を追加する。

---

## 4. GitHub配布で必要になる項目（2章に追記）

### ① targetSdkの明記
- Termuxと同じ方式でダウンロードしたツールを実行するなら、targetSdkは28になる。これを仕様に書いておく（64章の検証対象にも入っている）。
- Android 14から、targetSdk 23未満のアプリはインストールできなくなった。今後この下限が上がるリスクがある。
- Source: https://developer.android.com/about/versions/10/behavior-changes-10#execute-permission
- Source: https://developer.android.com/about/versions/14/behavior-changes-all#minimum-target-api-level

### ② 16KBページサイズへの対応
- Android 15以降、メモリのページサイズが16KBの端末が出てきている。llama.cppなどのnative library（`.so`）は16KB境界に揃えてビルドしないと、その端末で動かない。
- Play Store以外で配布する場合も同じ条件なので、NDKのビルド設定に入れておく。
- Source: https://developer.android.com/guide/practices/page-sizes

### ③ 開発者の本人確認・アップデート・署名鍵
- Googleは2026年から、Play Store以外で配布するアプリにも開発者の本人確認を段階的に求める（日本は2027年以降の予定）。
- Play Storeの自動更新がないので、GitHub ReleasesのAPIで新しい版を確認して知らせる機能と、APKの署名鍵の管理（鍵をなくすとアップデートを配れなくなる）を書いておく。
- Source: https://developer.android.com/developer-verification
- Source: https://docs.github.com/en/rest/releases/releases#get-the-latest-release
- Source: https://developer.android.com/studio/publish/app-signing

---

## 5. 細かい点

- **推奨モデル（21章）**：Thinkingスイッチを使うには、Qwen3の最初の版（例：`Qwen/Qwen3-8B`）を指定する。2507版は切り替えできない。
  - Source: https://huggingface.co/Qwen/Qwen3-4B-Instruct-2507
- **グレーアウトの基準（24・60章）**：「使用できないモデル」の判定基準を書いておく。例：「推定メモリ使用量（本体＋KV cache）が端末の搭載RAMを超えるもの」。Force Execution（35章）がONならグレーアウトを解除する。
  - Source: https://developer.android.com/reference/android/app/ActivityManager.MemoryInfo
- **破損の判定（29章）**：「破損時のみ再取得」の判定方法として、HFが公開しているSHA256と照合する、と書いておく。
  - Source: https://huggingface.co/docs/huggingface_hub/package_reference/hf_api
- **回答の重複防止（55章）**：system promptの指示に加えて、llama.cppのDRY(Don't Repeat Yourself) samplerを併用すると、小さいモデルでも効果が出やすい。
  - Source: https://github.com/ggml-org/llama.cpp/blob/master/tools/server/README.md
- **検索（8章）**：Search Layerの抽象化は良い。最初に実装するbackendを1つ決め（例：Raspberry Pi 5のSearXNG）、外出先からはVPN経由で接続することも書いておく。
  - Source: https://tailscale.com/kb/1017/install

---

## 6. 決めてほしいこと

1. Termux環境を別APKに分けるか（2章）
2. ArtifactのGrammar適用方法（3-②）とHyperLoad／Full Performanceの扱い（3-③）
3. Chaquopyを残すか（3-④）
4. Phase 0（実機検証）を追加するか（3-⑤）
