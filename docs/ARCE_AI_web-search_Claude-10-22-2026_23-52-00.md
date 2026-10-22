# ARCE.AI オンライン検索（0.8.6）

## 1. 起きたこと
チャットで最新情報を調べさせると、「検索に失敗（ローカルAIのみで回答）: DuckDuckGo Instant Answer: no results」になった。

## 2. 原因（コードで確認）
- 検索の順番は、SearXNG（アドレスを入れたときだけ）→ DuckDuckGo Instant Answer。アドレスが空だと、Instant Answer だけが残る（`lib/services/app_controller.dart`）。
- Instant Answer は、百科事典のような要約と関連項目だけを返す API で、普通のキーワード検索の結果一覧は返らない（`lib/core/search.dart` の既存コメントも同じ）。「Gemini の最新モデル」のような質問は、ほぼ空になる。

## 3. 0.8.6 の変更
- 検索の API を足した：**Brave Search API**（`BraveSearchProvider`）。`GET https://api.search.brave.com/res/v1/web/search?q=…&count=…`、キーはヘッダー `X-Subscription-Token`。結果は `web.results[]` の `title`・`url`・`description`（強調のタグと実体参照は外す）。
- 検索の順番：SearXNG（入れていれば）→ **Brave（キーがあれば）**→ DuckDuckGo Instant Answer。
- API キーは**設定のテキストではなく、安全な領域**（`SettingsStore.setBraveApiKey`、GitHub トークンと同じ扱い）。設定の JSON、バックアップ、チャットには出ない。URL にも入れない。チャットの `get_settings` / `update_settings` の対象外。
- 設定画面（検索の項目）に「Brave Search API キー」を足した。
- SearXNG も Brave も無いときは、検索が失敗した表示とモデルへの返答に、「設定の Brave Search API キーか SearXNG のアドレスを入れてください」と案内を付ける。

## 4. 確認したこと／していないこと
- 確認：URL とヘッダーの形、キーが URL と設定 JSON に入らないこと、強調タグの除去、順番、案内の表示（テスト 408 件）。
- **未確認**：Brave の公式 docs をこの環境から開けず（`ENOTFOUND`）、検索で見つかった要約でエンドポイント・`X-Subscription-Token`・`web.results` までは確かめた。`url`／`description` の項目名と無料枠の上限は、公式で確かめられていない。実機で、キーを入れて検索できるかを見てほしい。
- 使わなかった方法：DuckDuckGo の HTML ページの取得（公式の API ではなく、ブロックされやすい）。

## 出典
- Brave Search API（公式 docs）：https://api.search.brave.com/app/documentation/web-search/get-started
- Brave Search API の認証：https://api-docs.search.brave.software/guides/authentication
