# ARCE.AI（Flutter版）全OSの自動リリースとアプリ内更新

- 作成日：2026-10-04
- 設定ファイル：`.github/workflows/release-android.yml`、`release-ios.yml`、`release-windows.yml`、`release-macos.yml`、`release-linux.yml`（ビルドと公開。共通の判定は `.github/actions/prepare`）、`ci.yml`（解析・テスト）
- 関連コード：`lib/services/update_service.dart`、`lib/services/desktop_installer.dart`、`android/app/src/main/kotlin/ai/arce/app/update/ApkInstaller.kt`
- 前身：Android専用版の `ARCE_AI_release-workflow_Claude-09-26-2026_22-36-16.md`（署名鍵の作り方は同じ）

## 1. 何がリリースされるか

プラットフォームごとに、別のGitHub Release（別のタグ）です。1つのReleaseに全部を詰め込まないので、ビルドもファイルの置き場も、他のプラットフォームに邪魔されません。

| OS | Releaseのタグ | ファイル名 | 中身 | ワークフロー |
|---|---|---|---|---|
| Android | `v0.4.0` | `ARCE.AI-v0.4.0-android.apk` | arm64 と x86_64 を1つにした署名付きAPK | `release-android.yml` |
| iOS | `ios-v0.4.0` | `ARCE.AI-v0.4.0-ios-unsigned.ipa` | 未署名のipa | `release-ios.yml` |
| Windows | `windows-v0.4.0` | `ARCE.AI-v0.4.0-windows-x64.zip` | `Release` フォルダの中身（`arce_ai.exe` が最上位）＋VC++ランタイムDLL | `release-windows.yml` |
| macOS | `macos-v0.4.0` | `ARCE.AI-v0.4.0-macos.zip` | `ARCE.AI.app`（ad-hoc署名・公証なし） | `release-macos.yml` |
| Linux | `linux-v0.4.0` | `ARCE.AI-v0.4.0-linux-x64.tar.gz` | `bundle` フォルダの中身（`arce_ai` が最上位） | `release-linux.yml` |

- Androidだけ、タグが `v` で始まるだけの形です。前のKotlin版のアプリが、`releases/latest`（最後に公開された通常のRelease）の `vX.Y.Z` と `.apk` を読むためです。AndroidのReleaseだけを「Latest」にしてあり、他のReleaseは「Latest」になりません。そのおかげで、入っているv0.3.xが、そのまま更新できます。
- Flutter版のアプリは、`releases` の一覧から、自分のOSのタグ（`ios-` などの接頭辞）の中で最も新しい版を選びます。
- どのファイルにも、同じ名前に `.sha256` を付けた検証ファイルが並びます（`sha256sum` の形式）。アプリ内更新はこれを使って、ダウンロードしたファイルが壊れていないか確認します。

## 2. リリースの出し方

5つのワークフローは、別々に動きます。1つが失敗しても、他は止まりません。

| 方法 | 動作 |
|---|---|
| `pubspec.yaml` の `version:` を上げて、どのブランチでもpush | 5つが動き、それぞれ自分のReleaseにまだ無いファイルだけをビルドする。失敗した分は、修正をpushすれば、足りない分だけ作り直される |
| `git tag v0.5.0 && git push origin v0.5.0` | Androidだけが動く（iOSは `ios-v0.5.0`、他も `windows-v0.5.0` のように、OSごとのタグ） |
| Actionsタブ → 「Release Android」などから1つ選んで「Run workflow」 | 選んだワークフローだけ、入力した版（空なら `pubspec.yaml` の版）で動く |
| Androidの「Run workflow」で `reuse_run` に実行番号を入れる | ビルドせず、その実行が作ったAPKをReleaseに公開する。ビルドは成功したのに公開が失敗したときの救済（Artifactは7日間残る。版が違うAPKは拒否する） |
| 上記で「dry run」にチェック | Releaseは作らず、ビルド結果をArtifact（7日間保存）に残すだけ。他のワークフローと並行して動く |

- Androidだけは、`release-android.yml` を直してpushしたときも動きます（失敗の再試行のため）。他の4つは、`pubspec.yaml` の変更、タグ、手動実行だけです。
- 版は `X.Y.Z` の3つの数字だけです。Windowsは版を数字として埋め込むため、`-beta` のような付け足しは使えません。
- ビルド番号（Androidの `versionCode`）は `主版 × 1,000,000 + 副版 × 1,000 + 修正版` です（0.4.0 は 4000）。以前のAndroid版（v0.3.x、実行番号の14以下）より大きいので、上書き更新できます。ワークフローを分けても、番号は版だけで決まります。
- どのワークフローも、自分のビルドの前に解析とテスト（`flutter analyze` と `flutter test`）を行い、通らなければ公開しません。
- Androidは「ビルド」と「公開」が別のジョブです。公開だけが失敗したら、Actionsの実行画面で「Re-run failed jobs」を押すと、公開だけがやり直されます（25分のビルドと、そのキャッシュは無駄になりません）。
- Androidのジョブは、最初に使わないソフト（.NET、Haskellなど）を消して、ランナーのディスクの空きを確保します（llama.cppのコンパイルで容量が足りなくなったため）。

## 3. 最初に1回だけ行うこと

### 3.1 Androidの署名鍵（以前の鍵をそのまま使う）

以前のAndroid版で `ARCE_KEYSTORE_BASE64`、`ARCE_KEYSTORE_PASSWORD`、`ARCE_KEY_ALIAS` の3つのSecretsを登録済みなら、追加の作業はありません。
Flutter版も同じ `applicationId`（`ai.arce.app`）と同じ鍵で署名するため、スマホに入っているAndroid版（v0.3.x）の上に、そのまま上書きインストールできます。

まだなら、鍵の作り方とSecretsの登録は前身の文書の「2. 最初に1回だけ行うこと」と同じです。鍵を失うと、二度とAndroidの更新を配れなくなります。

### 3.2 ブランチ

ブランチは `main` だけです（既定）。自動リリースは `pubspec.yaml` の変更をpushすると動きます。ワークフローが既定ブランチにあるので、Actionsタブに「Run workflow」の手動実行のボタンも出ます。

`main` を作った直後のpushでは、リリースが動かないように、コミットの先頭に `[skip ci]` を付けます（新しいブランチのpushは、`pubspec.yaml` が変わったと扱われるおそれがあるため。未確認）。

### 3.3 Actionsの権限

Releaseの作成には `contents: write` が要ります。ワークフローに書いてあるので設定は不要ですが、組織の設定で読み取り専用に固定されている場合は、Settings → Actions → General → Workflow permissions を確認してください。ビルドのジョブは読み取りだけで、書き込みは公開のジョブだけに与えています。

**`.github/workflows/` を変えたコミットには、`GITHUB_TOKEN` でタグ（＝Release）を付けられません。**
`GITHUB_TOKEN` は `workflows` 権限を持てないためで、Releaseの作成は `403 Resource not accessible by integration`、`git push` は `refusing to allow a GitHub App to create or update workflow ... without workflows permission` で断られます。ただし、**ブランチの先頭のコミットは対象外**です（2026-10-04 に、同じ条件で切り分けて確認しました。仕様書の7.3）。

- 25分のビルドの途中で同じブランチにpushすると、ビルド中のコミットは先頭でなくなります。そのコミットがワークフローを変えていると、公開が断られます（v0.4.0 の最初の試行がこれで失敗しました）。
- 共通の公開手順（`.github/actions/publish`）は、まずビルドしたコミットにタグを付け、断られたらその時点のブランチの先頭に付け直します（Releaseの本文に「ビルドしたコミット」を書きます）。
- 自分でタグを押すとき（`git tag v0.5.0 && git push origin v0.5.0`）は、ワークフローを変えていないコミット（例：版を上げただけのコミット）に付けてください。
- ワークフローを直してpushしたあとは、ビルド中にさらにpushしないほうが確実です。

## 4. アプリ内更新の仕組み

```
起動時（と、起動中は設定した間隔ごと）
  GET /repos/<owner>/<repo>/releases           ← 非公開ならトークンを付ける。自分のOSのタグの中で最新の版を選ぶ
  → 自分の版より新しければ、画面上部に帯を出す（自動ダウンロードはしない）

ユーザーが「ダウンロードして更新」
  <OS用のファイル>.sha256 を取得 → ファイル本体をダウンロードしながらSHA-256を計算
  → 一致しなければ破棄してエラー表示

ユーザーが「今すぐインストール」
  Android : PackageInstaller でインストール（同じ署名鍵のAPKだけ受け付けられる）
  Win/mac/Linux : 展開 → 小さなスクリプトが、アプリの終了を待ってファイルを入れ替え、再起動する
  iOS : リリースページを開く（App Store外では自動インストールできない）
```

- 非公開リポジトリの場合は、設定の「GitHub トークン」に `Contents: read` 権限のトークンを入れます。トークンは端末の安全な領域（Keychain / Keystore など）に保存され、アセットのダウンロード先（GitHubの保管先）には送りません。リダイレクトを手で追って、トークンを外しています。
- Androidは初回だけ、「このアプリにアプリのインストールを許可する」設定画面が開きます。
- デスクトップは、アプリが置いてあるフォルダに書き込めることが条件です（`C:\Program Files` のような管理者権限の場所に置くと、入れ替えに失敗して元の版のまま再起動します。ユーザーのフォルダに置いてください）。

## 5. OSごとの注意

| OS | 注意 |
|---|---|
| macOS | Apple Developer IDで署名・公証していないため、初回は右クリック → 開く、または「システム設定 → プライバシーとセキュリティ」で許可が要ります。自己更新するために、App Sandboxは切ってあります（`macos/Runner/*.entitlements`）。 |
| iOS | 未署名のipaです。実機に入れるには、AltStore や Sideloadly などで自分のApple IDで署名します。TestFlight / App Store配布には Apple Developer Program（有料）が必要です。 |
| Windows | SmartScreenが「不明な発行元」と表示することがあります（コード署名証明書が無いため）。 |
| Linux | 実行には GTK 3 と libsecret（GNOME Keyring 等）が必要です。無い環境でも動きますが、GitHubトークンは保存されません。 |
| 推論 | Android以外は推論エンジンがありません。デモ応答のみです。 |

- Actionsの料金：非公開リポジトリでは、macOSランナーの分は実行時間が10倍で数えられます（無料枠の分数に対して）。出典は下記のGitHub公式文書です。

## 6. ローカルでの確認

```bash
flutter analyze && flutter test
flutter build linux --release        # このPCのOS用
```

Androidのビルドには `third_party/llama.cpp`（サブモジュール）と Android SDK / NDK 29.0.13113456 が必要です。

## 出典

- Flutterのビルドと配布（各OS）：https://docs.flutter.dev/deployment
- Flutterのビルド名・番号（`--build-name` / `--build-number`）：https://docs.flutter.dev/deployment/android#reviewing-the-gradle-build-configuration
- GitHub Actionsのランナー課金（OSごとの倍率）：https://docs.github.com/en/billing/managing-billing-for-your-products/managing-billing-for-github-actions/about-billing-for-github-actions
- GitHub Actionsの `GITHUB_TOKEN` の権限（`workflows` の項目は無い）：https://docs.github.com/en/actions/security-for-github-actions/security-guides/automatic-token-authentication （この環境から開けず、中身は未確認）
- 上の拒否の一次情報：Actionsの実行のログ（`git push` の拒否メッセージと、APIが返す `X-Accepted-Github-Permissions: contents=write; contents=write,workflows=write`）。実行 37195030866 の「Try the calls」
- キャッシュの `save-always` は非推奨（「意図どおりに動かない」）で、`cache/restore` と `cache/save` に分けるのが代わりの方法：https://github.com/actions/cache/blob/main/save/README.md （同上。非推奨の警告は、実行のログに出ていた）
- GitHub Releases API（latest、アセットのダウンロードとリダイレクト）：https://docs.github.com/en/rest/releases/assets#get-a-release-asset
- Android PackageInstaller：https://developer.android.com/reference/android/content/pm/PackageInstaller
- flutter_secure_storage（macOSのKeychainと署名）：https://pub.dev/packages/flutter_secure_storage#macos
- macOSのApp Sandbox：https://developer.apple.com/documentation/security/app-sandbox
