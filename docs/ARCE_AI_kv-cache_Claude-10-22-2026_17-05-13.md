# KV キャッシュの保存形式と、データ保存形式の判断（2026-10-22 JST・v0.8.1）

## 1. 結論

- **KV キャッシュ（巨大な tensor）はファイルに置き、索引だけを SQLite に持つ。** tensor を DB の行にはしない。
- **会話履歴は SQLite のまま。** 全文検索まで含めて、いま使える代替より条件が良い（3 章）。
- 貼ってもらった方法のうち、PagedAttention・RadixAttention・LMCache・vLLM は**サーバー（多数のリクエストを GPU でさばく）向け**で、1 台のスマホで llama.cpp を JNI で埋め込んでいるこのアプリには、そのままは当てはまらない。このアプリに効くのは、次の 3 つ。

| 目的 | 貼ってもらった方法 | このアプリでは |
|---|---|---|
| prefix の再利用 | RadixAttention / `--enable-prefix-caching` | **すでにある**（`arce_llama.cpp` の `reuse_prefix`：直前のプロンプトとの最長共通 prefix を再評価しない。会話が1本なので、radix tree は要らない） |
| 容量を減らす | FP8 KV（vLLM） | **F16 / Q8_0 は以前から。Q4_0 を追加した**（llama.cpp は FP8 を持たないので、8bit の Q8_0 がその役、さらに 4bit の Q4_0） |
| 永続化 | llama.cpp の slot save/restore | **追加した**。ただし `llama-server` の HTTP API（`/slots`）ではなく、組み込み用の C API（`llama_state_seq_save_file` / `llama_state_seq_load_file`）を JNI から呼ぶ |

## 2. 追加したもの

### 2.1 KV の型に Q4_0（設定「開発者→ローカルモデル→KV キャッシュ」）
- F16 : Q8_0 : Q4_0 = 64 : 34 : 18 バイト（32 個の値あたり）。メモリは約 1 : ½ : ⅓。精度は少しずつ落ちるので、既定は F16 のまま。
- 量子化した V キャッシュには flash attention が要る（既存のコードと同じ扱い）。
- JNI の `nativeLoad` の最後の引数を `Boolean kvQ8` から `Int kvType`（0=F16, 1=Q8_0, 2=Q4_0）にした。

### 2.2 KV のファイル保存（設定「ローカルモデルの設定→KV キャッシュをファイルに保存」。**既定はオフ**）
- 保存するもの：**最後のプロンプトの分だけ**（返信の分は捨てる）。次のプロンプトは、返信を思考なしで書き直して載せるので、返信の分は再利用できないため。再利用できない分を保存しないので、ファイルが小さくなる。
- 保存先：`<アプリのデータ>/kv/<会話ID>.<指紋>.kv`。ファイルは `.tmp` に書いてから rename する（途中で落ちても、半端なファイルが本物の名前にならない）。
- 索引：既存の `assets` テーブルの 1 行（`mime = application/x-llama-kv-state`、会話、サイズ、最後に使った時刻）。スキーマは変えていない。
  - 会話を消すと、行もファイルも一緒に消える。
  - 合計の上限（既定 1024 MB）を超えたら、**最後に使った時刻が古い会話の分から**消す（LRU）。
  - 行のないファイル（rename の直後に落ちたとき）、ファイルのない行は、保存のたびに片付ける。
- **指紋**：モデルのファイル名・サイズ・文脈長・KV の型・アプリの版。1 つでも違うと、そのファイルは読まない。llama.cpp の保存形式は版で変わりうる（貼ってもらった注意と同じ）ので、アプリの版を含めた。**アプリを更新すると、保存済みは使われなくなり、LRU で消える。** llama.cpp が拒んだファイルは、その場で消す。
- 保存するとき：会話を切り替える・新しい会話を始める、アプリがバックグラウンドに回る。復元するとき：履歴から会話を開く（`resolveInterrupted` を含む）。復元の直前に、利用者がもうモデルに書き始めていたら、復元しない（新しいプロンプトの計算を捨てることになるため）。
- 保存しないとき：プロンプトが短い（既定 512 トークン未満）、再帰・ハイブリッド系のモデル（Qwen3.5 など。末尾だけを切れず、メモリ上でも prefix を再利用できないのと同じ理由）、LiteRT-LM（独自のキャッシュ）。

### 容量の目安
1 トークンあたり `2 × 層 × KVヘッド × ヘッド次元 × 要素のバイト数`（`MemoryEstimator.kvCacheBytes` と同じ式）。例：Qwen3-14B 相当（40 層・8 ヘッド・128 次元）の F16 は 160 KiB/トークンで、4096 トークンの会話が約 640 MiB。Q8_0 なら約半分、Q4_0 なら約 3 分の 1。**数百 MB になることがあるので、既定はオフ、上限は設定で変えられる。**

## 3. データ保存形式を SQLite 以外にするか

履歴に必要なのは、①トランザクション（落ちても壊れない） ②**全文検索（3 文字未満も）** ③5 つの OS で同じ動作 ④追加のネイティブ依存が少ないこと。

| 候補 | 判断 |
|---|---|
| **SQLite（いまの）** | FTS5 の trigram で日本語の部分一致ができる（3.34.0 以降）。3 文字未満は索引できないので `instr()` で補っている（実装済み）。`sqlite3` パッケージが build hook で SQLite を同梱するので、OS ごとの追加作業がない。**採用のまま** |
| Isar | 元のプロジェクトはもう積極的には開発されておらず、fork（isar_community など）に分かれている。全文検索は自作になる |
| Realm | Atlas Device SDK は 2024-09 に deprecated、2025-09-30 に終了予定（Sync 部分）。選ばない |
| ObjectBox | 検索した範囲では、組み込みの全文検索は見つからなかった（ベクトル検索はある）。全文検索を自作する必要がある |
| Hive / sembast など | 全文検索がなく、会話が増えると全件を読むことになる |
| 専用の全文検索（Tantivy など） | `flutter_tantivy` は 2025-11 に出たばかりで、5 OS での実績がまだ薄い。履歴の規模では過剰 |

→ 履歴は SQLite のままにするのが、いまの条件では最も良い。**KV のような巨大な塊はファイル、索引と検索は SQLite** という分担は、貼ってもらった「tensor 本体はファイル、prefix → パスの索引だけ SQLite」と同じ考え方。

## 4. 確認したこと／していないこと

- 確認：`flutter analyze`、`flutter test`（321 件）。保存・復元・上限・LRU・指紋・拒否されたファイル・会話の削除・片付けは、偽のエンジンでテスト（`test/services/kv_snapshots_test.dart`、`test/data/llm_db_test.dart`）。
- 確認：C++（`arce_llama.cpp`）は、**固定している llama.cpp のコミット（81bc6b8）のヘッダに対して `g++ -Wall -fsyntax-only` が警告もなく通る**。Kotlin（エンジンと橋渡しの 5 ファイル）は、Android と Flutter の API だけ stub にして、Kotlin 2.4.0 のコンパイラで通る。
- **未確認**：実機（Android）での保存・復元、実際のファイルの大きさと速度。リンクとアプリへの組み込みは CI のビルドで確認する。

## 出典
- `llama_state_seq_save_file` / `llama_state_seq_load_file`、`LLAMA_STATE_SEQ_VERSION`：llama.cpp `include/llama.h`（固定コミット）https://raw.githubusercontent.com/ggml-org/llama.cpp/81bc6b83f827df746eb129235488d325c49cae52/include/llama.h
- KV に使える型（f16 / bf16 / q8_0 / q4_0 / q4_1 / iq4_nl / q5_0 / q5_1）：同 `common/arg.cpp` https://raw.githubusercontent.com/ggml-org/llama.cpp/81bc6b83f827df746eb129235488d325c49cae52/common/arg.cpp
- PagedAttention：https://ar5iv.labs.arxiv.org/html/2309.06180 ／ SGLang（RadixAttention）：https://arxiv.org/pdf/2312.07104 ／ vLLM の量子化 KV：https://docs.vllm.ai/en/latest/features/quantization/quantized_kvcache/ ／ LMCache：https://docs.lmcache.ai/developer_guide/architecture.html
- SQLite FTS5 の trigram（3.34.0、3 文字未満は索引できない）：https://sqlite.org/forum/forumpost/76b444bebe?t=c ／ https://docs.bitfount.com/api/bitfount/cache/migrations/indexes/create_patients_search_index
- Isar の fork：https://pub.dev/packages/isar_db ／ https://pub.dev/documentation/isar_community/latest/
- Realm の deprecated と終了日：https://pub.dev/documentation/realm/latest/ ／ https://mongodb.com/docs/realm
- flutter_tantivy：https://pub.dev/documentation/flutter_tantivy/latest/
