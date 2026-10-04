# ARCE.AI ローカル推論・端末 Agent・候補比較の実装方針

- 作成日：2026-10-04 23:30 JST
- 対象ビルド：Android / Windows x64 / Linux x64 のみ
- この文書は、Flutter 版仕様書の「Android 以外の推論」と、利用者が追加した Agent・マルチモーダル・候補比較要件を具体化する。

## 1. 対象としないもの

- iOS / macOS の新規ビルド・リリースは行わない。既存のプラットフォーム用ソースは削除しない。
- Wi-Fi 越しに1つのモデルの各層や各 token を端末へ分割する分散推論は対象にしない。遅延と通信量のため、家庭内 LAN では実用的でない。
- 未認証の TCP / HTTP listener、またはリモート shell は実装しない。

## 2. コード表示

`SyntaxHighlighter` は Android / Windows / Linux で共通の Dart 実装とする。ストリーム途中の不完全なコードも落とさず、Dart、Kotlin、Java、Python、JavaScript / TypeScript、C / C++、C#、HTML、JSON、YAML、Bash、SQL をトークン単位で表示する。構文木を作る重い parser は導入しない。

## 3. 候補比較

1. 完成した通常の返信で「候補」を押す。
2. 同じ履歴・同じ sampling 設定で追加候補を生成する。候補生成中は tool call を禁止し、検索や操作を重複実行しない。
3. 元の回答と追加候補を比較カードに表示する。
4. 利用者が1件を選ぶまで、候補は prompt history と永続化した会話履歴に入れない。
5. 選択した回答だけを assistant turn として確定する。

候補数は設定から2〜4件を選ぶ。単一端末では順次実行し、Device Agent が利用可能になった後は独立候補を並列に配分する。

## 4. マルチモーダル

モデル定義は `ModelCapability` によって text / image / video / audio を明示する。チャットの添付 UI は、**読み込み済みのモデル**が該当 capability を持つ場合だけ表示する。

画像・動画のボタンを実際に有効化するのは、各 backend がその media を前処理してモデルへ渡せるようになったときだけとする。GGUF の本体だけでは vision model を実行できないことがある（projector、画像 encoder、model 固有の prompt 形式が必要）。動画は native video model、または利用者に明示したフレーム抽出のどちらかをモデルごとに定義する。

## 5. Device Agent

`DeviceAgentPool` は次の安全境界を持つ。

- Agent は Platform、鍵 fingerprint、capability、同時実行上限を宣言する。
- pending / trusted / revoked の状態を持ち、trusted の端末だけが job を受け取る。
- 1つの候補生成・要約・検索など、相互に独立した job だけを配分する。
- code execution は別 capability とし、推論権限だけの Agent へ送らない。

次段階の transport は、QR またはワンタイムコードで鍵を確認し、相互 TLS のみで接続する。Android は前面サービスと明示的な停止操作を使い、Windows / Linux は常駐 Agent の有効・無効を利用者が管理する。モデルファイル自体は原則として各端末に保持し、ネットワーク転送しない。

## 6. Windows / Linux のローカル LLM

既存 Android JNI のパッケージ名と API は維持する。Windows / Linux には同じ llama.cpp revision からビルドする C ABI wrapper を同梱し、Dart FFI が load / generate / cancel / unload を呼ぶ。

- Linux x64: `libarce_llama.so` を Flutter bundle の `lib/` へ配置する。
- Windows x64: `arce_llama.dll` を実行ファイルと同じディレクトリへ配置する。
- C++ wrapper は Android JNI bridge と同じ、KV cache prefix reuse、GBNF、キャンセル、UTF-8 分割を提供する。
- LiteRT-LM は Android 専用のままとし、Windows / Linux は GGUF / llama.cpp を最初の対応範囲にする。

GitHub Actions のビルド対象は Android、Windows、Linux の3つだけにする。
