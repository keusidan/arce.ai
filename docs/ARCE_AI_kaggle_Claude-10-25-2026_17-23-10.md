# ARCE.AI と Kaggle（0.8.17）

## 1. 「Kaggle の各機能」にどう対応するか
Kaggle には**公式の MCP サーバー**がある（[Kaggle のブログ](https://www.kaggle.com/blog/kaggles-official-mcp-server)の紹介による）。アプリはすでに MCP サーバー（Streamable HTTP・ベアラートークン）をチャットの道具として使えるので、Kaggle の機能は**この MCP で全部まとめて**使う。

ブログに書かれている道具の分野：
- ノートブック：管理、実行の開始・中止、出力の取得
- コンペティション：検索、メタデータ、データのダウンロード、提出
- データセット：ファイルの一覧、メタデータ、検索
- モデル：作成、メタデータ、ファイルのダウンロード、一覧
- ベンチマーク：`CreateBenchmarkTaskFromPrompt`、`GetBenchmarkLeaderboard` など

## 2. 変更
- 設定 → MCP サーバー →「MCP サーバーを追加」に、**「Kaggle を入れる」「GitHub を入れる」のひな形**を足した。押すと、名前と URL（`https://www.kaggle.com/mcp`）が入る。トークンは、Kaggle の設定 → API の「Generate New Token」で作ったものを入れる（安全な領域に保存。設定の JSON・バックアップ・チャットには出ない）。「確認」ボタンで、つながるか・道具の一覧が取れるかを確かめられる。
- **書き込みの道具は、実行の前に確認カードが出る**。これまでは、道具の名前に `create`・`delete`・`push` などの文字列が入っているかを見ていたため、`ListDatasets` のように「set」を含むだけの読み取りの道具も確認が出て、`Submit`・`Start`・`Cancel`・`Upload` のような Kaggle の書き込みは出なかった。道具の名前を**単語ごと**（`create_or_update_file` も `CreateBenchmarkTaskFromPrompt` も）に分けて、書き込みを表す単語（create・update・delete・submit・start・cancel・stop・run・upload・publish・save・post・send ほか）に当たるかで判定するようにした。サーバー自体の id は読まない。
- 「書き込みの前に確認する」はサーバーごとのスイッチ（既定オン）。コンペの提出やノートブックの実行（時間と回数に上限のある資源を使う）は、確認カードを通る。

## 3. 確認したこと／していないこと
- 確認：道具の名前の判定（書き込みと読み取りの例、サーバー id を読まないこと。テスト）、既存のテストがすべて通ること。
- **未確認**：
  - Kaggle の公式ページ（ブログ・API の説明）は、この環境から開けなかった（`ENOTFOUND`）。道具の分野と URL は、検索結果の要約によるもの。
  - **認証の方式**：第三者の表では「OAuth 2.0 またはトークン、`npx mcp-remote` が必要」とある。アプリの MCP は**ベアラートークンだけ**で、ブラウザで承認する OAuth の流れには対応していない。Kaggle のトークンをベアラーとして受け付けるかは、実際に「確認」を押して確かめる必要がある。受け付けなければ、OAuth への対応が要る。
  - Kaggle の道具の実際の名前（上の判定は、ブログの 1 例と一般的な名前で試した）。
- まだやっていない：Kaggle Models から**モデルのファイルを直接ダウンロードして端末で動かす**こと（いまのモデル一覧は Hugging Face）。Kaggle の API（`kagglehub`）のファイルの取り方が必要。

## 出典
- Kaggle の公式 MCP サーバー（ブログ）：https://www.kaggle.com/blog/kaggles-official-mcp-server
- 公式のリモート MCP の URL の記載（第三者の README の要約）：https://github.com/Galaxy-Dawn/kaggle-mcp
- Kaggle のコマンドライン（トークンの作り方）：https://github.com/Kaggle/kaggle-cli/blob/main/docs/README.md
- kagglehub：https://github.com/Kaggle/kagglehub
