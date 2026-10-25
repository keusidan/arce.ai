# ARCE.AI — アプリ内の Linux 環境（proot）の設計

状態: 設計のみ。コードは 1 行も入っていない（2026-10-26 時点で `lib/` と `android/` に proot・rootfs の記述は無い）。
設計案 P7「エージェント環境」（`ARCE_AI_design-draft_Claude-10-20-2026_19-19-07.md`）の続き。

## 1. 目的

アプリ内のモデルが、端末の中で shell のコマンド（`git`、`python`、`pip`、`kaggle` など）を実行できるようにする。
いまは MCP サーバーとオンライン検索しか外に出る手段が無く、`kaggle kernels push` のような操作ができない。

## 2. 確認できたこと・できていないこと

| 事項 | 状態 | 出典 |
|---|---|---|
| Android 10 以降で `targetSdk` が 29 以上のアプリは、アプリのホーム領域のファイルを `execve()` できない。「APK に埋め込んだバイナリだけを読み込む」ことが求められている | 確認済み | [Android 10 の動作変更](https://developer.android.com/about/versions/10/behavior-changes-10) |
| PRoot のライセンスは GPL-2.0-or-later。ビルドには libtalloc（と libarchive）が要る | 確認済み | [proot-me/proot](https://github.com/proot-me/proot) |
| Termux は自前の fork（`termux/proot`、版 5.1.107.101、GPL-2.0）を、libtalloc と libandroid-shmem を付けてビルドしている。loader は実行のたびに展開せず、別ファイルとして置く（`PROOT_UNBUNDLE_LOADER`） | 確認済み | [termux-packages の proot/build.sh](https://raw.githubusercontent.com/termux/termux-packages/master/packages/proot/build.sh) |
| RikkaHub は proot の本体と loader を `.so` の名前で同梱し、rootfs をダウンロードして展開する。ライセンスは AGPL-3.0 | 前の調査で確認（GitHub 画面の要約を読んだもの） | [rikkahub/rikkahub](https://github.com/rikkahub/rikkahub) |
| Alpine の minirootfs（aarch64）の URL・版・SHA-256 | **未確認**。この環境から alpinelinux.org に届かない | — |
| proot が実機（Android 12 以降、各メーカーの seccomp 設定）で動くか | **未確認**。実機でしか分からない | — |
| `extractNativeLibs` を有効にした場合の APK サイズと、既存の llama.cpp の `.so` への影響 | **未確認**。ビルドして測る | — |

## 3. 設計

### 3.1 構成

```
モデル --(tool: run_command)--> ShellTool --(MethodChannel)--> Kotlin: ProotRunner
                                                                   |
                                  nativeLibraryDir/libproot.so  <--+   (APK に同梱した実行ファイル)
                                  filesDir/workspace/rootfs/        (ダウンロードして展開)
                                  filesDir/workspace/home/          (/workspace として見せる)
```

- **実行ファイル**: proot 本体と loader を `libproot.so`、`libproot_loader.so` の名前で `jniLibs/arm64-v8a/` に置く。起動時は `nativeLibraryDir` から `ProcessBuilder` で実行する。
- **rootfs**: 初回に利用者が「Linux 環境を入れる」を押したとき、既存の `FileDownloader`（再開・複数接続・SHA-256 検証）でダウンロードし、Kotlin 側で展開する。APK には入れない（サイズのため）。
- **展開**: `..` や絶対パスを含む名前は拒否する。シンボリックリンクは展開先の外を指さないか確かめる。
- **仕上げ**: `/etc/resolv.conf`（公開 DNS）、`/etc/hosts`、`/etc/hostname`、ロケールを書き込む。
- **実行**: `proot --kill-on-exit --link2symlink -r <rootfs> -w <cwd> -b <home>:/workspace` の中で、`env -i` で環境を空にしてからシェルを起動する。標準出力、標準エラー、終了コードを別々に返す。127 は「proot または rootfs が使えない」。
- **互換モード**: 端末の seccomp で起動に失敗したとき `PROOT_NO_SECCOMP=1` で再試行する（設定で切り替え可）。

### 3.2 proot の入手（決める点）

| 案 | 内容 | 長所 | 短所 |
|---|---|---|---|
| ① | CI で `termux/proot` の特定の版（タグ）をソースからビルドし、`.so` として APK に入れる | 出所がソースまで辿れる。GPL のソース提供がリポジトリで済む | libtalloc も要る。NDK でのビルド手順を作る必要がある |
| ② | Termux の配布 `.deb` から取り出して同梱する | 手早い | バイナリの出所が第三者。AGENTS.md の方針（公式の一次情報だけを土台にする）に合わない |

**既定: ①**。②は採らない。

### 3.3 パッケージングへの影響（要測定）

`android/app/build.gradle.kts` は `useLegacyPackaging = false`（`.so` を無圧縮で APK に置き、APK から直接読み込む）。この設定だと `nativeLibraryDir` に実ファイルが展開されず、`execve()` できない。
実行ファイルを使うには `extractNativeLibs`（`useLegacyPackaging = true`）が要るが、llama.cpp の `.so` も展開され、端末内の容量が増える。
別の道として、proot を `.so` ではなく asset に入れて起動時にコピーする方法は、上の W^X の制限で `execve()` できないため使えない。
→ ビルドして APK サイズとインストールサイズを測ってから決める。

### 3.4 安全面

モデルが shell を実行できるようになるため、次を設定にし、既定は厳しくする（AGENTS.md「秘密以外は設定」）。

- 確認カード: 既定は毎回確認する。`ToolApproval` の単語判定は、`run_command` には当てはまらない（任意のコマンドなので）。
- 作業フォルダ: `/workspace` だけが端末のファイルに繋がる。アプリの他のデータ（設定、API キー、DB）は見せない。
- 時間の上限と出力の上限（設定項目）。
- ネットワーク: rootfs の中は端末の回線で外に出られる。通信を止める設定を用意する（既定は許可。`kaggle` などに必要）。
- API キー・MCP の token は rootfs に渡さない。Kaggle の token は、利用者が `run_command` の確認カードを見て、環境変数として明示して渡す。
- 外部の文章（検索結果、MCP の返答）に書かれた命令では実行しない。確認カードの内容は、モデルの出力ではなく実際のコマンドを表示する。

### 3.5 ライセンス

- このリポジトリには LICENSE ファイルが無い。
- proot は GPL-2.0-or-later。実行ファイルを別プロセスとして同梱する形なので、APK に入れる場合は対応するソース（版とパッチ）を提供する必要がある。①なら、リポジトリにビルドの手順とタグを置くことで足りる。**弁護士の判断ではなく、私の理解である**。公開の前に、利用者が確認すること。
- RikkaHub は AGPL-3.0。**コードは取り込まない**。仕組みの理解だけを使い、自前で書く。
- Termux の terminal-emulator（Apache-2.0）は、対話ターミナル（後の段階）で使う候補。

## 4. 段階

| 段階 | 内容 | 検証 |
|---|---|---|
| 1 | CI で proot（①）をビルドして、`useLegacyPackaging` の影響を測る。起動だけを確かめる（`proot --version`） | CI のログ。実機での起動は利用者の確認が要る |
| 2 | rootfs のダウンロード・展開・仕上げ（Kotlin）と、設定画面の「Linux 環境」 | 展開のテストは単体で。実機での起動は利用者の確認が要る |
| 3 | `run_command` ツール（確認カード、時間・出力の上限、設定項目、`AgentSettings` との対応） | Dart の単体テスト |
| 4 | 対話ターミナル、`kaggle` の導入手順（`pip install kaggle`） | 実機 |

各段階は、1 つのバージョンとして出す。Android 以外は影響を受けない（他の OS は `run_command` を出さない）。

## 5. この設計で決めたこと・利用者に確認したいこと

決めたこと（変えたければ言ってほしい）:
- proot は CI でソースからビルドする（①）。
- rootfs は APK に入れず、初回にダウンロードする。
- 確認カードは既定で毎回出す。

確認したいこと:
1. rootfs の配布元。Alpine の minirootfs（小さい）か、Ubuntu / Debian の rootfs（`pip` や `apt` が使いやすい）か。既定は Alpine だが、`kaggle` と Python を使うなら Debian 系のほうが楽な可能性がある（未確認）。
2. 段階 1 の結果、APK のインストールサイズが大きく増える場合に、それを許すか。
