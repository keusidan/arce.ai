# バックグラウンドの自動更新と、クラウドモデルへの道具渡し（2026-10-21・v0.5.2）

## 1. バックグラウンドで自動更新する

設定「詳細設定 → アップデート」に **「自動で更新する」（`autoInstallUpdate`、既定 ON）** を足した。

- 起動時と、設定した間隔（既定12時間）の**自動チェック**（`UpdateService._autoCheck`）で新しい版を見つけたら、
  そのまま `download()` → 検証（既存の SHA-256 照合・中断からの再開をそのまま使う）→ `install()` まで進む。
- **手動**のチェック（「確認する」を押したとき）は今までどおり。カードに「ダウンロード」が出て、押してから動く。
  自動なのは「アプリが勝手にやる確認」の経路だけ、と分けている（テストの前提もこれで変わらない）。
- iOS は自動では動かさない（インストールできないので、リリースページを開くだけのため）。
- Android は初回だけ利用者がシステムの画面で「この提供元を許可」する必要がある。`canInstall()` が false のときは
  `requestInstallPermission()` を開いて**状態は `UpdateReady` のまま**残す。許可したあとに「インストール」を押せば入る。
- 失敗したときは `UpdateFailed` に理由が残り、画面に出る（黙って消えない）。

触った場所：`lib/services/settings.dart`（設定の追加）、`lib/services/update_service.dart`（`_autoCheck` /
`_downloadAndInstall` / 許可待ちの扱い）、`lib/ui/settings_page.dart`（トグルの行）。

## 2. クラウドモデルにも道具を渡す（設定の読み書きが効かなかった原因）

報告された症状：クラウド（プロバイダ）で「はい、変更できます。まず現在の設定内容を確認しますね。」と言うだけで、
`get_settings` が呼ばれない（ツールの表示も出ない）。

原因は最後の一歩が抜けていたこと。

- `AiRequest.tools` と `AiToolSpec`、`openai_compatible.dart` の `tools` 送信と `tool_calls` の解釈、
  `CloudEventAdapter` の `<tool_call>` 変換は、すべて v0.4.x で用意されていた。
- しかし `CloudEngine.generate` が `AiRequest` を組み立てるときに **`tools` を詰めていなかった**ので、
  プロバイダには道具の定義が一度も送られていなかった（端末モデルは GBNF で動くので気づきにくい）。

変更：

- `GenerateRequest` に `tools: List<ToolDefinition>`（既定 `const []`）を足した。端末エンジンは見ない。
- `ChatController` が、そのターンで許可されている道具をそのまま渡す（`toolCallSchema` と同じ並び）。
- `CloudEngine` が `AiToolSpec` に変換して送る。`provider.capabilities.tools` が false のときは送らない。

これで `get_settings` / `update_settings` がクラウドでも呼ばれ、承認カードもこれまでどおり出る。

## 3. 「思考」が表示されない件

- クラウド：`reasoning_content`（または `reasoning`）を読んで `<thinking>` として流す作りになっている。
  プロバイダやモデルがこれを返さない場合（例：`deepseek-chat` のような非 reasoning モデル）は、思考は出ない。
  `deepseek-reasoner` や GPT-OSS 系のように reasoning を返すモデルを選ぶ必要がある。
- 端末：設定「速度と精度」が 0.25 未満だと思考しない（`GenerationSettings.effectiveThinking`）。
  また、そのターンが「続行」のときは思考を飛ばす（計画は済んでいるため）。

## 4. まだ確かめていないこと

- 実機（Android）での自動更新。許可ダイアログが出るのは仕様（無通知のインストールは OS が許さない）。
- クラウドでの道具呼び出しの往復。`tool_response` はこれまでどおり **user メッセージ**として返す
  （OpenAI の `role: tool` の履歴にはしていない）。1ターン1呼び出しの範囲では動く想定だが、実機での確認はこれから。
- 小さい端末モデル（0.8B）が `update_settings` の `changes` 配列を正しく書けるか。

## 5. 版について

- v0.5.2（この版）が正しい系譜：v0.4.6 の上に「設定ツール」「クラウドへの道具渡し」「自動更新」を載せたもの。
- v0.5.0 は古い main（0.4.0 相当）から作ってしまった版なので使わない。
