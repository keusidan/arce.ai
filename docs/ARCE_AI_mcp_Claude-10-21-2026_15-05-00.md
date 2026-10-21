# MCP（外部ツール）対応（2026-10-21・v0.6.0）

## 何を足したか

チャットから MCP サーバーの道具を呼べるようにした。GitHub 連携（コードを読む・コミットする・PR を出す）は
これで「MCP サーバーを1つ設定する」だけで動く。RikkaHub で使っている GitHub MCP の設定がそのまま流用できる。

- `lib/mcp/mcp_client.dart`：JSON-RPC 2.0 over HTTP（Streamable HTTP）。`initialize` →
  `notifications/initialized` → `tools/list` / `tools/call`。応答は JSON でも SSE（`data:` 行）でも読む。
  認証は `Authorization: Bearer <token>`。
- `lib/mcp/mcp_tools.dart`：サーバーのツールを、アプリの `ToolDefinition` に変換してチャットに渡す。
  名前は `mcp_` を前置（`mcp_get_file_contents`）し、呼ぶときに外す。サーバーが落ちていても
  ツールが無いだけでチャットは動く。
- `lib/core/protocol.dart`：`McpCall`（名前＋引数そのまま）と `ToolApproval`。
- `lib/core/chat_controller.dart`：そのターンのツール一覧に MCP のツールを足す（`extraTools`）。
  書き込み系（`create` / `update` / `push` / `merge` … を含む名前）はカードで確認し、
  **「実行する」を選ぶまで何も起きない**。読み取り系はそのまま実行。
- `lib/services/settings.dart`：`mcpEnabled` / `mcpUrl` と、トークン（secure storage の `mcp_token`）。
- `lib/ui/settings_page.dart`：「MCP（外部ツール）」の節（有効化・URL・トークン・接続確認）。

## 使い方

1. 詳細設定 →「MCP（外部ツール）」で「MCP を使う」をオン。
2. URL を入れる（GitHub なら `https://api.githubcopilot.com/mcp/` など、使うサーバーの入口）。
3. トークンを入れる（GitHub の PAT。最初は read-only の repo 権限から）。
4. 「確認」を押すと、サーバーが公開しているツール名がトーストで出る。
5. チャットで「このリポジトリの README を読んで」のように頼むと、`mcp_` 付きのツールが呼ばれる。
   書き込みは確認カードが出る。

## 決めたこと（と理由）

- **ツール名に前置をする**：モデルには1つの平坦なツール一覧が見える。サーバーが `search` のような
  アプリと同じ名前を使っていても衝突しない。
- **書き込みは名前の動詞で判定**：MCP のツール定義に「危険度」は無いので、`create` / `update` /
  `push` / `merge` などを含む名前を確認つきにした。読み取り（`get_` / `list_` / `search_`）は素通し。
  厳密さより「うっかり push しない」を優先した割り切り。
- **サーバーは1つ**：まず GitHub を通すのが目的なので、設定は URL 1本にした。複数必要になったら
  `mcpServers` の配列に広げる。
- **失敗してもチャットは止めない**：`tools/list` が落ちたらツール無しでそのターンを進める。
  呼び出しの失敗は `tool_response` としてモデルに返す（やり直しを考えられる）。

## まだ足りないこと（次の候補）

- テスト（`test/mcp/`）。クライアントの JSON-RPC / SSE 解釈は手元で書いたが、まだコミットしていない。
  次はここを CI に入れる。
- OAuth（GitHub のホスト型サーバーは OAuth 前提のことが多い）。いまは PAT を Bearer で送る形だけ。
- 複数サーバー、stdio トランスポート（Android では難しい）、ツール一覧のキャッシュ。
- 端末モデル（llama.cpp）では MCP の複雑な JSON Schema が GBNF に重い。**クラウドモデル推奨**。
- ツールの承認は名前の動詞による推定なので、`allowed` な読み取りでも `set` を含む名前なら確認が出る。
