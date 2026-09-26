# ARCE.AI 企画書 v2 技術レビュー

- 対象：`ARCE_AI_proposal_v2.md`（行番号は同ファイル基準）
- 作成日：2026-09-26
- 結論：v1レビューの指摘は全て反映済み。ただし **矛盾1件・未決定事項・設計上の抜け** が残っている。

---

## 1. 仕様間の矛盾（実装前に解消が必要）

### ① NPUとGGUF(GPT-Generated Unified Format)は直結しない（L64）
- LiteRTはllama.cpp用のGGUFモデルを読めない。NPU経路には別のモデル形式（`.litertlm`等）と別の推論エンジン（LiteRT-LM）が必要。
- つまり「推論エンジン2系統＋NPU用モデルの別ダウンロード」になる。
- 設計案：推論エンジンを`InferenceEngine`というinterfaceで抽象化し、「llama.cpp実装」と「LiteRT-LM実装」を差し替え可能にする。
- Source: https://github.com/google-ai-edge/LiteRT-LM

### ② GPU backendを「OpenCLに統一」は危険（L65）
- llama.cppのOpenCL backendはAdreno（Snapdragon）向けに最適化されたもの。
- Mali/Immortalis（Tensor・Exynos・Dimensity）では恩恵がなく、Pixelはそもそも`libOpenCL.so`を積んでいない。
- 提案：端末ごとに「Adreno→OpenCL、それ以外→Vulkan、どちらも不可ならCPU」と切り替える。
- Source: https://github.com/ggml-org/llama.cpp/blob/master/docs/backend/OPENCL.md

### ③ 文字色の指定が食い違っている（L111 vs L112）
- L111「白のSans-serif」とL112「背景に合わせて自動選択」が矛盾。白背景のテーマでは白文字が見えなくなるため、L112に統一する。
- Source: https://www.w3.org/TR/WCAG21/#contrast-minimum

---

## 2. 未決定事項

| 項目 | 現状 | 提案 |
|---|---|---|
| 「とても重い」段階（L56） | 「要見直し」のまま | 段階ごと削除、または「今の端末では実行不可」と表示しダウンロードボタンを無効化 |
| 推奨モデルの決め方（L55） | 「AIが推奨モデルを選定」 | モデル選択前はAIが動いていないため、`ActivityManager.MemoryInfo.totalMem`で端末のRAM(Random Access Memory)を取得しルールで決定 |
| ビルド方式（L78-79） | 案A/案Bが併記のまま | MVP(Minimum Viable Product)は案A、案Bは後から追加 |

- ビルド方式で案Aを推す理由：desktop PCがWindows 11とのマルチブートのため、Windows起動中はビルドサーバーとして使えない。
- 設定の「APK生成 ON/OFF」（L35）の意味も、どちらを選ぶかで変わる。
- Source: https://developer.android.com/reference/android/app/ActivityManager.MemoryInfo

---

## 3. 設計上の抜け

### ④ 家の外からRaspberry Pi 5に届かない（L69）
- スマホが家の外にいるとき、Pi 5上のSearXNGにはそのままでは接続できない。VPN(Virtual Private Network)が必要で、Tailscale（WireGuardベース）が手軽。
- SearXNGをインターネットに直接公開するのは避ける。
- SearXNGのJSON APIは初期状態では無効。`settings.yml`の`search.formats`に`json`を追加する。
- Pi 5に繋がらないときのfallback（検索機能のグレーアウト等）を仕様に追加する。
- Source: https://docs.searxng.org/admin/settings/settings_search.html
- Source: https://tailscale.com/kb/1017/install

### ⑤ 処理フローで毎回検索する必要はない（L105-106）
- 雑談にもネットワークを使うのは無駄。検索はAIがtool callで必要と判断したときのみ実行する。
- エラーの種類によってやり直す地点を分ける：

| エラー種別 | やり直し地点 |
|---|---|
| JSONが壊れた | 生成のみやり直す |
| 通信エラー | 検索からやり直す |
| OOM(Out Of Memory) | やり直さず、軽いモデルを提案 |

- 特にOOMで検索からやり直しても、同じエラーを上限回数まで繰り返すだけになる。

### ⑥ HyperLoadの負荷と効果（L17）
- 仕組みとしては、自分の回答を自分で見直すSelf-Refineという手法に当たる。
- ただし推論の自己修正は、外部からのフィードバックがないと精度が上がりにくいという研究報告がある。
- スマホでは見直し1周ごとに生成時間がまるごと増えるため、以下を仕様に追加する：

    1. 周回数の上限（設定画面から指定）
    2. 途中で打ち切る条件
    3. Qwen3のThinkingと同時にONにしたときの扱い

- Source: https://arxiv.org/abs/2303.17651
- Source: https://arxiv.org/abs/2310.01798

### ⑦ 同じ文章の繰り返しはsamplingで防ぐ（L102, L117）
- system promptに書くだけでは、小さいモデルは守れない。llama.cppのDRY(Don't Repeat Yourself) samplerや`repeat_penalty`を併用する。
- Source: https://github.com/ggml-org/llama.cpp/blob/master/tools/server/README.md

### ⑧ Thinking対応の記述を修正（L59）
- DeepSeek-R1-Distillは、Thinking非対応ではなく**常にThinkingを出力する（OFFにできない）**。
- モデルごとに「切替可能 / 常時ON / 非対応」の3状態で管理する。
- Source: https://huggingface.co/deepseek-ai/DeepSeek-R1-Distill-Qwen-7B

### ⑨ 小さな抜け
- **履歴の保存先**：どこに保存するかが未記載。Room（AndroidのSQLite用ライブラリ）が標準的。
  - Source: https://developer.android.com/training/data-storage/room
- **Open-Meteoの無料枠**：非商用に限られる。Play Storeで広告付き・有料で配布する場合は有料プランが必要。
  - Source: https://open-meteo.com/en/terms
- **Artifactのリアルタイムプレビュー（L19）**：1トークンごとにWebViewを再読み込みすると画面がちらつく。更新を300ms程度に1回へ間引く旨を追記する。

---

## 4. 次に決めること
1. NPU：推論エンジンを2系統持つか、NPUを当面見送るか
2. ビルド方式：案A / 案B
3. 上記が決まればv3としてarchitecture設計（module構成と依存関係）に進む
