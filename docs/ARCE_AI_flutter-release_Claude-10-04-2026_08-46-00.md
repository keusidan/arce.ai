# ARCE.AI（Flutter版）全OSの自動リリースとアプリ内更新

- 作成日：2026-10-04
- 設定ファイル：`.github/workflows/release.yml`（ビルド・公開）、`.github/workflows/ci.yml`（解析・テスト）
- 関連コード：`lib/services/update_service.dart`、`lib/services/desktop_installer.dart`、`android/app/src/main/kotlin/ai/arce/app/update/ApkInstaller.kt`
- 前身：Android専用版の `ARCE_AI_release-workflow_Claude-09-26-2026_22-36-16.md`（署名鍵の作り方は同じ）

## 1. 何がリリースされるか

| OS | ファイル名 | 中身 | 作るジョブ |
|---|---|---|---|
| Android | `ARCE.AI-vX.Y.Z-android.apk` | arm64 と x86_64 を1つにした署名付きAPK | `android`（ubuntu） |
| Windows | `ARCE.AI-vX.Y.Z-windows-x64.zip` | `Release` フォルダの中身（`arce_ai.exe` が最上位）＋VC++ランタイムDLL | `windows` |
| macOS | `ARCE.AI-vX.Y.Z-macos.zip` | `ARCE.AI.app`（ad-hoc署名・公証なし） | `macos` |
| Linux | `ARCE.AI-vX.Y.Z-linux-x64.tar.gz` | `bundle` フォルダの中身（`arce_ai` が最上位） | `linux` |
| iOS | `ARCE.AI-vX.Y.Z-ios-unsigned.ipa` | 未署名のipa | `ios` |

どのファイルにも、同じ名前に `.sha256` を付けた検証ファイルが並びます（`sha256sum` の形式）。アプリ内更新はこれを使って、ダウンロードしたファイルが壊れていないか確認します。

## 2. リリースの出し方

| 方法 | 動作 |
|---|---|
| `pubspec.yaml` の `version:` を上げて、どのブランチでもpush | その版のReleaseが無ければ、自動でビルドして公開する（あれば何もしない）。`release.yml` を直してpushしたときも動くので、失敗したリリースは修正のpushだけで再試行される |
| `git tag v0.5.0 && git push origin v0.5.0` | そのタグでビルドして公開する |
| Actionsタブ →「Release」→「Run workflow」 | 入力した版（空なら `pubspec.yaml` の版）で同じ処理 |
| 上記で「dry run」にチェック | Releaseは作らず、ビルド結果をArtifact（7日間保存）に残すだけ |

- 版は `X.Y.Z` の3つの数字だけです。Windowsは版を数字として埋め込むため、`-beta` のような付け足しは使えません。
- `versionCode`（Android）とビルド番号は、Actionsの実行番号です。毎回増えるので、Androidの「前より大きい値」という更新条件を満たします。
- 先に `ci.yml` と同じ解析・テスト（`flutter analyze` と `flutter test`）が通らないと、どのOSのビルドも始まりません。

## 3. 最初に1回だけ行うこと

### 3.1 Androidの署名鍵（以前の鍵をそのまま使う）

以前のAndroid版で `ARCE_KEYSTORE_BASE64`、`ARCE_KEYSTORE_PASSWORD`、`ARCE_KEY_ALIAS` の3つのSecretsを登録済みなら、追加の作業はありません。
Flutter版も同じ `applicationId`（`ai.arce.app`）と同じ鍵で署名するため、スマホに入っているAndroid版（v0.3.x）の上に、そのまま上書きインストールできます。

まだなら、鍵の作り方とSecretsの登録は前身の文書の「2. 最初に1回だけ行うこと」と同じです。鍵を失うと、二度とAndroidの更新を配れなくなります。

### 3.2 ブランチ

自動リリースはブランチを問わず、`pubspec.yaml` か `release.yml` を変えたpushで動きます。`workflow_dispatch`（手動実行）はワークフローが既定ブランチにあるときだけActionsタブに出るため、既定ブランチに入れるまではpushかタグで動かしてください。

### 3.3 Actionsの権限

Releaseの作成には `contents: write` が要ります。ワークフローに書いてあるので設定は不要ですが、組織の設定で読み取り専用に固定されている場合は、Settings → Actions → General → Workflow permissions を確認してください。

## 4. アプリ内更新の仕組み

```
起動時（と、起動中は設定した間隔ごと）
  GET /repos/<owner>/<repo>/releases/latest   ← 非公開ならトークンを付ける
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
- GitHub Releases API（latest、アセットのダウンロードとリダイレクト）：https://docs.github.com/en/rest/releases/assets#get-a-release-asset
- Android PackageInstaller：https://developer.android.com/reference/android/content/pm/PackageInstaller
- flutter_secure_storage（macOSのKeychainと署名）：https://pub.dev/packages/flutter_secure_storage#macos
- macOSのApp Sandbox：https://developer.apple.com/documentation/security/app-sandbox
