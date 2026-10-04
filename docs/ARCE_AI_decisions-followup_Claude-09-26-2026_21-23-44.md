# ARCE.AI 追加決定事項の反映と影響

- 対象：ARCEv2レビュー（`ARCE_AI_review_spec-v2_Claude-09-26-2026_20-52-22`）への回答
- 作成日：2026-09-26
- 本書の位置づけ：決定事項を仕様に落とし込んだ内容と、決定によって生じる不都合をまとめたもの。コードはまだ書いていない。

## 0. 今回の決定事項

| # | 決定 |
|---|---|
| 1 | Termux関連は実装しない |
| 2 | JSONはGBNF方式とし、必要な周辺機能を追加する |
| 3 | 非公開・個人利用のため、ライセンス対応は不要 |
| 4 | 重要なアプリデータへのアクセスは、権限ウィンドウで事前にユーザーの承諾を得る |
| 5 | NPUのライブラリは自由に選んでよい |
| 6 | 最新のAndroidから5年前のバージョンまでをサポートする |
| 7 | Termuxを使わない代替案（1章）で進める |
| 8 | EXE生成は対象外とし、ソースコードの生成までにする |
| 9 | GitHubのアップデートを定期的に確認し、ユーザーが承認したら自動でダウンロードする（8章） |
| 10 | Google Play Storeに関する記述はすべて取り下げる（個人利用に一貫させるため） |

---

## 1. 【不都合あり】Termuxを使わない場合の影響

Termuxは、JDK・Gradle・aapt2・Pythonを端末上で動かす唯一の現実的な手段だった。これを外すと、次の機能が**今の書き方のままでは実現できない**。

| 機能 | 影響 |
|---|---|
| APK生成（21.1章） | Gradleは端末上で動かせない |
| JAR生成（21.2章） | JDKがない |
| EXE生成（21.3章） | クロスコンパイラがない |
| Python実行（23章） | Termux Pythonがない |
| Prototype 1（45章） | 検証の前提が消える |

### 代わりの方法（Termuxなしで実現する案）

Android 10以降も、**APKの中にnative library（`lib*.so`）として同梱したプログラムは実行できる**。この仕組みと、Android上でそのまま動くJavaライブラリを組み合わせれば、Termuxなしでもかなりの部分を実現できる。

| 機能 | 代替手段 | 実現性 |
|---|---|---|
| JAR生成 | ECJ(Eclipse Compiler for Java)：Java製のコンパイラで、アプリ内で動く | 高い |
| APK生成 | ECJ → D8（`.class`を`.dex`に変換、Java製） → aapt2（native、APKに同梱） → apksig（署名、Java製）を**アプリ内で順番に呼ぶ独自のビルド処理**。Gradleは使わない | 中（依存ライブラリの解決は自前で実装する必要がある） |
| Python実行 | Chaquopy（前回外したものを復活） | 高い（ただしpipのパッケージはアプリのビルド時に決まる） |
| EXE生成 | **対象外（ソースコードの生成まで）**に決定 | ― |

- 過去にはAIDEが、Gradleを使わずに端末上でAPKをビルドしていた。同じ方式である。
- **Termuxをやめたことで、targetSdkを28に固定する必要もなくなった**（6章の決定と両立する）。
- Source: https://developer.android.com/about/versions/10/behavior-changes-10#execute-permission （APK同梱のバイナリは引き続き実行可能）
- Source: https://github.com/eclipse-jdt/eclipse.jdt.core
- Source: https://developer.android.com/tools/d8
- Source: https://android.googlesource.com/platform/tools/apksig/
- Source: https://chaquo.com/chaquopy/

**→ 決定（2026-09-26）**：上の代替案（Termuxなし）で進める。EXE生成は対象外とする。

---

## 2. JSON：GBNF方式と、追加する周辺機能

GBNFで出力の「形式」は保証できる。それ以外の部分を補うため、次を仕様に加える。

| 追加機能 | 内容 | 理由 |
|---|---|---|
| ① lazy grammar | 決まった合図（例：`<tool_call>`）が出たところからだけGBNFを効かせる | Thinking・本文・Artifactを自由に書かせるため |
| ② JSON Schemaから自動生成 | Tool・質問タイルの定義をJSON Schemaで書き、llama.cppの変換機能でGBNFを作る | GBNFを手書きしないため。Schemaと文法の食い違いを防ぐ |
| ③ Agentごとの文法 | Agentが使えるToolだけを含んだ文法を、Agentごとに作る | 使えないToolをAIが呼べないようにする |
| ④ 途中切断の検出 | 生成が文字数の上限（`max_tokens`）で止まったかを判定し、止まった場合だけ再生成 | Q11.Aの決定どおり |
| ⑤ 意味のチェック | 形式が正しくても、中身を検証する（例：`options`が空でない、存在するファイル名か） | GBNFは形式しか保証しないため |
| ⑥ Schemaのバージョン管理 | Schemaにバージョン番号を付け、履歴（Room）にも記録 | 11章の再生成で、当時と同じ条件を再現するため |
| ⑦ 少しずつ表示 | tool callのJSONを、生成途中から解析して画面に反映 | ストリーミング表示と両立するため |

- Source: https://github.com/ggml-org/llama.cpp/blob/master/grammars/README.md （JSON SchemaからGBNFへの変換）
- Source: https://github.com/ggml-org/llama.cpp/blob/master/docs/function-calling.md （lazy grammar）

---

## 3. 権限ウィンドウ（重要なアプリデータへのアクセス）

### 問題点
- Androidの権限ダイアログは、カメラ・位置情報など**OSが管理する資源**のためのもの。アプリ自身のデータ（Room DB・設定・モデル）へのアクセスには、OSの権限の仕組みがない。
- そのため、権限ウィンドウは**ARCE.AIが自前で作る画面**になる。
- 同じプロセスの中で生成コードを動かすと、権限ウィンドウで「拒否」しても、コードが直接ファイルを開けてしまう。

### 実装方針：隔離プロセス＋承諾したファイルだけを渡す
1. 生成コードは、`android:isolatedProcess="true"`のServiceで動かす。
   - このプロセスは、アプリのファイル・ネットワーク・権限に一切アクセスできない。
2. 生成コードが重要データを必要とする場合、**権限ウィンドウ**を表示する。表示する内容：
   - 何のデータか
   - 読み取りだけか、書き込みもするか
   - 今回だけ許可するか、常に許可するか
3. ユーザーが承諾した場合だけ、そのファイルを`ParcelFileDescriptor`（ファイルを開いた状態の参照）として隔離プロセスに渡す。
4. 承諾の記録はRoomに保存し、設定画面から取り消せるようにする。

- この方式なら、「承諾したものしか触れない」ことをAndroidの仕組みとして保証できる。
- **要検証**：Chaquopy（Python）が隔離プロセスの中で動くか。Pythonの標準ライブラリはアプリのファイル領域に展開されるため、そのままでは読めない可能性がある。Prototypeの検証項目に加える。
- Source: https://developer.android.com/guide/topics/manifest/service-element#isolated
- Source: https://developer.android.com/reference/android/os/ParcelFileDescriptor

---

## 4. NPUライブラリの選定

- **採用案：LiteRT-LM**（Googleのオンデバイス推論ライブラリ）
  - QualcommとMediaTekのNPUに、同じAPIで対応できる。
  - `InferenceEngine`の3つ目の実装（`LiteRtLmEngine`）として追加する。
- 注意点：
  - モデル形式は`.litertlm`で、GGUFとは別。NPU用のモデル一覧は分ける（Q6.Aの決定どおり）。
  - NPU向けに変換済みのモデルは種類が限られる。Qwen3の全サイズが揃うとは限らない。
  - 実装はPhase 7（Performance）以降とし、Prototypeで対応端末と対応モデルを確認する。
- Source: https://github.com/google-ai-edge/LiteRT-LM

---

## 5. 対応するAndroidのバージョン

「最新から5年前まで」を、次のように設定する。

| 項目 | 値 | 意味 |
|---|---|---|
| `compileSdk` / `targetSdk` | 最新の安定版API | どのAPIの動作ルールに従うか |
| `minSdk` | 31（Android 12、2021年10月公開） | インストールできる最も古いバージョン |

- 「サポートする範囲」を決めるのは`minSdk`。`targetSdk`は常に最新にしておく。
- 2026年9月時点で、5年前の範囲に収まるのはAndroid 12から。
- 最新のtargetSdkにすることで生じる対応：
  - 長時間の生成に使うforeground serviceは、種類の宣言が必要（`specialUse`を使う）。
  - Android 15以降の16KBページサイズの端末に対応するため、native library（llama.cpp、aapt2等）を16KB境界に揃えてビルドする。
  - 通知の表示には、実行時の権限（`POST_NOTIFICATIONS`）の許可が必要。
- Source: https://developer.android.com/guide/topics/manifest/uses-sdk-element
- Source: https://developer.android.com/tools/releases/platforms
- Source: https://developer.android.com/develop/background-work/services/fgs/service-types
- Source: https://developer.android.com/guide/practices/page-sizes
- Source: https://developer.android.com/develop/ui/views/notifications/notification-permission

---

## 6. ライセンス

- 非公開の個人利用のため、対応は不要。
- 使用予定のライブラリ（llama.cpp＝MIT、ECJ＝EPL、D8・apksig＝Apache 2.0など）にも、個人利用を妨げる条件はない。

---

## 7. Google Play Storeに関する記述の取り下げ

ARCEv2の次の箇所から、Play Storeへの言及を削除する（v3で反映）。

| 箇所 | 現在の記述 | v3での記述 |
|---|---|---|
| 冒頭（L9） | GitHub Releases等による配布を基本とする | GitHub Releasesで配布する（個人利用） |
| 38章 | Play Storeのみを前提とした設計にはしない | 削除 |
| 39章 | Play Storeの自動更新に依存しない | 削除し、8章の更新機能に置き換える |

---

## 8. アップデート機能（GitHub Releasesからの自動取得）

### 処理の流れ

```
定期確認（バックグラウンド）
  ↓ 新しい版がある
通知「ARCE.AI vX.Y.Z があります」
  ↓ ユーザーが承認
APKを自動でダウンロード
  ↓
SHA256で改ざん・破損を確認
  ↓
Androidのインストール確認画面（1タップ）
  ↓
更新完了（モデル・履歴・設定はそのまま残る）
```

### 仕様

| 項目 | 内容 |
|---|---|
| 定期確認 | WorkManagerの`PeriodicWorkRequest`で実行。間隔は設定で選べる（例：6時間／12時間／1日。最短15分はAndroidの制限） |
| 確認先 | GitHub REST APIの「最新リリースの取得」（`GET /repos/{owner}/{repo}/releases/latest`） |
| 版の比較 | リリースのタグ（例：`v1.2.0`）と、アプリの`versionName`・`versionCode`を比べる |
| 通知の内容 | 現在の版、新しい版、更新内容（リリースノート）、ダウンロード容量 |
| ダウンロード | 承認後に自動で開始。「Wi-Fiのときだけ」を設定で選べる。途中で切れた場合は続きから再開する |
| 検証 | リリースにAPKのSHA256を載せておき、ダウンロード後に照合する。一致しなければインストールしない |
| インストール | `PackageInstaller`のSession APIを使う |
| 署名 | 更新前と同じ署名鍵でないと、Androidがインストールを拒否する。鍵をなくすと更新できなくなるので、バックアップを取る |

### 必要な準備と注意点

1. **非公開リポジトリの場合はaccess tokenが必要**
   - GitHubのリポジトリを非公開にする場合、APIの利用とAPKのダウンロードに、読み取り専用のfine-grained personal access tokenが必要。
   - tokenは初回に設定画面から入力し、Android Keystoreで暗号化して保存する。
   - tokenなしのAPIは1時間に60回までの制限があるが、数時間おきの確認なら問題ない。
2. **「提供元不明のアプリ」の許可**
   - 初回だけ、Androidの設定で「ARCE.AIからのアプリのインストール」を許可する必要がある（`REQUEST_INSTALL_PACKAGES`権限）。
3. **インストール確認画面**
   - 通常、Androidは更新のたびに確認画面を1回表示する。
   - Android 12以降は、ARCE.AI自身が前回のインストールを行っていれば、この確認画面を省略できる（`setRequireUserAction`）。ただし、アプリ内での「承認」は必ず残す（決定9のとおり）。
4. **データは消えない**
   - 同じ署名鍵で更新すれば、モデル・Room DB・設定はそのまま引き継がれる（「モデルを再ダウンロードしない」方針と一致する）。

- Source: https://developer.android.com/develop/background-work/background-tasks/persistent/getting-started/define-work#schedule_periodic_work
- Source: https://docs.github.com/en/rest/releases/releases#get-the-latest-release
- Source: https://docs.github.com/en/rest/using-the-rest-api/rate-limits-for-the-rest-api
- Source: https://docs.github.com/en/authentication/keeping-your-account-and-data-secure/managing-your-personal-access-tokens
- Source: https://developer.android.com/reference/android/content/pm/PackageInstaller
- Source: https://developer.android.com/reference/android/content/pm/PackageInstaller.SessionParams#setRequireUserAction(int)
- Source: https://developer.android.com/privacy-and-security/keystore
- Source: https://developer.android.com/studio/publish/app-signing

---

## 9. 決めてほしいこと

1. ~~Termuxを使わない代替案（1章）で進めてよいか~~ → 決定済み（代替案で進める）
2. ~~EXE生成の扱い~~ → 決定済み（対象外）
3. GitHubのリポジトリを公開にするか、非公開にするか（8章：非公開ならaccess tokenが必要）
4. 以上を反映した企画書v3を作るか、それともコード（Phase 0の試作）に進むか
