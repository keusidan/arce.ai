# ARCE.AI APK自動リリース（GitHub Actions）

- 作成日：2026-09-26
- 設定ファイル：`.github/workflows/release.yml`
- 関連：`app/build.gradle.kts`（署名設定・バージョン番号の受け取り）

## 1. 仕組み

```
git tag v0.1.0 && git push origin v0.1.0
  ↓ GitHub Actions（ubuntu-24.04）
submodule（llama.cpp）ごと取得 → JDK 21 → :core:test → :app:assembleRelease
  ↓
固定の鍵で署名 → apksignerで署名を確認 → SHA256を計算
  ↓
GitHub Release「v0.1.0」に次の2ファイルを添付
  - ARCE.AI-v0.1.0.apk
  - ARCE.AI-v0.1.0.apk.sha256
```

| 起動方法 | 動作 |
|---|---|
| `v*`のタグをpush | 署名付きAPKをReleaseとして公開 |
| Actionsタブ →「Release APK」→「Run workflow」 | 入力したバージョンで同じ処理（タグはその時点のcommitに自動作成） |
| 上記で「dry run」にチェック | 署名もReleaseもせず、未署名APKをArtifact（7日間保存）として残すだけ。ビルド確認用 |

- `versionName`：タグから`v`を除いたもの（例：`0.1.0`）
- `versionCode`：Actionsの実行番号。毎回増えるので、Androidのアップデート条件（前より大きい値）を満たす

## 2. 最初に1回だけ行うこと（ぽんずさんのPC）

### 2.1 リリース用の署名鍵を作る

```bash
cd ~
keytool -genkeypair -v -keystore arce-release.jks -keyalg RSA -keysize 4096 -validity 36500 -alias arce
```

- パスワードを聞かれるので、決めて入力する（以下「鍵のパスワード」）
- 名前などの質問は、空欄のままEnterでもよい
- `-validity 36500`は有効期間（日数）で、約100年
- **`arce-release.jks`と鍵のパスワードは、なくすと二度とアップデートを配れなくなる**。PCとは別の場所（USBメモリ、パスワードマネージャー等）にもバックアップを取る
- リポジトリの中には置かない（`.gitignore`で`*.jks`を除外済み）

### 2.2 GitHubのSecretsに登録する

GitHub CLI（`gh`）を使う場合：

```bash
cd ~/Documents/arce.ai
base64 -w0 ~/arce-release.jks | gh secret set ARCE_KEYSTORE_BASE64
gh secret set ARCE_KEYSTORE_PASSWORD
gh secret set ARCE_KEY_ALIAS --body arce
```

2行目は、実行するとパスワードの入力を求められるので、鍵のパスワードを入力する（コマンド履歴に残らない）。

ブラウザで登録する場合：リポジトリの「Settings → Secrets and variables → Actions → New repository secret」で、次の3つを登録する。

| 名前 | 値 |
|---|---|
| `ARCE_KEYSTORE_BASE64` | `base64 -w0 ~/arce-release.jks`の出力（1行の長い文字列） |
| `ARCE_KEYSTORE_PASSWORD` | 鍵のパスワード |
| `ARCE_KEY_ALIAS` | `arce` |

### 2.3 リリースする

```bash
git tag v0.1.0
git push origin v0.1.0
```

10〜15分ほどで、リポジトリの「Releases」にAPKが並ぶ。

## 3. 注意点

- **debug版からの切り替え**：今スマホに入っているdebug版（PCでビルドしたもの）は、別の鍵で署名されている。Releaseで配布するAPKを入れる前に、debug版を一度アンインストールする必要がある（アプリ内のモデルも消えるので、`adb push`し直す）。以降は同じ鍵なので、上書き更新できる
- **Secretsが未登録の場合**：署名なしのAPKでは入っているアプリを更新できないため、ワークフローはエラーで止まる（dry runを除く）
- **無料枠**：非公開リポジトリのActionsは、無料プランで月2,000分まで。2回目以降はGradleのキャッシュが効いて短くなる

## 4. ファイル名について

`.github/workflows/release.yml`は、GitHubが決まったフォルダの中を読むだけなので名前は自由に付けられる。ただし、ファイルを修正するたびに名前が変わると履歴が追いにくくなるため、日時は付けていない。本書のようなドキュメントには付けている。

## 5. Source

- GitHub Actionsの実行環境（Android SDK入り）：https://github.com/actions/runner-images/blob/main/images/ubuntu/Ubuntu2404-Readme.md
- Secretsの使い方：https://docs.github.com/en/actions/security-for-github-actions/security-guides/using-secrets-in-github-actions
- `gh secret set`：https://cli.github.com/manual/gh_secret_set
- `gh release create`：https://cli.github.com/manual/gh_release_create
- アプリの署名：https://developer.android.com/studio/publish/app-signing
- `keytool`：https://docs.oracle.com/en/java/javase/21/docs/specs/man/keytool.html
- apksigner：https://developer.android.com/tools/apksigner
- Actionsの無料枠：https://docs.github.com/en/billing/managing-billing-for-your-products/managing-billing-for-github-actions/about-billing-for-github-actions
