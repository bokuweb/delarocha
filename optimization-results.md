# Optimization results

`optimization-candidates.md`（2026-07-11）の全候補に対する実装・評価結果。

## 採用

| 候補 | 結果 |
|---|---|
| 1-1 | `findBestPrev`でmatrix rowをhoistし、単一predecessor fast pathを追加。 |
| 1-2 | `(end, right_id)`ごとに最小costだけを保持。同cost時は更新nodeをheadへ移し既存tie-breakを維持。Zig fullの測定で約25–35%改善。 |
| 1-3 | 未知語のUTF-8境界を最大8件キャッシュ。 |
| 1-5 | capacity確保後にlenを直接設定し、appendによる二重初期化を削除。 |
| 2-2 | `invoke_bmp`をbitset、`range_bmp`をu16化。CharPropertyあたり約184 KiB削減。 |
| 3-1 | 出力sizeの事前計算、matrix・trie固定幅table/termのlittle-endian一括read/writeを実装。big-endian変換経路は維持。 |
| 4-1 | span・word id・feature pointer/lengthを1回で返す`delarocha_tokens_copy_metadata`を追加。旧exportは維持。 |
| 4-2 | 新metadata経路のstart/endをu32化。公開span APIはusizeへ拡張して互換維持。 |
| 4-3 | `ZigTokenView` / `tokenize_views`を追加。surface/featureのString確保を回避。同一測定で所有Token版6.647 µsに対し2.482 µs（約62.7%高速）。 |
| 4-4 | `tokenize_spans`でworker内の3 bufferを再利用。 |
| 5-1 | backtrace後の前進cursorでchar offsetを計算し、O(n²)からO(n)へ変更。 |
| 5-2 | `ends`と`EndLink`をsentinel u32化。`EndLink`は24Bから8B。 |
| 5-3 | Nodeのdead fieldを削除し、matrix rowをpredecessor loop外へhoist。 |
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

## 検証

- `cargo test -p delarocha --features zig-ffi`
- `DELAROCHA_BUILD_ZIG=1 cargo test -p delarocha --features zig-ffi`
- `cargo check -p delarocha --features wasm --target wasm32-unknown-unknown`
- full/count一致fuzz: 50,000 seeds、最大384文字
- 対応するmacOS/Linux/Windows/Wasmのprebuilt static libraryを再生成
- CriterionとmacOS `sample`でfull tokenizeを計測

短文fixtureの絶対時間はマシン状態により大きく振れたため、単発の絶対値ではなく同一run内比較、Criterionの統計判定、計算量・memory layoutの変化を採否判断に使用した。
