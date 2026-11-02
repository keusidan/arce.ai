# リリースと CI

現行の仕様だけを書く。**未確認**は、まだ確かめていない。

## タグと Release（プラットフォームごとに別）

| OS | タグ | ファイル |
|---|---|---|
| Android | `vX.Y.Z` | `ARCE.AI-vX.Y.Z-android.apk`（arm64 と x86_64 を 1 つにした署名付き）＋ `.sha256` ＋ 差分パッチ |
| iOS | `ios-vX.Y.Z` | `ARCE.AI-vX.Y.Z-ios-unsigned.ipa`（未署名） |
| Windows | `windows-vX.Y.Z` | `ARCE.AI-vX.Y.Z-windows-x64.zip`（`Release` フォルダの中身＋ VC++ ランタイム DLL） |
| macOS | `macos-vX.Y.Z` | `ARCE.AI-vX.Y.Z-macos.zip`（`ARCE.AI.app`。ad-hoc 署名・公証なし） |
| Linux | `linux-vX.Y.Z` | `ARCE.AI-vX.Y.Z-linux-x64.tar.gz` |

- **Android のタグだけ接頭辞なしで、「Latest」にする**：前の Kotlin 版のアプリが `releases/latest` の `vX.Y.Z` と `.apk` を読むため。他の OS は `--latest=false`。Flutter 版のアプリは、`releases` の一覧から自分の OS の接頭辞のタグの中で最も新しい版を選ぶ。
- どのファイルにも `sha256sum` 形式の `.sha256`。
- 版は `X.Y.Z` のみ（Windows が版を数字として埋め込むため `-beta` は使えない）。
- **Android の `versionCode` ＝ 主版 × 1,000,000 ＋ 副版 × 1,000 ＋ 修正版**（1.0.0 は 1000000）。ワークフローの実行番号は使わない（分けたときに 1 から始まり、以前の APK より小さくなって、Android が更新を拒否する）。
- **すべての版を、5 つの OS で確かめる**：版を上げて push したら、Android・iOS・Windows・macOS・Linux の結果をすべて読む。赤い OS は、次のパッチ版で先に直す（赤のままだと、その OS の利用者は更新できない）。テストは `/` をパス区切りと決めつけない。リストして得たパスが、入力したパスと同じ文字列になるとも決めつけない（Windows のパス）。

## ブランチ
- **`main`**：リリースされた版。5 つの OS で緑になった版だけを、`dev` から fast-forward で進める（`git push origin <sha>:main`、強制しない）。`main` へ送るのは、`dev` のリリースがすべて終わってから（版が上がる push が `main` にあると、同じ版のリリースがもう一度始まる）。
- **`dev`**：作業用。通常の作業はここに push する。
- **`archive`**：1.0.0 より前の履歴のすべて。触らない（push しない）。`overview` の「履歴」参照。
- `main` と `dev` は、1.0.0 の内容から**履歴なしで**始めた（1.0.1 で、`main` を強制 push で一度だけ置き換えた。利用者の許可。強制しない規則は変わらない）。

## ワークフロー
- `ci.yml`：push と PR で `flutter analyze` と `flutter test`。
- `release-android.yml` / `-ios.yml` / `-windows.yml` / `-macos.yml` / `-linux.yml`：それぞれ、判定（`.github/actions/prepare`）→ 解析とテスト → ビルド → 公開（`.github/actions/publish`：その OS の Release にアップロード。Release が無ければ作る）。5 つは**同時並行**で別々に動く。OS 間に `needs:` や `workflow_run` を置かない。同時実行のグループも共有しない。**1 つの OS が失敗しても、再実行されても、編集されても、ほかの OS を止めない**。1 つの OS の workflow やネイティブのコードの変更を、ほかの OS の前提にしない。
- `proot-build.yml`（リリースではない。proot をビルドして artifact に残すだけ。`linux_environment`）、`proot-package.yml`（手動。APK の中の `.so` の大きさを測る）、`bot.yml`（`github_bot`）。
- 外部から patch やコードを取ってきて当てる workflow、コミットを push する workflow は作らない（過去に `apply-version.yml` がそれをして毎回失敗したので削除した。`bot.yml` だけが、限度つきの例外。`github_bot`）。ビルドの入力は、サブモジュールとして固定したもの（llama.cpp・proot）か、パッケージマネージャが署名を確かめるもの（NDK・apt）に限る。
- **同じ OS の run は順番に動き、待てるのは 1 つだけ**（`release-<os>-publish` の `concurrency`、`cancel-in-progress: false`）：ビルドが動いている間に、同じ OS の run が 2 つ以上来ると、**真ん中の run は `cancelled`** になる（失敗ではなく、より新しい run に席を譲ったという扱い。その版のその OS のリリースが無くなる）。Linux のビルドは約 25 分、Android などは約 7 分。**だから**：(1) 版を続けて push するときは、Linux のビルドが終わってから。(2) `main` に送るのは、`dev` の release がすべて終わってから（`main` への fast-forward も、同じ版の release の run を作り、待ち行列の席を取る。作った版が既にリリース済みなら、準備の段階で何もせず終わる）。(3) 席を失った版は、Actions の「Release <OS>」を手動で起動（`workflow_dispatch`、版を入力）して作れる。
- **Android は 5 つのジョブ**：`prepare`（4 秒）→ **`test`（解析とテスト、約 73 秒）と `android`（ビルド、約 5 分）が並行** → `publish`（15 秒。`test` が成功、または `reuse_run` で省略したときだけ）→ `patches`（別ジョブ。差分パッチを、前の 3 つの版ごとに並行して作り、リリースに足す。約 68 秒。失敗しても全体は赤にならない。`continue-on-error`）。他の 4 つは、ビルドのジョブの最後のステップで公開する。
  - 公開だけが失敗したら「Re-run failed jobs」で公開だけをやり直せる。`reuse_run` に実行番号を入れた手動実行は、ビルドを省いて、その実行の APK（Artifact `android`、7 日間）を公開する（版が違う APK は拒否する）。
  - Android のジョブは、最初に使わないソフト（.NET、Haskell など）を消して、ディスクを空ける（llama.cpp のコンパイルで容量が足りなくなるため）。ccache は `cache/restore` と `cache/save`（`if: !cancelled()`）に分けて、ビルドが失敗しても保存する（`save-always` は非推奨で動かなかった）。NDK のキャッシュ、Gradle のキャッシュ、Flutter / pub のキャッシュも使う。他の OS は Flutter SDK と pub のキャッシュだけ。
  - APK のあと、`Check proot in the APK`：2 つの `.so` がビルドしたファイルとバイト単位で同じこと、`lib/` の `.so` がすべて圧縮されていること、マニフェストが `extractNativeLibs=true` であることを調べ、違えば赤にする（`linux_environment`）。
- きっかけ：`pubspec.yaml` の変更を push（どのブランチでも）、OS ごとのタグ、手動実行（dry run あり）。Android は `release-android.yml` と `prepare` / `publish` の変更でも動く（失敗後の再試行）。判定：その OS の Release に、その OS のファイルが既にあれば、push では何もしない。
- 各ワークフローは、自分のビルドの前に解析とテストを行い、通らなければ公開しない。
- 待ち合わせに固定の `sleep` を使わず、GitHub の応答で状態を確認する。

| 方法 | 動作 |
|---|---|
| `pubspec.yaml` の `version:` を上げて push | 5 つが動き、自分の Release にまだ無いファイルだけをビルドする。失敗した分は、修正を push すれば足りない分だけ作り直される |
| `git tag v1.0.0 && git push origin v1.0.0` | Android だけが動く（iOS は `ios-v1.0.0` など、OS ごとのタグ） |
| Actions タブ →「Release Android」などで「Run workflow」 | 選んだワークフローだけ、入力した版（空なら `pubspec.yaml` の版）で動く |
| Android の「Run workflow」で `reuse_run` を入力 | ビルドせず、その実行の APK を公開 |
| 「dry run」にチェック | Release は作らず、ビルド結果を Artifact（7 日間）に残すだけ |

## 最初に 1 回だけ行うこと
- **Android の署名鍵**：Secrets `ARCE_KEYSTORE_BASE64`・`ARCE_KEYSTORE_PASSWORD`・`ARCE_KEY_ALIAS`（登録済み。Kotlin 版と同じ鍵）。Flutter 版も同じ `applicationId` と鍵で署名するので、端末の Android 版に上書きインストールできる。Secrets が無いと、署名なしの APK では更新できないので、workflow はエラーで止まる（dry run を除く）。**署名鍵（`*.jks`）はリポジトリに入れない**（`.gitignore` 済み）。
  - 鍵の作り方：`keytool -genkeypair -v -keystore arce-release.jks -keyalg RSA -keysize 4096 -validity 36500 -alias arce`。**`arce-release.jks` と鍵のパスワードは、なくすと二度と更新を配れなくなる**。PC とは別の場所にもバックアップを取る。
  - Secrets への登録：`base64 -w0 ~/arce-release.jks | gh secret set ARCE_KEYSTORE_BASE64`、`gh secret set ARCE_KEYSTORE_PASSWORD`（入力を求められる）、`gh secret set ARCE_KEY_ALIAS --body arce`。ブラウザなら Settings → Secrets and variables → Actions → New repository secret。
  - debug 版からの切り替え：debug 鍵で署名された版は、release の APK で上書きできない。一度アンインストールする（アプリ内のモデルも消える）。
- **Actions の権限**：Release の作成には `contents: write` が要る（workflow に書いてある。組織の設定で読み取り専用に固定されていたら Settings → Actions → General → Workflow permissions を確認）。ビルドのジョブは読み取りだけで、書き込みは公開のジョブだけ。
- 無料枠：非公開リポジトリの Actions は、無料プランで月 2,000 分。macOS のランナーは実行時間が 10 倍で数えられる。

## `.github/workflows/` を変えたコミットにはタグを付けられない
`GITHUB_TOKEN` は `workflows` 権限を持てないので、`.github/workflows/` のファイルを追加・変更したコミットには、タグ（＝Release）を付けられない（API は `403 Resource not accessible by integration`、`git push` は `refusing to allow a GitHub App to create or update workflow ... without workflows permission`）。ただし**ブランチの先頭のコミットは対象外**（使い捨ての検証用ワークフローで切り分けて確認した）：

| 条件 | 結果 |
|---|---|
| 先頭のコミットを指定（push 起動でも手動起動でも） | 成功 |
| ワークフローを変えた古いコミットを指定（`gh release create`、API、`git/refs`、`git push`） | すべて失敗 |
| ワークフローを変えていない古いコミットを指定 | 成功 |
| `--target` にブランチ名（＝先頭）を指定 | 成功 |

- 25 分のビルドの途中で同じブランチに push すると、ビルド中のコミットは先頭でなくなる。そのコミットが workflow を変えていると、公開が断られる。
- 直し方（`.github/actions/publish`）：まずビルドしたコミットにタグを付け、断られたらその時点のブランチの先頭に付け直す（Release の本文に「ビルドしたコミット」を書く）。
- 自分でタグを押すときは、workflow を変えていないコミット（例：版を上げただけのコミット）に付ける。**workflow を変えるコミットと、版を上げるコミットは分ける**。workflow を直して push したあとは、ビルド中にさらに push しないほうが確実。
- **未確認**：人が先に押したタグ（`git push origin vX.Y.Z`）に対する公開。

## OS ごとの注意

| OS | 注意 |
|---|---|
| macOS | Apple Developer ID で署名・公証していないため、初回は右クリック → 開く、または「システム設定 → プライバシーとセキュリティ」で許可が要る。自己更新のため App Sandbox は切ってある。 |
| iOS | 未署名の ipa。実機に入れるには、AltStore や Sideloadly などで自分の Apple ID で署名する。TestFlight / App Store 配布には Apple Developer Program（有料）が要る。 |
| Windows | SmartScreen が「不明な発行元」と表示することがある（コード署名証明書が無いため）。 |
| Linux | 実行には GTK 3 と libsecret（GNOME Keyring など）が要る。無い環境でも動くが、GitHub トークンは保存されない。 |
| 推論 | Android 以外は推論エンジンが無い（デモ応答のみ）。 |
| ランナー（macOS・iOS） | `release-macos.yml`・`release-ios.yml` は **`macos-15`**（GitHub の `macos-14` のイメージは 2026-11-02 に廃止された。予告の停止テスト「brownout」の間は、ジョブが開始 1 秒で取り消された。[runner-images の案内 13518](https://github.com/actions/runner-images/issues/13518)）。次にイメージが変わるときは、この表と、2 つの `runs-on` を見直す。 |

## ローカルでの確認

```bash
flutter pub get
flutter analyze && flutter test      # CI も両方走らせる。クリーンに保つ
flutter build linux --release        # このPCのOS用（Linux のパッケージは README.md）
```

- Android のビルドには `third_party/llama.cpp`（サブモジュール）と Android SDK / NDK 29.0.13113456 が必要。
- `flutter pub get` を走らせると `pubspec.lock` が変わることがある。意図しない変更はコミットしない（`git checkout -- pubspec.lock`）。
- Linux でビルド・画面確認するには `apt install clang cmake ninja-build pkg-config libgtk-3-dev libsecret-1-dev libjsoncpp-dev xvfb xdotool imagemagick fonts-noto-cjk`。画面は `xvfb-run` で起動し、`xdotool` で操作して `import -window root` で撮れる。
