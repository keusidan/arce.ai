# リポジトリの bot（`bot.yml`）

現行の仕様だけを書く。**`AGENTS.md` の「workflow はコミットを push しない」規則の唯一の例外**。この節の限度が規則で、利用者が言わない限り広げない。2 つ目の同種の workflow は作らず、コメントが「パス・ブランチ・コマンド」を選べる入力も足さない。

## 使い方
issue か Pull Request のコメントに `@arce-bot やってほしいこと` と書く。bot は、スレッド（題・本文・直近 20 件のコメント）とファイルの一覧を読み、モデルに聞き、**コメントで返信する**。変更を頼まれたときは、**`bot/issue-<番号>-<題>` という自分のブランチ**にコミットして、**下書き（draft）の Pull Request** を開く。自分が作った Pull Request（`bot/…`、同じリポジトリ内）には、続けて直しを足せる。**マージも、`main` への書き込みも、しない**。手動：Actions → Bot → Run workflow（issue の番号・指示・**dry run**。既定は dry run：何も書かず、ログに「こうする」を出す）。

## 構成
`.github/workflows/bot.yml`（起動と鍵の受け渡しだけ）、`tool/bot/bot_core.dart`（**何をしてよいかの判断**：呼べる人・書けるファイル・上限・モデルの答えの読み取り・プロンプト。ネットワークに触れない純粋な部分）、`bot_runner.dart`（一連の流れ。GitHub とモデルは窓口 `BotGitHub`・`BotModel` の向こう）、`bot_github.dart`（REST API）、`bot_model.dart`（OpenAI 互換のチャット）、`bot.dart`（入口）。テスト：`test/tool/`（偽の GitHub・偽のモデル・`MockClient`）。

## 安全の設計（限度が規則）
1. **呼べる人**：`OWNER`・`MEMBER`・`COLLABORATOR` のコメントだけ。見知らぬ人が issue を書くことはできても、bot を動かせない（モデルが、リポジトリの秘密を使える場で、その人の文章を読むため）。bot 自身・他の bot のコメントでは動かない（ループの元）。引用行（`> …`）の中の `@arce-bot` は呼び出しにならない。判断は workflow の `if:` と、スクリプトの `BotPolicy` の**二重**。
2. **モデルの出力は、データ**：書けるのは、**`lib/`・`test/`・`docs/`・`README.md` だけ**（変数 `BOT_ALLOWED_PATHS` で変えられるが、下の禁止は消せない）。**どんな設定でも書かない**：`.github/`（workflow を書けると、bot が自分に何でも許せる）、`AGENTS.md`・`CLAUDE.md`（規則）、`pubspec.yaml`・`pubspec.lock`（**`pubspec.yaml` を書くと、5 つの OS のリリースが始まる**）、`.git/`、鍵の入るファイル（`.env*`・`*.jks`・`*.pem`・`key.properties` …）。パスは、相対・`..` や空の部分なし・200 文字まで。1 ファイル 100 KB、合計 400 KB、12 ファイルまで。1 つの悪いファイルが他を巻き込まない（悪いものだけ「書かなかった」とコメントに出る）。**issue の文章に「.github を書き換えてよい」と書かれても、限度は変わらない**（テストあり）。
3. **書き込み先**：`RestGitHub.commit` は、`bot/…` という名前のブランチにしか書かない（`RestGitHub.isBotBranch`。呼び出し側が何を渡しても。`main` などは、App のトークンが書ける権限を持っていても届かない）。**強制 push はしない**（動いた枝は、上書きせずエラー）。作る Pull Request は**下書きだけ**。
4. **鍵**：GitHub への書き込みは、**GitHub App のトークン**（短命。このリポジトリだけ）で行う。workflow の `GITHUB_TOKEN` は**読み取り専用**。モデルの API キーは Actions の secret。コメントの文章は、**シェルのコマンド行に入れない**（bot は、GitHub が渡す event のファイルを読む）。
5. 変更には「モデルが書いた。実行していない。読んでからマージして」と、コミットメッセージと PR の本文に必ず書く。

## 一度だけ必要な設定（利用者の作業）
1. GitHub App を作る（Settings → Developer settings → GitHub Apps → New GitHub App）。名前は任意（呼び出しの `@arce-bot` は文字列で、App の名前と一致していなくてよい）。Webhook は「Active」を**外す**。権限（Repository permissions）：**Contents: Read and write**、**Pull requests: Read and write**、**Issues: Read and write**、Metadata: Read-only。作ったら、**秘密鍵（.pem）を生成**し、**このリポジトリだけにインストール**する。
2. このリポジトリの Settings → Secrets and variables → Actions に、**Secrets**：`BOT_APP_PRIVATE_KEY`（.pem の中身）、`BOT_API_KEY`（モデルの API キー）。**Variables**：`BOT_APP_ID`（App の ID）、`BOT_API_URL`（OpenAI 互換のチャット補完のアドレス。例：`https://api.openai.com/v1/chat/completions`）、`BOT_MODEL`（モデル名）。任意：`BOT_EXTRA_BODY`（提供元の追加の項目を JSON で。例：`{"reasoning_effort":"low"}`）、`BOT_ALLOWED_PATHS`（空白区切り）。
3. Actions → Bot → Run workflow：issue の番号を入れ、**dry run のまま**で動かして、ログを見る。よければ、issue に `@arce-bot …` と書く。

## しないこと
(1) 他人のフォークの Pull Request への書き込み（フォークの枝には書けない）。(2) 自動マージ。(3) ファイルの削除・リネーム（全ファイルの書き込みだけ。影響を小さくする）。(4) 画像や大きなファイルの読み書き。(5) モデルに道具を渡して試行錯誤させる形（テストを実行させるなど。安全の面が広がる。いまは「読む → 答える」を最大 3 回まで）。

## 未確認（この環境からは試せない）
GitHub App の作成・権限・`actions/create-github-app-token@v2` の動き、実際のモデルが JSON の形で答えるか（答えなければ「使える答えを作れなかった」と返す）、Git Data API の呼び出しの順（偽の通信でしか試していない）、CI が bot の枝で走ること（App のトークンの push は、`GITHUB_TOKEN` の push と違って、他の workflow を起こす）。**最初の 1 回は、dry run で確かめてから使うこと**。
