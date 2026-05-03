# Vibrato Zig 移植設計メモ

## 目的

Vibrato を Zig に移植する目的は、単なる言語置き換えではなく、形態素解析のホットパスに対して以下を実現することである。

* ラティス構築・探索時のメモリアクセス局所性を改善する
* 文単位の一時メモリを arena / bump allocator で管理し、細かい allocation を排除する
* `Node` 表現を小さくし、探索時に必要なデータだけを連続配置する
* 連接コスト表へのランダムアクセスを減らす、または局所化する
* 辞書フォーマットを実行時に扱いやすい layout に固定し、分岐と変換コストを減らす

この移植では、Zig そのものによる高速化ではなく、Zig で低レベルなメモリレイアウトを明示的に制御しやすいことを利用して、データ構造と実行時メモリ管理を再設計する。

## 非目的

以下は初期スコープに含めない。

* Vibrato の全API互換を最初から目指すこと
* 辞書ビルドツールチェーンの完全移植
* すべての辞書フォーマット・学習機能の即時対応
* Rust版の設計をそのままZigに翻訳すること
* allocator差分だけで大幅高速化を期待すること

初期段階では、解析器本体のホットパスに集中する。

## 基本方針

1. まず Rust版 Vibrato の挙動と出力互換性を保つ最小実装を作る
2. 次にラティス・Node・連接コスト表のメモリレイアウトを変更する
3. ベンチマークで各変更の効果を個別に測定する
4. 効果が確認できた構造のみ本実装に残す

特に、以下の順序で進める。

1. 読み取り専用辞書ロード
2. Tokenizer / Worker 相当の実装
3. ラティス flat arena 化
4. Node の圧縮または SoA 化
5. 連接コスト表の locality 改善
6. FFI / CLI / API 整備

## アーキテクチャ概要

```text
+----------------+
| Dictionary     |
| - lexicon      |
| - trie         |
| - matrix       |
| - unk handler  |
+-------+--------+
        |
        v
+----------------+
| Tokenizer      |
| - shared dict  |
+-------+--------+
        |
        v
+----------------+
| Worker         |
| - sentence buf |
| - lattice      |
| - arena        |
| - result buf   |
+-------+--------+
        |
        v
+----------------+
| Tokens         |
+----------------+
```

`Tokenizer` は読み取り専用の `Dictionary` を共有し、実際の一時メモリは `Worker` に閉じ込める。複数スレッドで使う場合は、スレッドごとに `Worker` を持つ。

## メモリ管理方針

### 辞書領域

辞書は基本的に immutable とする。

* 起動時または初期化時にロード
* 解析中は読み取りのみ
* 複数 `Worker` 間で共有可能
* allocator は通常の general purpose allocator でもよい
* 可能なら memory-mapped file も検討する

### 文単位の一時領域

文ごとに初期化されるデータは `Worker` 内の arena / bump allocator で管理する。

対象:

* 入力文の codepoint buffer
* byte offset / char offset mapping
* ラティスノード
* end-position index
* unknown word 候補
* 出力 token の一時構造

方針:

* `Worker.reset(sentence_len)` で arena を巻き戻す
* 文ごとの小さな allocation をしない
* capacity は過去最大文長に応じて再利用する
* 長すぎる文で膨らんだ arena は shrink policy を設ける

例:

```zig
const Worker = struct {
    dict: *const Dictionary,
    arena: std.heap.ArenaAllocator,
    sentence: SentenceBuffer,
    lattice: Lattice,
    result: TokenBuffer,

    pub fn reset(self: *Worker) void {
        _ = self.arena.reset(.retain_capacity);
        self.sentence.reset();
        self.lattice.reset();
        self.result.reset();
    }
};
```

## ラティス設計

### Rust版に近い構造の問題意識

Rust版では概念的に、各文字位置ごとに終端ノードの配列を持つ。

```text
ends[pos] -> Vec<Node>
```

これは理解しやすく、capacity再利用も可能だが、以下の弱点がある。

* positionごとに小さな可変配列がある
* `Vec<Vec<Node>>` 的なメタデータが増える
* ノード群が分散しやすい
* 探索時に cache line を無駄にしやすい

### Zig版の初期案: flat buffer + range index

Zig版では、ラティスノードを1本の連続配列に置き、各終端位置は範囲で参照する。

```text
nodes:       [Node, Node, Node, Node, ...]
end_ranges: [Range, Range, Range, ...]

end_ranges[pos] = { start, len }
```

```zig
const Range = struct {
    start: u32,
    len: u32,
};

const Lattice = struct {
    nodes: std.ArrayListUnmanaged(Node),
    end_ranges: std.ArrayListUnmanaged(Range),

    pub fn nodesEndingAt(self: *const Lattice, pos: usize) []const Node {
        const r = self.end_ranges.items[pos];
        return self.nodes.items[r.start .. r.start + r.len];
    }
};
```

ただし、単純な flat append だけでは `end_ranges[pos]` ごとに連続領域を保証しづらい。候補追加順によっては、同じ `pos` に終わるノードが分散する可能性がある。

そのため、以下のいずれかを採用する。

### 案A: two-pass bucket layout

1. まず各終端位置の候補数を数える
2. prefix sum で `end_ranges` を確定する
3. `nodes` を一括確保する
4. 各位置の範囲にノードを書き込む

長所:

* 終端位置ごとのノードが完全に連続する
* 探索が速い
* allocation が一括で済む

短所:

* ラティス構築が二度手間になる
* 実装が複雑
* unknown word 生成との統合に注意が必要

### 案B: per-position temporary buckets + final compact

1. 構築中は簡易 bucket を使う
2. ラティス構築後に flat compact する
3. Viterbi探索は compact 後の配列を使う

長所:

* 実装しやすい
* 探索時の局所性を改善できる

短所:

* compact のコピーコストがある
* 短文では効果が薄い可能性

### 案C: current-like buckets with arena-backed slices

1. 各終端位置に small buffer を持つ
2. 実データは arena から確保する
3. `Vec` 相当の個別allocator呼び出しはしない

長所:

* Rust版に近く移植しやすい
* allocation は抑えられる

短所:

* flat layout ほどの局所性は得にくい

### 推奨

初期実装は案Cで挙動互換を優先し、その後、案Aまたは案Bをベンチ比較する。最終候補は案A。

## Node 表現

### AoS baseline

まずは Rust版に近い Array of Structs で実装する。

```zig
const Node = struct {
    word_id: u32,
    start: u32,
    end: u32,
    left_id: u16,
    right_id: u16,
    word_cost: i32,
    min_cost: i32,
    prev_node: u32,
};
```

注意点:

* `prev_node` は pointer ではなく index にする
* `start` / `end` は byte offset か char offset かを明確に分ける
* IDの最大値を確認し、`u16` で足りるものは `u16` にする
* alignment による padding を `@sizeOf(Node)` で確認する

### Hot / Cold split

Viterbi探索中に頻繁に読むフィールドと、結果復元時にしか使わないフィールドを分ける。

Hot:

* `right_id`
* `min_cost`
* `prev_node`

Cold:

* `word_id`
* `start`
* `end`
* `left_id`
* `word_cost`
* features

```zig
const NodeHot = struct {
    right_id: u16,
    min_cost: i32,
    prev_node: u32,
};

const NodeCold = struct {
    word_id: u32,
    start: u32,
    end: u32,
    left_id: u16,
    word_cost: i32,
};
```

探索時には `NodeHot` を主に読み、必要な場合のみ `NodeCold` に触る。

### SoA layout

さらに攻める場合、完全な Structure of Arrays にする。

```zig
const LatticeSoA = struct {
    word_ids: []u32,
    starts: []u32,
    ends: []u32,
    left_ids: []u16,
    right_ids: []u16,
    word_costs: []i32,
    min_costs: []i32,
    prev_nodes: []u32,
};
```

長所:

* Viterbi探索で必要な列だけ読める
* cache効率がよい
* SIMD / prefetch を試しやすい

短所:

* 実装が複雑
* token復元が少し面倒
* append処理で複数配列の整合性を保つ必要がある

### 推奨

1. AoS baseline
2. Hot / Cold split
3. SoA

の順にベンチ比較する。

## Viterbi探索

### 基本形

各開始位置 `begin` から辞書候補を列挙し、候補 `candidate` に対して、`begin` に終わるノードの中から最小コストの前ノードを探す。

```text
cost = prev.min_cost
     + matrix[prev.right_id][candidate.left_id]
     + candidate.word_cost
```

最小の `prev` を記録する。

### 改善余地

支配的になりやすいのは以下。

* `prev` ノード列の走査
* 連接コスト表 `matrix[right_id][left_id]` のランダムアクセス
* 候補ノード作成
* unknown word処理

### 探索関数の分離

辞書候補列挙とコスト計算を分け、ベンチ可能にする。

```zig
fn findBestPrev(
    matrix: *const ConnectionMatrix,
    prev_nodes: []const NodeHot,
    left_id: u16,
    word_cost: i32,
) BestPrev {
    var best_cost: i32 = std.math.maxInt(i32);
    var best_index: u32 = invalid_node;

    for (prev_nodes, 0..) |prev, i| {
        const trans = matrix.cost(prev.right_id, left_id);
        const cost = prev.min_cost + trans + word_cost;
        if (cost < best_cost) {
            best_cost = cost;
            best_index = @intCast(i);
        }
    }

    return .{ .cost = best_cost, .index = best_index };
}
```

この関数を個別に micro benchmark する。

## 連接コスト表設計

### baseline

まずは row-major の dense matrix とする。

```zig
const ConnectionMatrix = struct {
    left_size: u32,
    right_size: u32,
    costs: []const i16,

    pub inline fn cost(self: *const ConnectionMatrix, right_id: u16, left_id: u16) i32 {
        return self.costs[@as(usize, right_id) * self.left_size + left_id];
    }
};
```

### 改善案

#### ID remapping

頻出する left/right ID が近くに配置されるように辞書ビルド時に remap する。

これは Vibrato の既存方針と同じ方向性であり、Zig版でも必須に近い。

#### hot rows cache

頻出 `right_id` の row を小さな hot cache 領域に複製する。

```text
hot_right_ids -> compact row table
cold_right_ids -> original matrix
```

利点:

* よく使う連接コスト行を小さいメモリ領域に集約できる
* L2/L3 cacheに乗りやすい可能性がある

注意:

* 分岐が増える
* hot判定テーブルが必要
* 辞書・コーパス依存が強い

#### blocked matrix

matrixを固定サイズblockに分割する。

```text
[right block][left block][within block]
```

候補の left_id / right_id 分布が局所化されている場合に効く可能性がある。

#### compressed matrix

巨大辞書向けに、以下を検討する。

* `i16` dense matrix
* row dictionary compression
* delta encoding
* frequently used rows only uncompressed

ただし、復号コストが探索ループに入ると逆効果になりやすい。初期段階では dense を維持する。

### 推奨

初期版は dense row-major + ID remapping を前提にする。hot rows cache と blocked matrix は実験扱いにする。

## 辞書引き

### 方針

* 入力文は UTF-8 のまま保持する
* 解析用に codepoint / char index buffer を作る
* trie は codepoint 単位で検索する
* byte offset mapping は token復元用に保持する

### Trie候補

初期実装では、Rust版の Crawdad 相当を完全移植するのではなく、以下のいずれかを検討する。

1. 既存辞書フォーマットを読み、最小限の trie reader を実装する
2. Zig版専用の辞書runtime formatを作る
3. Rust側で辞書をZig向けbinaryに変換するツールを用意する

最速を狙うなら 2 または 3 が望ましい。

## 辞書フォーマット

### Runtime dictionary

Zig版では、実行時に扱いやすい binary format を定義する。

```text
Header
String table
Lexicon entries
Trie data
Connection matrix
UNK rules
Feature table
ID remapping tables
```

### 設計原則

* runtime中に複雑なdecodeをしない
* offsetは32bitで足りる範囲なら32bitにする
* endianを固定する
* alignmentを明示する
* mmap可能なlayoutにする
* versionとfeature flagsを持つ

### Header案

```zig
const DictHeader = extern struct {
    magic: [8]u8,
    version: u32,
    flags: u32,
    lexicon_offset: u64,
    trie_offset: u64,
    matrix_offset: u64,
    string_offset: u64,
    unk_offset: u64,
};
```

`extern struct` を使う場合も、endiannessとpaddingの扱いには注意する。portableにするなら手動decodeの方が安全。

## Unknown word 処理

unknown word は性能・品質の両方に効くため、初期実装から分離しておく。

```zig
const UnknownHandler = struct {
    pub fn candidates(
        self: *const UnknownHandler,
        sentence: *const SentenceBuffer,
        pos: usize,
        out: *CandidateWriter,
    ) void {
        // generate unknown candidates
    }
};
```

注意点:

* unknown候補が多すぎるとラティスが膨らむ
* 文字種判定を高速化する
* 文字種テーブルは compact に保持する
* 連続する同種文字の処理を最適化する

## API設計

### Zig API

```zig
const Tokenizer = struct {
    dict: *const Dictionary,

    pub fn init(allocator: Allocator, dict_path: []const u8) !Tokenizer;
    pub fn deinit(self: *Tokenizer) void;
    pub fn createWorker(self: *const Tokenizer, allocator: Allocator) !Worker;
};

const Worker = struct {
    pub fn tokenize(self: *Worker, input: []const u8) ![]const Token;
};
```

### C ABI

外部利用を考えるなら C ABI を提供する。

```c
vibrato_zig_tokenizer_t* vibrato_zig_tokenizer_new(const char* dict_path);
vibrato_zig_worker_t* vibrato_zig_worker_new(vibrato_zig_tokenizer_t* tokenizer);
int vibrato_zig_tokenize(vibrato_zig_worker_t* worker, const char* input, vibrato_zig_tokens_t* out);
void vibrato_zig_tokens_free(vibrato_zig_tokens_t* tokens);
```

C ABIでは ownership を明確にする。

* tokenizer は dictionary を所有
* worker は一時メモリを所有
* tokens は worker 内部参照か、呼び出し側所有コピーかを明示

初期実装では、tokens は worker 内部バッファを参照し、次回 tokenize で無効化される仕様が簡単。

## 並列性

* `Dictionary` は immutable で共有可能
* `Worker` は thread-local
* `Tokenizer` から `Worker` を複数生成する
* arena は `Worker` ごとに持つ

```text
Dictionary 1個
  ├── Worker thread A
  ├── Worker thread B
  └── Worker thread C
```

共有mutable stateは持たない。

## ベンチマーク計画

### 比較対象

* Rust版 Vibrato
* Zig AoS baseline
* Zig flat lattice
* Zig hot/cold Node
* Zig SoA Node
* Zig matrix hot rows variant

### 入力データ

* 短文大量
* 中長文
* 法務文書
* ニュース文
* Webテキスト
* unknown word が多いテキスト
* UniDic系の大きな辞書
* IPADIC系の小さめ辞書

### 指標

* tokens/sec
* sentences/sec
* bytes/sec
* p50 / p95 latency
* allocation count
* peak RSS
* L1-dcache-load-misses
* LLC-load-misses
* branch-misses
* cycles / instruction

Linuxでは以下を使う。

```bash
perf stat -d ./bench_tokenize corpus.txt
```

Zig側では、各実装variantを compile-time option で切り替えられるようにする。

```zig
const Layout = enum {
    aos,
    hot_cold,
    soa,
};
```

### Micro benchmark

以下を個別測定する。

* UTF-8 decode / sentence buffer構築
* trie lookup
* candidate generation
* `findBestPrev`
* matrix cost lookup
* lattice append
* backtrace
* token output construction

特に `findBestPrev` と matrix lookup は最重要。

## 実装ステップ

### Phase 0: 調査

* Rust版の出力仕様を確認する
* 小さな辞書とテスト文を固定する
* Rust版のベンチ基準値を取る
* `perf` でホットパスを確認する

成果物:

* baseline benchmark report
* compatibility test cases
* minimal corpus

### Phase 1: Zig baseline

* Dictionary loader minimum
* Tokenizer / Worker
* AoS Node
* current-like lattice buckets
* dense matrix
* unknown word minimum

目標:

* 出力互換
* Rust版比で極端に遅くない
* allocation count を制御できている

### Phase 2: flat lattice

* arena-backed lattice
* flat buffer + range index
* 案A/B/Cの比較
* Viterbi探索関数の分離

目標:

* allocation countを文あたりゼロに近づける
* cache missを削減する

### Phase 3: Node layout optimization

* Hot / Cold split
* SoA implementation
* backtraceとの整合性確認

目標:

* `findBestPrev` の速度改善
* L1/LLC miss削減

### Phase 4: matrix locality optimization

* ID remappingの維持
* hot rows cache実験
* blocked matrix実験
* prefetch実験

目標:

* 大きな辞書での改善
* 小さな辞書での劣化を避ける

### Phase 5: Packaging

* CLI
* C ABI
* docs
* benchmark report
* fuzz / differential testing

## テスト方針

### Differential testing

Rust版 Vibrato と Zig版の出力を比較する。

比較対象:

* surface
* byte offsets
* feature fields
* word id
* total path cost

完全一致が難しい箇所は差分許容ルールを明示する。

### Fuzz testing

入力文字列について fuzz する。

* 不正UTF-8
* 空文字
* 長大文字列
* 絵文字
* combining marks
* 制御文字
* unknown word連続
* 混在スクリプト

### Memory safety

* Zig safety check有効でテスト
* Debug / ReleaseSafe / ReleaseFast を比較
* arena reset後の参照切れをチェック
* C ABI経由のownership違反をテスト

## リスク

### Zig移植だけでは速くならない

最大のリスク。Rust版はすでに最適化されているため、単純移植では差が出ない可能性が高い。

対策:

* Phaseごとに測定する
* 効果のない最適化は捨てる
* Rust版で先にプロトタイプ可能なものはRustで検証する

### 辞書互換が重い

辞書フォーマットやビルドツールまで含めるとスコープが膨らむ。

対策:

* 初期は runtime 専用辞書に変換する
* Rust側に変換ツールを置いてもよい
* 完全互換は後回しにする

### SoA化で実装複雑性が増す

性能は上がる可能性があるが、保守性が下がる。

対策:

* AoS / HotCold / SoA を compile-time option で切替
* ベンチ結果が十分でなければ採用しない

### 大辞書ではmatrixが支配的

ラティスやallocatorを改善しても、連接コスト表アクセスが支配的なら効果が限定される。

対策:

* matrix locality改善を独立テーマとして扱う
* cache missを必ず測定する

## 成功基準

### Minimum success

* Rust版と主要ケースで出力互換
* Rust版と同等程度の速度
* 文ごとのallocationがほぼ発生しない
* C ABIまたはCLIから利用できる

### Target success

* 小〜中辞書で Rust版比 5〜15% 高速
* 大辞書で Rust版比 10〜30% 高速
* p95 latency 改善
* cache miss削減が確認できる

### Stretch goal

* UniDic系の巨大辞書で、matrix locality改善により大幅な速度改善
* mmap辞書で起動時間とRSSを改善
* Rust/Python/NodeなどからC ABI経由で利用可能

## 推奨する最初の実験

最初にやるべき実験は、Zig完全移植ではなく、Rust版または小さなZig prototypeで以下を比較すること。

1. 現行に近い `Vec<Vec<Node>>` / bucket layout
2. flat buffer + end range layout
3. Hot / Cold split Node
4. `findBestPrev` のmatrix lookup cache miss

この結果で差が出るなら、Zig移植の価値がある。差が出ない場合、allocatorや言語差ではなく、連接表・辞書引き・アルゴリズム側に焦点を移すべきである。

## 追加の高速化・差別化アイデア

ここまでの主眼はラティス、Node、連接コスト表、allocatorである。さらに Vibrato / MeCab 系実装との差別化を狙うなら、以下の領域も検討する価値がある。

### 1. 辞書ビルド時プロファイル最適化

実行時だけでなく、辞書ビルド時に対象ドメインのコーパスを使って最適化する。

例:

* left/right ID の頻度順 remapping
* よく出る単語IDの連続配置
* よく出る feature string の近接配置
* matrix hot rows の選定
* unknown word rule の発火頻度に基づく順序最適化
* trie node の遷移順序最適化

```text
training corpus
  -> frequency profile
  -> optimized dictionary layout
  -> runtime dictionary
```

この方向は、一般用途の形態素解析器との差別化になりやすい。たとえば法務文書、医療文書、金融文書、社内文書など、入力ドメインが偏っている場合に効く可能性が高い。

初期実装では、辞書変換ツールに `--profile-corpus` を渡せる設計にしておく。

```bash
zig-dict-build \
  --input system.dic \
  --profile-corpus legal_corpus.txt \
  --output legal.optimized.zdict
```

### 2. Candidate pruning

通常の Viterbi では候補を広く保持するが、用途によっては候補を早めに刈り込める。

候補:

* 明らかに高コストな候補を破棄する
* 各終端位置の候補数上限を設ける
* beam search 的に上位K候補だけ残す
* unknown word候補を保守的に制限する
* 特定ドメイン辞書を優先し、一般辞書候補を後回しにする

```text
if candidate_cost > best_cost_at_position + beam_width:
    discard
```

注意点として、完全な最短経路保証が崩れる可能性がある。そのため、以下のようにモードを分ける。

* `exact`: 完全互換・正確性優先
* `fast`: 軽い pruning を許容
* `aggressive`: 精度より速度優先

このモード分けはプロダクト上の差別化になりやすい。

### 3. Partial / streaming tokenization

長文を一括解析するのではなく、文・節・句読点単位で分割し、streaming 的に解析する。

狙い:

* 長大入力での peak memory 削減
* レイテンシ改善
* エディタ・Wordアドイン・リアルタイム校正で使いやすい
* 入力差分に対する incremental re-tokenize に繋げられる

```text
input stream
  -> segmenter
  -> tokenize segment
  -> emit tokens
```

注意点:

* 分割境界をまたぐ形態素をどう扱うか
* unknown word の連続処理
* 文末記号がない長文
* byte offset の復元

完全な解析品質を維持する場合は、境界周辺に overlap window を持たせる。

```text
[segment A][overlap]
          [overlap][segment B]
```

### 4. Incremental tokenization

エディタやWordアドイン用途では、文書全体を毎回再解析しないことが大きな差別化になる。

変更範囲だけを再解析し、前後の安定境界まで token を再利用する。

```text
old tokens + edit range
  -> find stable left boundary
  -> find stable right boundary
  -> re-tokenize only affected region
  -> splice tokens
```

安定境界の候補:

* 改行
* 句点
* 空白
* 記号
* 文節境界候補
* 一定文字数以上離れた安全地点

これは通常のバッチ形態素解析器があまり重視しない領域であり、リアルタイム用途では強い差別化になる。

API例:

```zig
pub fn updateTokenization(
    self: *IncrementalTokenizer,
    old_text: []const u8,
    edit: TextEdit,
    new_text: []const u8,
) !TokenDiff;
```

### 5. Batch tokenization API

多数の短文を解析する用途では、1文ずつAPIを呼ぶ overhead が支配的になることがある。

対策:

* 複数文をまとめて受け取る
* Worker 内部バッファをまとめて再利用する
* 入力を連結して offset table で管理する
* thread pool に投げる
* 結果を columnar に返す

```zig
pub fn tokenizeBatch(
    self: *WorkerPool,
    inputs: []const []const u8,
    out: *BatchTokenResult,
) !void;
```

差別化ポイント:

* 検索インデックス作成
* 大量文書処理
* RAG前処理
* ログ解析
* 契約書一括解析

CLIでも以下のような batch mode を用意する。

```bash
zig-vibrato tokenize-batch --input jsonl --output msgpack
```

### 6. Columnar output / zero-copy output

多くの用途では、tokenごとにrichなオブジェクトを作るより、必要な列だけを返す方が速い。

出力を columnar にする。

```text
surfaces:     []Range
word_ids:     []u32
start_bytes:  []u32
end_bytes:    []u32
pos_ids:      []u16
features:     []FeatureRef
```

利点:

* allocation削減
* FFIしやすい
* Python / Node / WASM から扱いやすい
* SIMD / vectorized post-process に繋げやすい

APIでは、用途に応じて出力レベルを選べるようにする。

```zig
const OutputMode = enum {
    surfaces_only,
    ids_only,
    offsets_only,
    full_features,
};
```

`surfaces_only` や `offsets_only` は非常に高速にできる可能性がある。

### 7. Feature lazy decoding

形態素解析の内部では、毎回すべての feature string を展開する必要はない。

方針:

* 解析中は `word_id` / `feature_id` のみ扱う
* surface と offsets は入力文字列への参照にする
* feature string は必要になった時だけ decode する
* POSなど頻出属性は numeric ID で返す

```zig
const Token = struct {
    surface: Range,
    word_id: u32,
    feature_id: u32,

    pub fn feature(self: Token, dict: *const Dictionary) []const u8 {
        return dict.featureString(self.feature_id);
    }
};
```

これは、単に分かち書きや検索用token列だけ欲しい用途で大きく効く。

### 8. Specialized tokenizer modes

用途別に専用モードを用意する。

例:

* `wakati`: 分かち書きのみ
* `search`: 検索インデックス用に複合語・原形・N-bestを返す
* `pos`: 品詞IDまで返す
* `full`: 全featureを返す
* `lattice`: デバッグ・N-best用にラティスを返す

`wakati` や `search` では、feature展開や一部の後処理を省略できる。

```bash
zig-vibrato tokenize --mode wakati
zig-vibrato tokenize --mode search
zig-vibrato tokenize --mode full
```

これは性能だけでなく、APIの使いやすさでも差別化になる。

### 9. N-best / lattice reuse

N-best解析を行う場合、1-best解析後にラティスを捨てるのではなく、同じラティスを再利用する。

差別化案:

* 1-best と N-best を同じ構築済みラティスから返す
* 上位K経路探索を optional にする
* search mode で曖昧な候補だけ追加出力する
* downstream task が必要なときだけ N-best を計算する

```zig
const AnalyzeOptions = struct {
    nbest: u16 = 1,
    keep_lattice: bool = false,
};
```

### 10. Domain dictionary overlay

巨大なベース辞書を毎回完全に引くのではなく、ドメイン辞書を overlay として先に探索する。

```text
domain trie
  -> base trie
  -> unknown handler
```

利点:

* ドメイン語を優先できる
* ユーザー辞書の追加が軽い
* ベース辞書を再ビルドせず差分更新できる
* Wordアドインや企業内利用で扱いやすい

差別化案:

* overlay辞書を複数重ねる
* overlayごとに優先度を持つ
* domain match時はbase候補を一部skipするfast mode
* ユーザー辞書をhot reloadする

### 11. Memory-mapped dictionary

辞書を mmap 可能な形式にすると、起動時間とメモリ使用量で差別化できる。

狙い:

* 起動時ロードを高速化
* 複数プロセス間で辞書ページを共有
* serverless / CLI で cold start 改善
* 大辞書でRSSを抑える

設計上は、runtime dictionary format を最初から mmap 前提にしておく。

注意点:

* endian
* alignment
* pointerを保存しない
* offset参照に統一する
* version migration

### 12. WASM / embedded mode

Zigの強みとして、WASMや単一バイナリ配布に寄せやすい。

差別化ポイント:

* ブラウザ内tokenization
* VS Code / web editor 拡張
* Wordアドインのローカル解析
* サーバー不要のデモ
* エッジ環境での前処理

WASM向けには以下を分ける。

* 小型辞書
* feature lazy decoding
* wakati/search専用モード
* allocator固定
* panic-free API

### 13. SIMD / vectorized preprocessing

形態素解析本体は分岐とランダムアクセスが多くSIMD化しにくいが、前処理には余地がある。

候補:

* UTF-8 validation
* ASCII fast path
* 文字種判定
* 空白・句読点スキャン
* segment boundary detection
* byte offset mapping

特に、ASCIIを多く含む文書や英数字混じりの契約書では、ASCII fast path が効く可能性がある。

```text
if input chunk is ASCII:
    use fast character class table
else:
    fallback to UTF-8 decode
```

### 14. Compile-time specialization

Zigでは compile-time option により、用途別に不要な機能を落としたバイナリを作りやすい。

例:

* unknown word処理なし
* N-bestなし
* full featureなし
* debug latticeなし
* C ABIのみ
* WASM向け小型辞書のみ

```zig
const BuildOptions = struct {
    enable_nbest: bool,
    enable_full_features: bool,
    enable_lattice_dump: bool,
    enable_mmap: bool,
};
```

これにより、汎用版と高速・小型版を分けられる。

### 15. Observability / profiler-friendly design

高速化を継続するには、内部統計を出せることが重要である。

出力する統計:

* 入力文字数
* 生成候補数
* unknown候補数
* ラティスノード数
* matrix lookup回数
* pruning数
* arena使用量
* token数
* 各フェーズの処理時間

```bash
zig-vibrato tokenize --stats corpus.txt
```

APIでも `AnalyzeStats` を返せるようにする。

```zig
const AnalyzeStats = struct {
    chars: u32,
    nodes: u32,
    matrix_lookups: u64,
    unknown_candidates: u32,
    arena_bytes_used: usize,
};
```

これは開発者体験としても差別化になる。

## 差別化の優先順位

優先度をつけるなら、以下が現実的である。

| 優先度 | 項目                               | 理由                        |
| --- | -------------------------------- | ------------------------- |
| 高   | Feature lazy decoding            | 多くの用途で不要な文字列展開を避けられる      |
| 高   | OutputMode                       | 分かち書き・検索用途で明確に速くできる       |
| 高   | Batch tokenization               | 実務の大量処理で効きやすい             |
| 高   | mmap dictionary                  | 起動時間・RSSで差別化しやすい          |
| 中   | Incremental tokenization         | エディタ・Wordアドイン用途で強い差別化     |
| 中   | Domain dictionary overlay        | 企業・専門領域向けに有効              |
| 中   | Profile-guided dictionary layout | ドメイン特化で性能差を作れる            |
| 中   | Candidate pruning                | fast modeとして有効。ただし精度検証が必要 |
| 低〜中 | SIMD preprocessing               | 入力特性次第。効果測定が必要            |
| 低〜中 | Compile-time specialization      | 配布形態によって有効                |

特に、プロダクトとして差別化するなら以下の3つが強い。

1. **Incremental tokenization**: リアルタイム校正・Wordアドイン向け
2. **Domain dictionary overlay**: 企業・法務・専門文書向け
3. **OutputMode / lazy feature**: 用途別に不要処理を削れる高速API

## まとめ

Zig移植の勝ち筋は、Rust版をそのまま置き換えることではない。

勝ち筋は以下である。

* 文単位一時メモリを arena 化する
* ラティスを flat / compact layout にする
* Node を Hot / Cold または SoA に分ける
* 連接コスト表の局所性を改善する
* runtime dictionary format を実行時最適な形に固定する

この方針であれば、allocator削減だけでなく、cache locality とデータ配置の改善によって、Vibratoに対して実測で勝てる可能性がある。
