# 対話セッション（`shell_session`）

現行の仕様だけを書く。Android のみ。`linux_environment` の上に載る。**未確認**は、実機で確かめていない。

## 何ができるか
`run_command` は 1 つのコマンドを実行して終わる（入力はできない）。道具 `shell_session` は、**動き続けて入力を待つプログラム**（`python3` などの REPL、質問してくるインストーラ、opencode のような CLI エージェント）を動かし、モデルが**画面を見ながら入力**できる。
- `action`：`start`（`command`・`cwd`・`secrets`）→ セッション id、`send`（`session`・`input`・`keys`）、`read`（画面を見直す。動いている最中に使う）、`stop`、`list`。
- `input` は打ったとおりに入り（改行は Enter キー）、`keys` は名前（Enter・Tab・Esc・矢印・Home・End・PageUp/Down・Backspace・Delete・Space・Ctrl-C・Ctrl-D・Ctrl-<英字>）。`wait_ms` は出力を待つ時間（設定の上限まで）。

## 仕組み
- Android 側（`ShellSessions.kt`・`LinuxEnv.startSession`）が、proot の中で **`script -qefc "…" /dev/null`**（util-linux。基本システムに入っている）を動かして**疑似端末**を与える（`TERM=xterm-256color`、`stty` で桁・行を設定）。
- 出力は**リングバッファ**に溜め、Dart 側が**バイト位置から**読む（二重に読まず、読み落とさない。バッファより多く出たときは「失われた」と伝える）。読むときは、出力が来るまで待ち、**来たあと 0.3 秒静かになるまで**待つ（出力は何回かに分かれて届くため）。
- モデルが読むのは**端末の画面を文字にしたもの**（`TerminalScreen`、`lib/core/terminal_screen.dart`）：色・カーソル移動・消去・行の挿入と削除・スクロール領域・保存と復元に対応し、色や題名などは捨てる。画面から流れた行は、次の読み取りで 1 度だけ渡す（`scrollback`）。全画面のプログラムは、その絵がそのまま画面になる。
- Dart 側の管理は `ShellSessionManager`（`lib/services/shell_sessions.dart`）。

## 安全
- **開始するコマンド**と、**入力する文**は、`run_command` と同じ規則で判断する（サンドボックスの外に触れる／`/proc` の抜け道がある／`secrets` を渡す／「検索や外部ツールの結果を読んだあと」の規則／すべて確認する設定、のどれかなら**承認カード**）。カードには、開始なら `$ コマンド`・場所・渡す秘密、入力なら `> 入力`・キー。**キーだけ**の入力（Ctrl-C・矢印）は、文が無いので聞かない。`read`・`stop`・`list` は聞かない。シェルを起動して、そこに文を打てば何でも実行できるので、**入力にも同じ判断をかけている**（文字の判定は、変数で組み立てた名前を防げない。`linux_environment`）。
- 渡した**秘密の値は、画面にも流れた行にも出さない**（開始のときだけでなく、あとの読み取りでも伏せる。環境変数の名前の分と、`{{secret:ID}}` の分の両方）。画面の末尾に、値の書きかけがあるときは、その部分も落とす（残りが次の読み取りで届き、2 つを足されないため）。session の `send` で使えるのは、その session を始めたときに渡した id だけ。
- 開始時に環境が無ければ入れる（利用者が承認した呼び出しの中で）。

## 限度（すべて設定。「Linux 環境」のカード →「対話セッション」）
同時に動かす数（既定 3）、使われないセッションを止めるまで（15 分。0 で止めない）、出力を待つ時間（1500 ミリ秒）と、モデルが指定できる上限（30 秒）、端末の幅・高さ（120×40）、流れた行を残す数（500）、読まれるまで残す出力（256 KB）。**ワークスペースが上限を超えたら、すべてのセッションを止める**（5 秒ごとに見る）。Linux 環境を削除する・ワークスペースを空にするときも、先にセッションを止める。

## 動かし続けるものを、画面に出す
`run_command` のコマンドは、返ると終わる（`--kill-on-exit`）。Web サーバーや、ブラウザで操作するビューア（HTML ビューア・Python の画面・`python3 -m http.server` など）を、画面に出し続けたいときは、`shell_session` で動かし続け、127.0.0.1 のポート（1024〜65535）で待たせて、道具 `show` に `port` を渡す（`screens`）。proot はネットワークを分けないので、proot の中のポートは、アプリから 127.0.0.1 で見える（未確認：実機）。

## しないこと
(1) tmux を使う形（セッションの外のコマンドが、`--kill-on-exit` の proot ごと消えるため、サーバーを動かし続ける別の仕組みが要り、さらに tmux を apt で入れる必要がある）。(2) 全画面のプログラムの色や太字をモデルに伝える（読む役には要らない）。(3) アプリを閉じても続くセッション（プロセスは、アプリの終了とともに終わる）。

## CLI エージェント（opencode・agy）
- **agy ＝ Antigravity CLI**。**公式の資料には届かず、以下は第三者の案内（未確認）**：入れ方は `curl -fsSL https://antigravity.google/cli/install.sh | bash`（`~/.local/bin` に入る。**Linux の arm64 版がある**。[Arm の案内](https://learn.arm.com/install-guides/antigravity/)）。**一発で終わる使い方 `agy -p '指示'`（`--print`。`--print-timeout`・`--sandbox` もある）**があり、これは `run_command` で足りる（対話の `shell_session` は、`agy` だけで TUI を開くとき）。認証は、API キーを環境変数で渡せるという記述がある（変数名は未確認。入れるなら**設定の「秘密」**に入れ、モデルが `secrets` に名前を書き、承認カードで渡す。`secrets`）。
- **注意**：Antigravity の**サーバー**（IDE 側）が「Linux ARM64（Ubuntu を proot で）」で落ちるという[報告](https://discuss.ai.google.dev/t/bug-report-antigravity-server-crashed-unexpectedly-on-linux-arm64-ubuntu-via-proot/122169)がある（CLI とは別物だが、proot では動かない可能性がある）。一方、[Termux でネイティブに動かした報告](https://discuss.ai.google.dev/t/i-got-antigravity-cli-running-natively-on-android-termux-no-vms-no-cloud-shell-no-proot-distro-just-your-phone/147333)もある（アプリの proot の外）。**この rootfs（Ubuntu 24.04 arm64、proot）で `agy` が動くかは、実機で確かめるまで分からない**。
- opencode は、公式の資料に届かず未確認。
- コーディングモードの計画をこれらに渡す手順は `coding_mode`。

## テスト
`test/core/terminal_screen_test.dart`（画面の読み取り）、`test/services/shell_sessions_test.dart`（読み取りの位置・キー・待ち時間・伏せ字・日本語の途切れ）、`test/mcp/mcp_tools_test.dart`（承認の規則・実行・失敗の返し方）、`test/core/protocol_test.dart`（モデルが書いた JSON の読み取り）、`test/core/chat_controller_test.dart`（外部の文章を読んだあとの確認）。

## 未確認（実機で確かめる）
(1) proot の中で `script` が疑似端末を作れるか（`/dev/ptmx` と `/dev/pts` は `-b /dev` の経路で見えるはずだが、端末の SELinux の設定によっては断られるかもしれない）。(2) opencode・agy を、この rootfs に入れて動かせるか、どの呼び方が正しいか。(3) 小さなモデルが「始める → 読む → 打つ」の手順を守れるか。(4) Kotlin（`ShellSessions.kt` など）の動き（CI のビルドは通るが、端末で動かしていない）。
