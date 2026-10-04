# ARCE.AI 企画書 v3 技術レビュー

- 対象：`ArceAI___v3.txt`（行番号は同ファイル基準）
- 作成日：2026-09-26
- 結論：前回の指摘⑩〜⑬は全て反映済みで、未決定事項も「★【要決定】」として本文に明記された。残っている問題は、**前々回の指摘の一部が未反映のままであること**と、**書き写しの途中で仕様が崩れた箇所があること**。

---

## 1. 反映状況

| 指摘 | 状況 |
|---|---|
| ⑩ モデル表をQwen3系に更新 | ✅（L176-188） |
| ⑪ 変更履歴と本文の矛盾 | ✅（L194「要決定」、L510） |
| ⑫ MLC-LLMでモデル形式が増える | ✅（L221-225、L365-368） |
| ⑬ Pythonランタイム（Chaquopy） | ✅（L416-418） |
| ① NPUとGGUFは直結しない | ✅ 要決定として明記（L242-245） |
| ② OpenCLに統一するのは危険 | ❌ 未反映（L249、L363、L385） |
| ④ VPN(Virtual Private Network)・SearXNGのJSON有効化・fallback | ❌ 未反映（L261-265） |
| ⑤ 検索を毎回しない・エラーの種類ごとにやり直し地点を分ける | ❌ 未反映（L93、L104-109、L491） |
| ⑥ HyperLoadの周回上限・打ち切り条件 | ❌ 未反映（L32-34） |
| ⑦ 繰り返し防止にDRY(Don't Repeat Yourself) samplerを併用 | ❌ 未反映（L443、L479） |
| ⑨ 履歴の保存先・Open-Meteoの非商用条件・プレビューの間引き | ❌ 未反映 |

※①〜⑨の詳細は `ARCE_AI_review_v2_Claude-09-26-2026_16-42-38` を参照。

---

## 2. 書き写しで仕様が崩れた箇所（v1から劣化）

### ⑭ 太字記法の`**`が消えている（L44）
- 「太字は `<text>` 記法」となっていて、v1の`**<text>**`から`**`が抜けている。v2のPDFを作るときに太字の指定として解釈されて消え、それがそのまま引き継がれたもの。
- system promptに書き込む仕様なので、正しくは「太字は `**<text>**` 記法」。

### ⑮ Artifact記法が食い違っている（L41 vs L433）
- L41は`` `<Programing Code>` ``、L433は```` ```<programing>``` ````。大文字小文字も囲み方も違う。
- さらに「Programing」は「Programming」の綴り間違い。
- アプリはこの記法を目印にArtifactを見つけて切り出すので、1つに統一しないと実装できない。
- 標準のcode fence（```` ```html ````のように、言語名を付けた囲み）にしておけば、モデルがもともと学習している書き方なので出力が安定する。

### ⑯ 質問タイルのJSONが、JSONとして成り立っていない（L70-71）
- `{"title","options","allow_free_input"}`はキー名を並べただけで、値の型が書かれていない。
- v1の例に戻す：

```json
{"title": "質問文", "options": ["選択肢1", "選択肢2"], "allow_free_input": true}
{"title": "質問文", "options": ["選択肢1", "選択肢2", "選択肢3"], "multi_select": true}
```

- GBNF(GGML BNF) grammarやJSON schemaで出力の形を縛るには、型が必須（`title`は文字列、`options`は文字列の配列、`allow_free_input`・`multi_select`はboolean）。
- `allow_free_input`と`multi_select`を同時に指定してよいかも決めておく必要がある。
- Source: https://github.com/ggml-org/llama.cpp/blob/master/grammars/README.md

---

## 3. 新しいモデル表について

### ⑰ Qwen3の「2507」版ではThinkingスイッチが使えない
- 2025年7月に出たQwen3-2507系は、Instruct版（考えない）とThinking版（常に考える）に分かれている。`/think`・`/no_think`による切り替えはできない。
- Thinkingスイッチを使うには、切り替え対応の初期版（例：`Qwen/Qwen3-8B`）を指定する必要がある。モデル表にはrepo名まで書いておくのが安全。
- Source: https://huggingface.co/Qwen/Qwen3-4B-Instruct-2507 （「non-thinking modeのみ対応」と明記）
- Source: https://huggingface.co/Qwen/Qwen3-8B

### ⑱ Gemma 3nの呼び方が正しくない（L176、L180）
- Gemma 3nの正式な呼び方は **E2B / E4B**（Eはeffective parameters＝実効パラメータ数）。
  - 「Gemma 3n-4B」は正しくは「Gemma 3n E4B」。
  - L176の「Gemma 3n」はE2Bのことだと明記する。
- Gemma 3nにThinking機能はない。表の中で、Thinkingに対応するモデルかどうかも示しておくと親切。
- Source: https://ai.google.dev/gemma/docs/gemma-3n

### ⑲ 表のサイズはファイルサイズで、必要なRAM(Random Access Memory)ではない
- 実際に動かすと、モデル本体に加えてKV cache（会話の文脈を覚えておくためのメモリ）が必要。文脈が長くなるほど増える。
- 端末のRAMと比べて段階を判定するなら、「ファイルサイズ＋余裕分」で比べる必要がある。
- Source: https://huggingface.co/Qwen/Qwen3-14B-GGUF

### ⑳ DeepSeekの扱いが食い違っている（L161、L200）
- 本文では「Qwen・Gemma・Deepseekをダウンロード」「Deepseekは量子化・蒸留版のみ」と書いている。しかしモデル表からDeepSeekは消えている。
- 表に戻すのか、本文から消すのかを決める。
- 戻す場合は、前回の⑧（R1-Distillは常にThinkingが出てOFFにできない）への対応が必要。

---

## 4. 次のステップ

1. 要決定事項（NPUを2系統にするか見送るか・ビルド方式A/B・「とても重い」区分）を決める
2. ②④〜⑨・⑭〜⑳を反映し、v4企画書として清書する
