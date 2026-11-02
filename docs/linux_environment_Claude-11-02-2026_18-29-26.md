# アプリ内の Linux 環境（proot）と `run_command`

現行の仕様だけを書く。Android のみ（ほかの OS は `run_command`・`shell_session` を出さない）。**未確認**は、実機で確かめていない。対話セッションは `shell_sessions`、秘密の渡し方は `secrets`。

## 目的
アプリ内のモデルが、端末の中で shell のコマンド（`git`、`python`、`pip`、`kaggle` など）を実行できるようにする。MCP サーバーとオンライン検索だけでは、`kaggle kernels push` のような操作ができない。ワークスペースは**全チャット共通で、上限は設定 `workspaceLimitMb`（既定 2048 MB）**。rootfs は Ubuntu（利用者の決定）。

## 確認できたこと・できていないこと

| 事項 | 状態 | 出典 |
|---|---|---|
| Android 10 以降で `targetSdk` が 29 以上のアプリは、アプリのホーム領域のファイルを `execve()` できない。「APK に埋め込んだバイナリだけを読み込む」ことが求められている | 確認済み | [Android 10 の動作変更](https://developer.android.com/about/versions/10/behavior-changes-10) |
| PRoot のライセンスは GPL-2.0-or-later。ビルドには libtalloc（と libarchive）が要る | 確認済み | [proot-me/proot](https://github.com/proot-me/proot) |
| Termux は自前の fork（`termux/proot`、版 5.1.107.101、GPL-2.0）を、libtalloc と libandroid-shmem を付けてビルドしている。loader は実行のたびに展開せず別ファイルとして置く（`PROOT_UNBUNDLE_LOADER`） | 確認済み | [termux-packages の proot/build.sh](https://raw.githubusercontent.com/termux/termux-packages/master/packages/proot/build.sh) |
| RikkaHub は proot の本体と loader を `.so` の名前で同梱し、rootfs をダウンロードして展開する。ライセンスは AGPL-3.0 | 確認（GitHub の画面の要約） | [rikkahub/rikkahub](https://github.com/rikkahub/rikkahub) |
| NDK 29 で proot（Termux の fork v5.1.107.101）を arm64 向けにビルドできる。`libproot` は約 270 KiB、loader は約 17 KiB。依存は `libc.so` と `libdl.so` だけ（libtalloc は静的に入れた）。16KB ページに揃っている | **確認済み**（`proot-build.yml` の実行） | CI の実行 |
| Ubuntu の rootfs（aarch64）：Ubuntu Base 24.04.5、29,936,675 バイト、SHA-256 `a91d5a93010193712d346d761372b7c9db6dfcf093893161c64ca107f05914f2` | **確認済み** | 実際にダウンロードして計算 |
| proot が実機（Android 12 以降、各メーカーの seccomp 設定）で動くか | **未確認** | — |

## 設計

```
モデル --(tool: run_command / shell_session)--> McpTools._runShell --> LinuxEnvironment --(MethodChannel)--> Kotlin: SystemBridge
                                                                                          └ LinuxEnv.run / startSession
                                  nativeLibraryDir/libproot.so  <--   (APK に同梱した実行ファイル)
                                  filesDir/linux/rootfs/            (ダウンロードして展開)
                                  filesDir/workspace/               (/workspace として見せる。全チャット共通)
```

- **構成**：モデル → `run_command`（`McpCall` として扱う）→ `McpTools._runShell` → `LinuxEnvironment`（`lib/services/linux_env.dart`）→ `MethodChannel('ai.arce.app/system')` の `linuxRun` → `SystemBridge` → `LinuxEnv.run`（Kotlin）。メインスレッドでは実行しない。チャットの道具と設定画面は、`McpTools.shellEnvironment`（1 つの `LinuxEnvironment`）を共有する（`AppController.linux`。`AppController.create(linux: …)` でテスト用の偽物に差し替えられる）。
- **実行ファイル**：proot 本体と loader を `libproot.so`、`libproot_loader.so` の名前で `jniLibs/arm64-v8a/` に置き、起動時は `nativeLibraryDir` から `ProcessBuilder` で実行する。環境変数 `PROOT_LOADER` で loader の場所を教える。
- **rootfs**：初回に利用者が「Linux 環境を入れる」を押したとき（または最初の `run_command` のとき）、既存の `FileDownloader`（再開・複数接続・SHA-256 検証）でダウンロードし、Kotlin 側で展開する。APK には入れない。`linuxInstall` が、ダウンロード済みの tar.gz のパス・SHA-256・DNS を受け取り、`TarGz` で `linux/rootfs.partial` に展開し、仕上げをしてから `linux/rootfs` に rename する。全部成功するまで、`linux/rootfs` には触らない。展開の上限 `maxBytes` は 0 で無制限。
- **展開**：`..` や絶対パスを含む名前は拒否する。シンボリックリンクが展開先の外を指さないか確かめる。
- **仕上げ**：`/etc/resolv.conf`（設定の DNS）、`/etc/hosts`、`/etc/hostname`、`/etc/apt/apt.conf.d/99arce`（`APT::Sandbox::User "root";`）、`/workspace`、`/tmp`。
- **実行**：`proot --kill-on-exit --link2symlink -0 -r <rootfs> -b /dev -b /proc -b <workspace>:/workspace -w <cwd> /usr/bin/env -i HOME=/workspace/home PATH=… LANG=C.UTF-8 TERM=dumb TMPDIR=/tmp SHELL=/bin/bash /bin/bash -c <command>`。シェルの `-c` の文字列は、1 つの引数として渡す（`ShellRunner`。`-c` を 2 つの引数で渡すと最初の語しか実行されない）。標準出力・標準エラー・終了コードを別々に返す（`exit`・`stdout`・`stderr`・`truncated`・`killedBy`・`elapsedMs`・`workspaceBytes`）。127 は「proot または rootfs が使えない」。
- **互換モード**：端末の seccomp で起動に失敗したとき `PROOT_NO_SECCOMP=1` で再試行する（設定 `shellCompatMode`）。
- **容量**：`DiskUsage` が 4 KiB ブロック単位で測り、コマンドの実行中 2 秒ごとに、上限を超えかつ実行前より増えていたら止める（`killedBy = workspace`）。
- **1 つずつ**：`LinuxEnv.run` は `synchronized`。複数のチャットが同時に頼むと順番待ち。
- **状態**：`LinuxEnvironment` は `ChangeNotifier`。未導入／ダウンロード中（割合）／展開中／使える／失敗。設定画面の `ListenableBuilder` がこれを見る。
- **設定**：`shellEnabled`（道具を出すか）、`shellConfirm`（承認の要否。チャットからは変えられない）、`shellTimeoutSeconds`（120）、`shellMaxTimeoutSeconds`（600）、`shellMaxOutputChars`（20000）、`workspaceLimitMb`（2048）、`linuxRootfsUrl`・`linuxRootfsSha256`（チャットからは変えられない）、`linuxDns`（`1.1.1.1 8.8.8.8`。チャットからは変えられない）、`shellCompatMode`、`shellConfirmAfterExternal`（下）。`AppController._shellSettings` が毎回読み、`McpTools` の `ShellSettings` として渡す（道具の説明にも、上限とフォルダを書く）。対話セッションの設定は `shell_sessions`。
- **設定画面**：「Linux 環境」のグループ（Android だけ）。設定の行（スイッチ・秒数・文字数・容量）、「入れる」「削除」「空にする」（確認ダイアログ）、ワークスペースの使用量（`123 MB / 2048 MB`）、`ProotCheckRow`、秘密のカード（`secrets`）、対話セッションの設定。
- **proot の入手**：`termux/proot` の特定の版（タグ）を**サブモジュール `third_party/proot` に固定**し、CI で**ソースからビルド**して `.so` として APK に入れる（libtalloc は、apt が署名を確認する Ubuntu のソースパッケージからビルドする）。出所がソースまで辿れ、GPL のソース提供がリポジトリで済む。Termux の配布 `.deb` から取り出す案は、バイナリの出所が第三者になり、方針（公式の一次情報だけを土台にする）に合わないので採らない。
- **テスト**：Dart のテストと CI は緑。Kotlin の `core` 部分（`TarGz`・`DiskUsage`・`ShellRunner`）は JVM でも検査できる。**未確認**：実機での rootfs のダウンロード・展開・`bash` の起動、`apt`・`pip`・`git`・`kaggle` の動作、`/proc` の bind、ハードリンクの作成（SELinux）、時間の上限と容量の上限、承認カードの見え方。

## 安全面
モデルが shell を実行できるので、次を設定にし、既定は厳しくする（`settings_policy`）。
- **確認カード**：既定は毎回確認する（`shellConfirm`。チャットからは変えられない）。確認カードには、モデルの説明ではなく、**実際のコマンド**を表示する（`ToolApproval.tile` が `$ command`・場所・上限の秒数を出す）。
- **作業フォルダ**：`/workspace` だけが端末のファイルに繋がる。アプリの他のデータ（設定、API キー、DB）は見せない。
- **時間・出力の上限**（`shellTimeoutSeconds`・`shellMaxTimeoutSeconds`・`shellMaxOutputChars`）。
- **ネットワーク**：rootfs の中は端末の回線で外に出られる。**止める設定は作っていない**（proot にその機能が無く、作れない）。外部の文章に誘導されたコマンドが、ワークスペースの中身を外へ送れる。確認（外部を読んだあと）が、いまの唯一の備え。
- **API キー・MCP の token は、既定では rootfs に渡さない**（ファイルにも環境変数にも入れない）。例外：利用者が設定した「秘密」（`secrets`）。
- **proot は境界ではない**：コマンドはアプリと同じ利用者（uid）で走り、proot が変えるのは**パスの読み替えだけ**。`/proc` を bind しているので、コマンドは `/proc/self/root` や `/proc/<pid>/cwd` を通って**端末の本当のファイル（アプリのデータ・履歴 DB・ダウンロードしたモデル）に届く**。`SandboxPolicy` は、コマンドの**文字**にそれらが書かれていれば「サンドボックスの外」として確認を求める（`/proc/self|thread-self|<pid>|$$|${VAR}|$(…)` の `root`・`cwd`・`exe`・`mem`・`environ`・`fd` など）が、**変数で名前を組み立てられると防げない**。API キーと MCP のトークンは、端末の安全な領域（Keystore で暗号化）にあり、rootfs には渡していないので、コマンドからは読めない。読めるのは、履歴・設定（キーを含まない）・モデルなど。Android のアプリは namespace や chroot を使えないので、これは直せない。確認とカードで守る。
- **外部の文章に書かれた命令**（検索結果・MCP の返答。誰かが「このコマンドを実行して」と書けてしまう）への備え：**検索や外部ツールの結果を一度でも読んだ会話では、サンドボックス内のコマンドも確認する**（設定「検索や外部ツールの結果を読んだあとは、コマンドを確認する」。既定オン。`shellConfirmAfterExternal`。チャットからは変えられない）。保存した会話を開き直したときも、履歴に外部の結果があれば同じ。確認カードに理由が出る。止めるのは確認までで、確認したあとの実行は制限しない。
- 設定ファイルに `approvedTools` として `run_command` などを書いても、読み込むときに外す（確認を飛ばせるのは MCP の道具だけ）。

## ライセンス
- このリポジトリには LICENSE ファイルが無い。
- proot は GPL-2.0-or-later。実行ファイルを別プロセスとして同梱する形なので、APK に入れる場合は対応するソース（版とパッチ）を提供する必要がある。proot を CI でビルドするなら、リポジトリにビルドの手順とタグを置くことで足りる。**これは私の理解であり、法的な判断ではない。公開の前に、利用者が確認すること。** 利用者の決定：非公開・個人利用のためライセンス対応は不要（GPL / AGPL の部品を同梱するときは別）。
- RikkaHub は AGPL-3.0。**コードは取り込まない**。仕組みの理解だけを使い、自前で書く。
- Ubuntu の rootfs は、配布元の条件に従う（個々のパッケージに、それぞれのライセンスがある）。
- Termux の terminal-emulator（Apache-2.0）は、対話ターミナルの候補だった（実際には、画面は自前の `TerminalScreen`。`shell_sessions`）。

## proot のビルド（`proot-build.yml`）
- 手順：NDK 29.0.13113456（sdkmanager）の clang（`aarch64-linux-android31`）で、①Ubuntu 24.04 のソースパッケージ `talloc`（2.4.2）を waf でクロスコンパイルして静的ライブラリにし、②サブモジュールの proot を、ソースフォルダのコピーの中でビルドする（`make proot loader/loader`）。結果は workflow の artifact `proot-arm64-v8a`（14 日）と、実行のアノテーションに出る。
- 結果：`libproot.so`（proot 本体）約 280 KB、`libproot_loader.so`（loader）約 17 KB（どちらも strip 後）。proot の動的な依存は `libdl.so` と `libc.so` だけ。PIE、`BIND_NOW`、LOAD の整列は 0x4000（16KB ページ対応）。loader は proot の中に埋め込まず別ファイル（`PROOT_UNBUNDLE_LOADER`）。実行時は環境変数 `PROOT_LOADER` でその場所を教える（fork のソース `src/execve/enter.c` で確認。未設定なら、ビルド時に決めた固定のパスを見に行く）。
- ビルドで必要だった回避（ソースは変えていない）：
  1. libtalloc の configure は、クロスコンパイルでは実行できない検査の答えを `cross-answers.txt` で求める。答えを入れた検査：uname、rpath、`--version-script`（FAIL）、getconf の大きなファイル、`HAVE_SECURE_MKSTEMP`、`C99 vsnprintf`、`strptime`、`HAVE_IFACE_*`、mmap 系（`HAVE_SHARED_MMAP`・`HAVE_MMAP`・`HAVE_MREMAP`・`HAVE_INCOHERENT_MMAP`）、`HAVE_FCNTL_LOCK`、`HAVE_FTRUNCATE_EXTEND`、`HAVE_BROKEN_READDIR`、`HAVE_WORKING_GETCWD`、`strtoll`。bionic（Android の libc）に当てはまる答えを、理解にもとづいて入れた（実機で talloc を動かしての確認は未）。
  2. proot の makefile は、ソースフォルダの外でビルドすると VPATH のせいでパスが二重になる。→ ソースフォルダをコピーして、その中でビルドする。
  3. `src/extension/ashmem_memfd/ashmem_memfd.c` が `<string.h>` を読まずに `strcmp` / `memset` を使う。NDK 29 の clang は暗黙の関数宣言をエラーにする。→ `-Wno-error=implicit-function-declaration`（警告に戻す。リンク時に bionic の関数に解決される）。`-include string.h` を全体に付けると、自前で `basename()` を定義する loader が壊れる。
  4. `libandroid-shmem`（System V の共有メモリ）は使わない（任意の依存。`shmget` などは proot の中では動かない可能性がある。未確認）。

## APK への同梱（`useLegacyPackaging = true`）
- 実行ファイルは、ディスク上の実ファイルからしか起動できない。そのため `android/app/build.gradle.kts` は `useLegacyPackaging = true`（`android:extractNativeLibs`）。アプリの**すべての** `.so` が、APK の中で圧縮され、インストール時に `nativeLibraryDir` へ展開される。Android 10 以降はアプリのデータ領域のファイルを実行できないため、プログラムとして起動できるのは、この取り出された場所のファイルだけ。
- **入れ方**：`release-android.yml` の `android` ジョブが、ローカルアクション `.github/actions/proot` で proot をビルドし（サブモジュールのコミットでキャッシュ）、`libproot.so` と `libproot_loader.so` を `android/app/src/main/jniLibs/arm64-v8a/` にコピーしてから `flutter build apk` を行う。`jniLibs/` は `.gitignore` に入れてあり、リポジトリには入らない（ローカルのビルドでは入らず、アプリは「proot なし」と表示する）。x64 の APK（エミュレータ向け）には入らない。
- **CI の検査**（`Check proot in the APK`）：APK の中に 2 つの `.so` があり、ビルドしたファイルとバイト単位で同じこと、`lib/` の `.so` がすべて圧縮されていること、マニフェストが `extractNativeLibs=true` であることを調べ、違えば赤にする。proot を CI で実行はしない（arm64 の bionic 向けで、runner では動かせない）。
- **コスト**（`proot-package.yml` で測定。実際のリリース 2 つを使う）：

| 項目 | `.so` を無圧縮で APK に置く方式 | 展開する方式（現行） |
|---|---|---|
| APK のサイズ（ダウンロード） | 131.4 MB | **68.0 MB**（約半分） |
| 端末内の合計（APK ＋ 展開した arm64 の `.so`） | 約 131 MB | 約 117 MB（68.0 ＋ 48.8）。x86_64 と armeabi-v7a の分は圧縮のまま APK の中にあるだけで、展開されない |
| 差分更新のパッチ（UI の変更） | 1.1 MB | 5.9 MB（圧縮された `libapp.so`（7.5 MB）の中の変更が、圧縮の流れ全体に広がるため。それでも全体の約 9%） |
| コードの変更なし | 10 KB | 3 KB |

  arm64 の `.so` の内訳：`liblitertlm_jni.so` 20.8 MB、`libflutter.so` 11.2 MB、`libapp.so` 7.5 MB、`libarce_llama.so` 6.6 MB、`libsqlite3.so` 1.7 MB、`libomp.so` 0.9 MB。proot は約 0.3 MB を足す。展開する方式にしても、ダウンロードも端末内の合計も、以前より小さい。**未確認**：端末での起動時間の変化（インストール時に展開するので、起動のたびの展開はない）、更新のインストールにかかる時間の変化。
- **実機の確認**（`ProotProbe.kt`、設定 →「Linux 環境」→「proot の確認」）：`libproot.so --version`、`libproot.so -r / /system/bin/echo ok`（rootfs なし。ptrace と seccomp が許されるかが分かる）を実行し、失敗したら `PROOT_NO_SECCOMP=1` でもう 1 回試して、終了コードと出力をそのまま画面に出す。何も変更しない。**未確認**：このボタンの結果（実機）。

## 残り
- 対話ターミナルの画面（アプリ内の端末の表示）は、`shell_sessions` の `TerminalScreen` をモデルが読む形で入っている。人間が打つ端末画面は無い。`kaggle` の導入手順（`pip install kaggle`）はモデルが `run_command` でする。
- Android 以外では動かさない。
