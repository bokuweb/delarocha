# Optimization results

`optimization-candidates.md`（2026-07-11）の全候補に対する実装・評価結果。

## 採用

| 候補 | 結果 |
|---|---|
| 1-1 | `findBestPrev`でmatrix rowをhoistし、単一predecessor fast pathを追加。 |
| 1-3 | count-only未知語のUTF-8境界を最大8件キャッシュ。full側は安定性修正で従来経路へ戻した。 |
| 2-2 | `invoke_bmp`をbitset、`range_bmp`をu16化。CharPropertyあたり約184 KiB削減。 |
| 3-1 | 出力sizeの事前計算、matrix・trie固定幅table/termのlittle-endian一括read/writeを実装。big-endian変換経路は維持。 |
| 4-1 | span・word id・feature pointer/lengthを1回で返す`delarocha_tokens_copy_metadata`を追加。旧exportは維持。 |
| 4-2 | 新metadata経路のstart/endをu32化。公開span APIはusizeへ拡張して互換維持。 |
| 4-3 | `ZigTokenView` / `tokenize_views`を追加。surface/featureのString確保を回避。同一測定で所有Token版6.647 µsに対し2.482 µs（約62.7%高速）。 |
| 4-4 | `tokenize_spans`でworker内の3 bufferを再利用。 |
| 5-1 | backtrace後の前進cursorでchar offsetを計算し、O(n²)からO(n)へ変更。 |
| 5-2 | `ends`と`EndLink`をsentinel u32化。`EndLink`は24Bから8B。 |
| 5-3 | Nodeのdead fieldを削除。matrix row hoistはcount-onlyで維持し、full側は安定性修正で従来経路へ戻した。 |
| 6-1 | Wasmが構築済みTokenizerを保持し、辞書cloneをtokenizeごとから設定変更時だけへ移動。 |
| 6-2 | Tokenizerの辞書をArc共有し、Wasmがowned workerを保持してlattice bufferを再利用。 |

## 評価して不採用

| 候補 | 理由 |
|---|---|
| 1-4 | Zig側にはuser dictionaryを設定する公開経路が現在なく、`user_entries`は常に空。到達不能な経路へのindex追加は常駐memoryだけを増やすため見送り。API追加時に同時実装する。 |
| 1-6 | 逆順append + reverseを実装して測定したところ、2.953 µsから4.378 µsへ悪化。resize後の直接書き込みを維持。 |
| 1-7 | range定義は後勝ちで重複可能。単純なstart二分探索では意味が変わる。非BMP range数は小さくprofileでもhotでないため維持。 |
| 2-1 | ignore-space時はend-linkだけが空白後へ伝播し、prev Nodeの`end`はtokenの`start`と一致しない。`start`は冗長ではないため削除不可。 |
| 2-3 | `trie_pair`はASCIIを含むbyte pairにも使われ、`trie_bmp`と同値ではない。統合は追加branchとtable設計変更を伴い、profile上の根拠がないため維持。 |
| 2-4 | 公開Tokenのusize→u32は破壊的変更。4-2でFFI転送量だけu32化し、公開API互換を維持する方が同じhot-path効果を得られる。 |
| 3-2 | Rustのproduction pathは既にmmap + borrowed load。Zig standaloneでmmap ownershipをDictionaryへ追加するとpublic lifecycle変更になる一方、現状のCLIはRust実装で利用経路がないため見送り。 |
| 3-3 | binary v3へのformat破壊を伴う。現profileではunaligned matrix loadを独立hotspotとして確認できず、既存v2互換を壊す根拠がない。 |
| 3-4 | dictionary build専用の全面的trie builder書き換え。runtime profile対象外で、比較用の実IPADIC raw datasetが環境にないため現builderを維持。 |
| 3-5 | 同じくbuild専用。fixtureのmatrixは小さくSIMD化の測定根拠がなく、architecture別実装の保守costを正当化できない。 |
| 5-4 | Pure Rust実装は互換・fixture用途で、large dictionaryのproduction pathはZig trieを使用。二重のtrie実装を保守する用途根拠がない。 |
| 1-2 | full latticeのnodeを`(end, right_id)`で統合すると一部入力でlattice stateを破壊するため撤回。 |
| 1-5 | `ArrayList.items.len`の直接更新はworker stateの安定性を損なうため撤回。 |

## 追加評価（2026-07-20）

### 採用

| 候補 | 結果 |
|---|---|
| 未知語run cache | groupしないカテゴリは必要な`length`までに走査を制限。groupするカテゴリは同一category setのrun終端・残り文字数をworkerに保持した。Zig count-onlyの2048文字未知漢字は約3.4 msから約26 µs、既知1文字候補と競合するgroup付き2048文字英字は約5.6–10.9 msから約303 µsへ改善。短文fixtureは約39–40 ns/文を維持。Pure Rustの512文字英字は927 µsから636 µs（約31%改善）。 |
| 長い未知語候補のbatch化 | `length > 8`のカテゴリでは、同じ未知語entryが生成する全長候補でpredecessor探索を1回だけ共有し、UTF-8境界を先頭からの再走査ではなく前進cursorで求める。長いpathを非inline関数へ分離して短文を従来経路に維持した。外部負荷下で旧・新binaryを交互に測定した4ペア中央値では、Zig grouped alpha 2048文字が約605 µsから119 µs（約80%改善）、短文coreが約95 ns/文から98 ns/文。Pure Rust 512文字の同条件ペアでは約1.46 msから243 µs（約83%改善）。 |
| allocation-free view | `ZigTokenViews` / `tokenize_borrowed_views`を追加。worker内metadata bufferを直接iterationし、結果`Vec<ZigTokenView>`の確保を回避。同一短文fixtureで従来view約748–785 ns/4文に対し約630 ns/4文。 |
| 安定性修正 | full lattice node統合を削除し、`ArrayList` length操作・full predecessor経路・FFI allocatorを安定版へ戻した。 |

### 評価して不採用

| 候補 | 理由 |
|---|---|
| `(begin, left_id)` predecessor cache | 8-way曖昧候補の512文字入力では約36.5 µsから25–30 µsへ改善したが、Worker肥大化とhot-path分岐により短文が約40 ns/文から58 ns/文以上へ悪化。総合回帰のため不採用。曖昧入力ベンチのみ残した。 |

## 追加評価（2026-09-26）: 辞書load

### 採用

| 候補 | 結果 |
|---|---|
| 3-2 mmap + borrowをZig標準経路へ | `Dictionary.fromBinaryFile` / `Tokenizer.initBinaryFile` / `delarocha_tokenizer_new_binary(_count_only)`はファイルをread-only mmapし、Dictionaryがmappingを所有して`deinit`でunmapする。WindowsとWasm、mmap不可のfilesystemは従来のcopy経路へfallback。copyが必要な呼び出し側向けに`fromBinaryFileCopy` / `initBinaryFileCopy`を追加。 |
| N5 Rust count-only | `count_only_from_binary_path`をRust側mmap + 新export `delarocha_tokenizer_new_binary_borrowed_bytes_count_only`へ変更。mmapは`ZigTokenizer`が所有し、native tokenizer解放後にdropされる。 |
| trie tableのzero-copy borrow | `TrieNode`をDLRDIC02の22-byte recordと同一の`extern struct`（align(1)）にし、node・edge・term・count termをmmapから直接sliceする。従来はborrow load時間の約60%がnode decodeだった。`TrieTerm` / `TrieCountTerm`は`extern`化し、#32以降の書き出し（Zig auto layout）と同じfield順を固定。record layoutは不変（新旧builderの出力はmagic以外byte一致）。ただしDLRDIC02は#32前後で2種類のterm layoutが混在し区別できないため、magicをDLRDIC03に上げてDLRDIC02は`UnsupportedDictionaryVersion`で拒否する。borrowしたstreamもload時にnode range・edge child・word id・connection idを線形検証する（IPADIC mmap loadは約3.3ms→約7ms、tokenizeは誤差範囲）。 |
| 非trie部の高速化 | 大辞書のentry loopは16-byte header内の2つの長さだけを読む。 |
| error経路修正 | truncated binaryで`CharProperty`の二重free、未初期化category/range sliceのfree、matrix costのalignment不一致free、分岐内errdeferによるtrie tableのleakが起きていたのを修正し、truncated入力のtestを追加。 |

IPADIC（89 MB）、M4、交互9回の中央値。load時間は同一process内の繰り返しload、RSSは`/usr/bin/time -l`のpeak（1文tokenize込み）。

| 経路 | 変更前 | 変更後 |
|---|---|---|
| Zig `fromBinaryFile`（`initBinaryFile` / FFI path） | 22.4 ms / 159 MiB | 4.1 ms / 47 MiB |
| Zig count（`fromBinaryFile` + discard） | 22.0 ms / 160 MiB | 4.1 ms / 47 MiB |
| Zig `fromBorrowedBinaryBytes`（呼び出し側mmap） | 10.0 ms / 108 MiB | 4.1 ms / 47 MiB |
| Zig `fromBinaryFileCopy`（従来copy） | 22.4 ms / 159 MiB | 19.9 ms / 165 MiB |
| Rust `from_binary_path` | 10.4 ms / 110 MiB | 4.1 ms / 48 MiB |
| Rust `count_only_from_binary_path` | 23.1 ms / 163 MiB | 4.1 ms / 47 MiB |

tokenize出力digestは全load経路で一致。tokenize 1回あたりのcycle数（load差分を除去）はZig full/count・doc/linesとも変更前と±2%以内。copy経路は22-byte nodeのため+6 MiB。

### 評価して不採用

| 候補 | 理由 |
|---|---|
| `MADV_WILLNEED` | load時間はやや短縮するが、ファイル全体がresidentになりpeak RSSが約89 MiBへ増加。 |
| binary v3（feature offset table分離） | 残りのload時間約4 msの大半はentry recordを走査する際のpage faultで、v3なら不要になりcount-onlyのRSSも約30 MiB減る見込み。ただしformat変更が必要なため今回は見送り。 |

## 検証

- `cargo test -p delarocha --features zig-ffi`
- `DELAROCHA_BUILD_ZIG=1 cargo test -p delarocha --features zig-ffi`
- `cargo check -p delarocha --features wasm --target wasm32-unknown-unknown`
- full/count一致fuzz: 50,000 seeds、最大384文字
- 対応するmacOS/Linux/Windows/Wasmのprebuilt static libraryを再生成
- CriterionとmacOS `sample`でfull tokenizeを計測

短文fixtureの絶対時間はマシン状態により大きく振れたため、単発の絶対値ではなく同一run内比較、Criterionの統計判定、計算量・memory layoutの変化を採否判断に使用した。
