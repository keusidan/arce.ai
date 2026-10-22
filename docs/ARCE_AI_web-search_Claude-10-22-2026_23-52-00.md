# ARCE.AI オンライン検索（0.8.6〜0.8.7）

## 1. 起きたこと
チャットで最新情報を調べさせると、「検索に失敗（ローカルAIのみで回答）: DuckDuckGo Instant Answer: no results」になった。

## 2. 原因（コードで確認）
- 検索の順番は、SearXNG（アドレスを入れたときだけ）→ DuckDuckGo Instant Answer。アドレスが空だと、Instant Answer だけが残る（`lib/services/app_controller.dart`）。
- Instant Answer は、百科事典のような要約と関連項目だけを返す API で、普通のキーワード検索の結果一覧は返らない（`lib/core/search.dart` の既存コメントも同じ）。「Gemini の最新モデル」のような質問は、ほぼ空になる。

## 3. 0.8.6 → 0.8.7 の変更：検索 API を自由に設定できる
0.8.6 は Brave 専用の項目だった。0.8.7 で、**どの検索サービスでも自分で登録できる**形にした（設定 → 基本設定 → 「検索 API」）。

- 1 件の項目：名前、URL、ヘッダー（JSON）、API キー、「結果の場所」、題名・URL・概要の項目名、使う／使わない。
- URL の `{query}` が検索語（URL エンコード）、`{count}` が件数、`{key}` が API キーに入れ替わる。`{key}` はヘッダーの値にも使える（例：`{"X-Subscription-Token": "{key}"}`）。**GET で JSON を返すサービス**が対象。POST のみのサービス（Tavily、Serper など）は、まだ対応していない。
- 結果の場所と項目名は、ドット区切り（`web.results`、`items` など）。答えそのものが一覧なら空にする。
- API キーは**安全な領域**（`search_key_<id>`）。設定の JSON、バックアップ、チャットには出ない。名前が機密らしいヘッダー（`Authorization`、`token`、`api-key` …）は、値を `{key}` にしないと保存できない。
- 「ひな形」：Brave Search と Google カスタム検索。どちらも項目は書き換えられる。「試す」で、保存する前に 1 回検索して、読み取れた件数を表示する。
- 検索の順番：SearXNG のアドレス（入れていれば）→ 登録した検索 API（一覧の順、有効なもの）→ DuckDuckGo Instant Answer。
- どれも無いまま検索に失敗したときは、「設定の検索 API か SearXNG のアドレスを入れてください」と案内する。
- 0.8.6 で Brave のキーだけを入れていた場合は、起動時に「Brave Search」の項目へ移す（キーも移して、古いキーは消す）。
- チャットの `get_settings` は、検索 API の名前・URL（`?` より前）・有効か・キーの有無を返す。**チャットからの追加・変更はできない**：URL を書き換えられると、保存済みのキーが別のサーバーに送られるため。

## 4. 確認したこと／していないこと
- 確認：URL とヘッダーの埋め込み（キーのエンコード、ヘッダー内のキー）、結果の場所と項目名の読み取り、強調タグの除去、キー未設定のときは呼ばないこと、機密らしいヘッダーの拒否、設定 JSON にキーが入らないこと、順番、案内の表示（テスト 413 件）。
- **未確認**：Brave と Google の公式 docs をこの環境から開けなかった（`ENOTFOUND`）。ひな形の項目名（Brave：`web.results`・`title`・`url`・`description`、ヘッダー `X-Subscription-Token`。Google：`items`・`link`・`snippet`、`cx`・`num`）は、記憶と検索結果の要約によるもので、公式では確かめていない。実機の「試す」で読み取れなければ、項目名を直せる。
- 未確認：0.8.6 の Brave キーの移し替えは、実機の安全な領域では試していない（テストでは動かせない）。
- 使わなかった方法：DuckDuckGo の HTML ページの取得（公式の API ではなく、ブロックされやすい）。

## 出典
- Brave Search API（公式 docs）：https://api.search.brave.com/app/documentation/web-search/get-started
- Brave Search API の認証：https://api-docs.search.brave.software/guides/authentication
- Google Programmable Search（Custom Search JSON API）：https://developers.google.com/custom-search/v1/overview
