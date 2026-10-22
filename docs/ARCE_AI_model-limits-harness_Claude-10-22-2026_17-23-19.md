# モデルごとの上限・自動取得・DeepSeek/GLM の公式の指示（2026-10-22 JST）

最初の依頼：DeepSeek V4.1 Flash が「少ししかいじらない」「指示を読めない」。原因を、指示の書き方より先に、アプリ側の設定と実装に探した。

## 1. 貼ってもらった分析を、コードで確かめた結果

対象は、この作業 branch（`main` の v0.8.0 に、この session の変更を足したもの。`dart` という名前の branch は無く、Dart 版の最新は `main`＋この branch）。

| 指摘 | 結果 |
|---|---|
| 最大トークンの既定が 2048（速度⇔精度が中央ならそのまま）で、思考の分も使うので途中で止まる | **正しい**。`effectiveMaxTokens` が `maxTokens × (0.5 + 速度精度)`＝2048。公式は DeepSeek V4.1 で **max_tokens ≥ 256K** を推奨し、`deepseek-recipe` の既定も「思考なし 8192／思考あり 65536／思考あり＋max で 131072」。2048 は 1/100 以下。→ **0.8.2 で直した** |
| temperature/top_p が Qwen3 用の値のまま | **正しい**（思考ありで 0.6/0.95、なしで 0.7/0.8）。公式は DeepSeek V4.1 で **1.0/1.0**、GLM-5 で **1.0/0.95**。→ **0.8.2 で直した**（ユーザーが決めていないときだけ、公式の推奨を使う） |
| 最大トークンを上げられない | 一部正しい。モデル設定の上限が 131072 だった（公式の推奨 256K 以上に届かない）。→ **1,048,576 まで** |
| ルールはモデル設定の「プロンプト」に書く | その通り（`ModelConfig.prompt` は毎回 system で先頭に入る） |
| A. 思考の指定がクラウドに届かない | **正しい**（思考スイッチは端末用の `<think>` を作るだけ。provider の `body` は 0.8.1 までは UI で編集できなかった）。→ 次の 0.8.3 |
| B. ツールの会話の形が合っていない（`<tool_call>` の文字列、`<tool_response>` を user に、推論を捨てる） | **正しい**。公式の `encoding` では、ツールを宣言すると **過去のターンの reasoning を全部残す**（`drop_thinking` が自動で無効になる）。→ 0.8.4 |
| C. ツール定義が二重（Qwen 形式の文章＋ネイティブの function calling） | **正しい**（`cloud_engine.dart` の注釈どおり、意図して二重にしている）。DeepSeek V4.1 のネイティブは DSML 形式で、`tools` から変換される。→ 0.8.4 |
| D. Coding エージェントにファイルを読み書きするツールが無い | **正しい**。MCP でつなぐか、アプリにツールを足す（今回は未対応） |

## 2. 一次情報で確認したこと

### DeepSeek-V4.1-Flash(-1017) の公式モデルカードと `encoding/README.md`
- 推奨：`temperature` 1.0、`top_p` 1.0、`context_window` 1M、`max_tokens` ≥ 256K。
- 推論の強さ（reasoning effort）は **1〜100 の数値**。`low`=50、`high`=75、`max`=100、既定は `high`。`thinking_mode` は `thinking` か `chat`。
- ツール呼び出しは **DSML 形式**（`<｜DSML｜ calls>` … ）。`tool` ロールは、直前の user に `<tool_result>` として入る。
- **ツールを宣言すると `drop_thinking` が自動で無効になり、全ターンの reasoning を残す**（ツールを使う会話は、複数ステップの推論を追うのに全文脈が要るため）。ツールが無いときは、直近の user の前の reasoning を捨てる。
- 画像は `<｜deepseek_image｜>`（V4.1 は画像を読める）。
- `config.json`：`text_config.max_position_embeddings` = 1,048,576。

### `deepseek-ai/deepseek-recipe`（公式）
- Messages / Chat Completions / Responses のリクエストを V4・V4.1 のプロンプトに変換し、出力（reasoning・ツール呼び出し・画像）を読み戻す Rust ライブラリ。推論・HTTP は呼び出し側。
- 既定の `max_tokens`：8192（思考なし）／65536（思考あり）／131072（思考あり＋max）。

### GLM-5.3 の公式モデルカード（zai-org）
- `reasoning_effort`：`low` / `high` / `max`。**渡さなければ `max`**。`low` と `high` は明示して渡す。
- チャットテンプレートの `clear_thinking` は、渡さなければ `false`。**チャットでは明示的に `true` にする**。
- 評価条件：`temperature` 1.0、`top_p` 0.95（または 1.0）、最大 64K〜128K（`128000`）の出力、コンテキスト 1M（`max_position_embeddings` 1,048,576）。

### 「DeepSeek Harness」
- **実在する**。公式は `github.com/deepseek-ai/deepseek-harness`（コマンド名 `dsh`）。MIT、**developer preview**（「互換性を壊す変更がある」と README に明記）、Cordis 上の「すべてがプラグイン」な agent 実行基盤（Node）。
- ただし README には、API の thinking・reasoning_content・サンプリング・上限の指定は**書かれていない**。つまり harness は **agent を動かす側の実装**で、アプリが従うべき**通信の仕様書ではない**。仕様にあたるのは、モデルカードの `encoding` と `deepseek-recipe`。
- 紛らわしいもの：`HenryZ838978/deepseek-harness` は**非公式**の再実装（reasoning_content が落ちて 400 になる問題への対策）。`deepseekharness.dev` など、公式を名乗るサイトの数字（キャッシュ率など）は根拠にしない。

## 3. 0.8.2 の変更

### 3.1 モデルごとの上限
- `ModelConfig` に **コンテキスト長**（`contextTokens`）と **最大出力**（`maxOutputTokens`）を追加。モデルの編集で直接入れられる。
- 最大トークンの決め方（強い順）：**モデルごとの設定 ＞ 設定画面でユーザーが決めた値 ＞ 公式の推奨 ＞ アプリの既定**。結果は、モデルの最大出力と、**文脈に残った分**（コンテキスト − 入力の見積もり − 512）に収める（収まらない要求はプロバイダが断るため）。temperature・top_p も同じ順。
- ユーザーが選んだ小さい値は、そのまま使う（下限で持ち上げない）。
- 公式の推奨があるのは、**モデルカードのあるバージョンだけ**：DeepSeek V4／V4.1、GLM-5 以降。それ以外は、これまでどおり。モデルの編集の「公式の推奨を入れる」で、欄に値を入れられる。
- 上限の引き上げ：モデルごとの最大トークン 131072 → 1,048,576。共通・オンライン・コーディングの設定も同じ（共通の選択肢に 16K〜256K を追加）。
- コーディングモードの設計/開発モデルの最大トークンは **0＝自動**（既定）に。モデルの推奨と上限に合わせる（推奨が無ければ 設計 8192／開発 16384）。0.8.1 が保存した固定の既定（2048／4096）は、自動に読み替える。思考モデルは思考の分も使うので、小さい固定値では答えが切れる。
- コーディングの各役も、モデルの推奨（temperature・top_p）と上限に従う。

### 3.2 自動取得
- 取得元（この順）：**① プロバイダの `GET /models`**、**② Hugging Face の `config.json`**（モデル名が `owner/name` の形のとき、文脈長だけ。`max_position_embeddings`、`text_config` の中も読む）。
- `/models` で読む欄（各社の公開ドキュメントにある名前）：文脈＝`context_length`・`context_window`・`max_context_length`（Mistral）・`max_model_len`（vLLM）・`inputTokenLimit`（Gemini）、出力＝`top_provider.max_completion_tokens`（OpenRouter）・`max_completion_tokens`・`outputTokenLimit`、画像＝`architecture.input_modalities`／`capabilities.vision`、ツール＝`supported_parameters`／`capabilities.function_calling`。**曖昧な `max_tokens` は読まない**（文脈の意味のサービスと、出力の意味のサービスがあるため）。
- いつ：①モデルを使い始めたとき（設定「モデルの上限を自動で調べる」。モデルごとに 1 回）。②プロバイダの「モデル」の「取得」（一覧の全モデルの空欄を埋める。新しいモデルは上限つきで追加）。③モデルの編集の「上限を取得」（上書き）。
- **ユーザーが入れた値は、①②では消さない**。提供元が言わなかったことで、既にある値も消さない。
- Hugging Face には**モデル名だけ**を送る（設定「Hugging Face からも調べる」でオフにできる）。`owner/name` 以外の名前は送らない。

## 4. 確認したこと／していないこと
- 確認：`flutter analyze`、`flutter test`（356 件）。優先順位、上限での丸め、各社の応答の形（公開ドキュメントの形の例で）、Hub の読み取り、値の保存、設定の移行。
- **未確認**：実際の各社の `/models` の応答（DeepInfra・Groq の欄名は、公式ドキュメントで確認できなかった。読めなければ「分からない」のままで、Hub か手入力になる）。DeepSeek API・Z.ai の **HTTP の引数名**（`api-docs.deepseek.com` と `docs.z.ai` は、この環境から開けなかった）。これは 0.8.3 で、追加リクエスト項目として利用者が決められる形にする。

## 5. 次
- 0.8.3：思考（thinking）・推論の強さを、provider に届ける。DeepSeek と GLM には専用の項目（公式の値：DeepSeek の 1〜100 または low/high/max、GLM の low/high/max と `clear_thinking`）。
- 0.8.4：ツールの会話を、provider のネイティブの形（`tool_calls`／`tool` ロール）で送り、`reasoning_content` を捨てずに返す。

## 出典
- DeepSeek-V4.1-Flash-1017 モデルカード：https://huggingface.co/deepseek-ai/DeepSeek-V4.1-Flash-1017
- 同 `encoding/README.md`：https://huggingface.co/deepseek-ai/DeepSeek-V4.1-Flash-1017/blob/main/encoding/README.md
- deepseek-recipe：https://github.com/deepseek-ai/deepseek-recipe
- DeepSeek Harness（公式）：https://github.com/deepseek-ai/deepseek-harness
- GLM-5.3 モデルカード：https://huggingface.co/zai-org/GLM-5.3
- OpenRouter の `/api/v1/models`：https://openrouter.ai/docs/sdks/typescript/models/modelslistresponse
- Mistral のモデル一覧の項目：https://apis.io/schemas/mistral/mistral-model/
- Groq のモデルごとの上限：https://console.groq.com/docs/models
- 非公式の再実装（根拠にしない）：https://github.com/HenryZ838978/deepseek-harness
