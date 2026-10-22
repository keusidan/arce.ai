# 添付ファイル：対応モデルなら画像、それ以外はテキストとして読む

## 動き

ファイルを添付すると、中身を見て次のように読む（`lib/core/attachments.dart` の `AttachmentReader`）。

| 中身 | 画像に対応するモデル | 対応しないモデル（端末のモデルを含む） |
|---|---|---|
| 画像（PNG / JPEG / GIF / WebP） | 画像として送る | 理由を出して断る（バイト列をテキストとして渡さない） |
| UTF-8 のテキスト（SVG・ソースコード・Markdown など） | テキストとして送る | テキストとして送る |
| そのどちらでもない（実行ファイル・圧縮ファイルなど） | 断る | 断る |

- 画像かどうかは**ファイルの先頭のバイト**で決める。拡張子は見ない（`.txt` に改名した画像も画像。SVG はテキストなのでテキスト）。
- 画像の上限は 1 枚 4 MB（Anthropic の 5 MB が最も低いため、それ未満にした）。添付は従来どおり 5 ファイルまで。
- テキストの上限（1 ファイル 8000 文字、合計 16000 文字）は従来どおり。画像は文字数の枠を使わない。

## 「画像に対応する」の決め方

モデルごとの設定（`ModelConfig.vision`）で決まる。設定画面のモデルの編集に **「画像を送る」** のスイッチがある。

- スイッチを触っていないモデルは、モデル名から目安で推測する（`ModelConfig.guessVision`。`gpt-4o`、`claude`、`gemini`、`llava`、`-vl` など）。推測は外れることがある。外れたら、このスイッチで直す。
- 端末のモデル（llama.cpp）はテキストだけ。画像は常に断る。
- 送り方は OpenAI 互換の `image_url`（`data:` URL に base64）。

## 仕組み（画像がプロンプトを通る道）

プロンプトは 1 本の ChatML のテキストなので、画像は本文の中に目印 `<image id="…" name="…"/>`（`ImageMarker`）で置き、画像のバイトは `GenerateRequest.images`（id → バイト）で別に運ぶ。`CloudEngine` が `ChatMlBridge.messages` に渡し、

- 対応するプロバイダ：目印を画像パートに置き換える
- 対応しない／バイトが無い：目印を `[画像: ファイル名]` の文字に置き換える

id は中身の SHA-256 の先頭 16 文字。同じ画像は同じ id になる。

## 制限（分かっていて、まだやっていないこと）

- 画像のバイトは、**会話を開いている間だけ**メモリにある。保存した会話を開き直すと、履歴には目印だけが残り、モデルには `[画像: ファイル名]` として見える（画像そのものは再送されない）。保存するには、履歴のデータベースの添付ファイルの置き場（`lib/data/llm_db.dart`）へ書く必要がある。
- 画像は縮小しない（画像ライブラリを入れていない）。上限を超える画像は断る。
- 画面の添付チップは、画像でもファイル名だけ。サムネイルは出さない。
- Anthropic など OpenAI 互換でない API の画像形式には、まだ対応していない。

## 確認したこと／していないこと

- 確認：`flutter analyze` と `flutter test`（251 件）。種類の判別、断る場合、目印の往復、リクエストの形（`image_url`）、モデル設定の保存と読み込み、`ChatController` から engine に画像が渡ること。
- 未確認：実際のクラウド API に画像を送った往復、実機でのファイル選択（`file_picker`）。

## 出典

- OpenAI 互換の画像入力（`image_url` と `data:` URL）：https://platform.openai.com/docs/guides/images-vision
- Anthropic の画像の上限（1 枚 5 MB）：https://docs.claude.com/en/docs/build-with-claude/vision
- 画像の先頭バイト：PNG https://www.w3.org/TR/png/#5PNG-file-signature 、WebP https://developers.google.com/speed/webp/docs/riff_container
