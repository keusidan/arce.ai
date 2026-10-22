# ARCE.AI 差分更新（0.8.9・Android）

## 1. ねらい
アプリの更新で、新しい APK の全体ではなく、**今入っているアプリとの差分だけ**をダウンロードする。

## 2. 仕組み
- **リリースの workflow**（`.github/workflows/release-android.yml` の publish ジョブ）：新しい APK を作ったあと、直近 3 つの前のリリースの APK から新しい APK への bsdiff のパッチを作り、APK と同じリリースに載せる。名前は `ARCE.AI-v<新>-android.apk.from-<旧>.patch`。パッチが APK の半分より大きければ載せない。作るのに失敗しても、リリースは止めない（`continue-on-error`）。
- **アプリ**（`lib/services/update_service.dart` の `_tryDelta`）：
  1. このリリースに、今のバージョン向けのパッチがあるか調べる。なければ全体を取る。
  2. Android にインストール済みの APK の場所を聞く（`SystemBridge.kt` の `baseApk`。分割 APK でインストールされている場合は無し）。
  3. パッチをダウンロードする（複数接続・中断からの再開は、これまでと同じ経路）。
  4. 今の APK にパッチを当てて、新しい APK を作る（`lib/services/bspatch.dart`、別の isolate）。
  5. 新しい APK の SHA-256 を、リリースの `.sha256` と比べる。**一致したときだけ**使う。一致しない、途中で失敗した、土台が違う、のどれでも、作りかけは消して、**これまでどおり全体をダウンロード**する。
- パッチの形式は bsdiff の BSDIFF40（`bsdiff` や Python の `bsdiff4` が作る標準の形式）。bzip2 の読み取りに `archive` パッケージを使う。
- 設定：「差分だけダウンロードする」（既定オン、チャットの `update_settings` の `updateUseDelta` でも変えられる）。

## 3. 確認したこと／していないこと
- 確認：実際の `bsdiff4`（Python）が作ったパッチ（239 バイト）を、Dart が 1 バイトも違わずに適用できること。土台が違うとき・壊れたパッチを拒否すること。更新サービスが、差分から新しいファイルを組み立てて全体を取らないこと、土台が違うときは全体を取り直すこと、差分が無い・土台が分からない・設定オフのときは全体を取ること（テスト）。バージョンの選び方のシェルの部分。
- **未確認**：
  - 実際の APK で、パッチがどれだけ小さくなるか。APK は zip で、変わらないファイルはそのままなので小さくなるはずだが、測っていない。ネイティブのライブラリ（`.so`）が毎回違うバイト列になると、小さくならない。
  - インストール済みの `base.apk` が、リリースの APK とバイト単位で同じか。同じでなければ SHA-256 が合わず、全体を取る。
  - 新しい workflow の手順（`pip` の `bsdiff4`、リリースの一覧と古い APK の取得）は、実際の GitHub Actions ではまだ動かしていない。
  - 実機で `baseApk` が返す場所を読めるか。
  - 大きな APK へのパッチ適用の時間とメモリ（古い APK・新しい APK・パッチを全部メモリに載せる）。
- 最初の差分つきリリースでは、古い APK が `v0.8.x` にあれば、その分のパッチが付く。パッチがない古い版からの更新は、全体をダウンロードする。
- Android だけが対象。ほかの OS の配布物（zip・tar.gz）は対象外。

## 出典
- Colin Percival, "Naive differences of executable code"（bsdiff）：https://www.daemonology.net/bsdiff/
- bsdiff4（Python）：https://github.com/ilanschnell/bsdiff4
- archive パッケージ（BZip2）：https://pub.dev/packages/archive
