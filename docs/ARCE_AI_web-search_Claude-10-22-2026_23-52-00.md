# ARCE.AI オンライン検索（0.8.6〜0.8.10）

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
- GET だけに対応（0.8.7 の時点）。0.8.10 で POST に対応した（5 章）。
- 使わなかった方法：DuckDuckGo の HTML ページの取得（公式の API ではなく、ブロックされやすい）。

## 5. 0.8.10：RikkaHub の検索サービスに合わせて広げる
RikkaHub（Android の LLM アプリ）の検索サービスの一覧を、リポジトリの `search/src/main/java/me/rerere/search` にあるファイル名で確かめた：Bing、Bocha、Brave、CustomJs、DeepSeek、Doubao、Exa、Firecrawl、Grok、Jina、LinkUp、Metaso、Ollama、Perplexity、RikkaHub（自前）、SearXNG、Serper、Tavily、Tinyfish、Zhipu。（README には Exa・Tavily・Zhipu・LinkUp・Brave・Perplexity と、「etc.」とある。）

- 検索 API の設定を **POST（JSON の本文）**に対応させた。本文の `{query}` と `{key}` は JSON の文字列として、`{count}` は数字として入る（引用符・改行・日本語が入っても壊れない）。サービスごとの 1 回の件数の上限（`maxCount`）も設定にした。本文のひな形が JSON にならないときは、保存の前に分かる。
- ひな形を 13 件にした：Brave、Google カスタム検索、Tavily、Exa、Serper、Perplexity、Ollama、智谱（Zhipu）、Firecrawl、LinkUp、博查（Bocha）、Jina、秘塔（Metaso）。SearXNG は、これまでの「SearXNG のアドレス」で使える。
- **まだ対応していないもの（RikkaHub にあって、ここには無い）**：Bing（端末が検索ページを読む方式。公式の API ではなく、ページの形が変わると壊れる）、CustomJs（JavaScript で自作）、DeepSeek・Doubao・Grok（モデルに検索させる方式で、検索結果の一覧を取る API とは別の仕組み）、RikkaHub 自前のサービス、Tinyfish（形式を確かめられなかった）。そのため「同じ広さ」には、まだ届いていない。
- ひな形の形式の確かさ：Tavily・Exa・Serper・Perplexity・Ollama・智谱は、第三者の資料で本文・ヘッダー・結果の項目名が揃って見つかったもの（公式の docs は開けていない）。Firecrawl・LinkUp・Bocha・Jina・Metaso は、一部の項目名が確かめられなかったので、名前に「要確認」を付けた。「試す」で読み取れるかを確かめてから使う。
- 画面：設定の「基本設定」の「Search」の切り替え（チャットの入力欄の「検索」ボタンと重なるため）と、チャット画面のハンバーガーメニューの「詳細設定」（下のタブと右上の歯車と重なるため）を消した。検索のオン・オフは、チャットの入力欄のボタンで行う。

## 6. 0.8.11：設定画面の整理と、下のボタンが隠れる問題
- 「基本設定」を **「モデル全般設定」**に変えた。ローカルとオンラインで共通の設定をここに集めた：Thinking 表示、回答（口調・速度と精度・エージェント・返信の長さ）、最大トークン（共通）・再試行・ツール呼び出しの上限。前の「回答」「開発者設定」は、この中に入れた。
- **「検索設定」**を新しく作った：SearXNG のアドレス、検索結果の件数（「上限とタイムアウト」から移した）、検索 API の一覧。デスクトップ版のサイドバーの「詳細設定」にも「検索設定」と「モデル全般設定」を並べた（「回答の設定」「開発者設定」は無くした）。
- 検索 API などの下から出てくる編集画面で、**3 ボタンのナビゲーションバーが「試す」「保存」に重なって押しにくい**問題を直した。編集画面の下の余白を、キーボードの高さか、システムのバーの高さ（大きい方）にした（`sheetBottomPadding`）。プロバイダ・モデル・MCP・検索 API の 4 つの編集画面に効く。実機のバーの高さで見るのは、まだ。

## 7. 0.8.12：コーディングモードのモデルの選び方
設計モデルと開発モデルを選ぶ欄が、狭い一覧で「Google Gemini · gemini-2.5-fl…」のように名前を途中で切って、同じ名前に見えて選べなかった。欄を押すと**画面の幅いっぱいの一覧**が下から開き、すべての名前を省略せずに書くようにした（選んである項目にはチェック）。欄そのものは 2 行まで表示する。

## 出典
- Brave Search API（公式 docs）：https://api.search.brave.com/app/documentation/web-search/get-started
- Brave Search API の認証：https://api-docs.search.brave.software/guides/authentication
- Google Programmable Search（Custom Search JSON API）：https://developers.google.com/custom-search/v1/overview
- RikkaHub（検索サービスの一覧）：https://github.com/rikkahub/rikkahub/tree/master/search/src/main/java/me/rerere/search
- Tavily のヘルプ：https://help.tavily.com/articles/4840311948-tavily-search-api
- Ollama の Web 検索 API（ドキュメントの写し）：https://lzw.me/docs/ollama/zh-CN/capabilities/web-search.html
- Perplexity Search API：https://docs.perplexity.ai/guides/search-quickstart
- Exa（公式の curl ガイド）：https://docs.exa.ai/reference/getting-started-with-curl
- 智谱 BigModel のウェブ検索：https://docs.bigmodel.cn/api-reference/%E5%B7%A5%E5%85%B7-api/%E7%BD%91%E7%BB%9C%E6%90%9C%E7%B4%A2.md
