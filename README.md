# delarocha

[![CI](https://github.com/bokuweb/delarocha/actions/workflows/ci.yml/badge.svg)](https://github.com/bokuweb/delarocha/actions/workflows/ci.yml)

- runtime dictionary loader
- `Tokenizer` / reusable `Worker`
- AoS nodes
- dense row-major connection matrix
- minimal unknown word handling
- C ABI for Rust bindings
- `cargo bench` harness for comparison with Vibrato

## Installation

```bash
cargo add delarocha
```

Optional features: `vibrato-system` (load precompiled Vibrato `system.dic` /
`system.dic.zst`), `zig-ffi` (link the Zig tokenizer core; see
[Rust Binding To Zig C ABI](#rust-binding-to-zig-c-abi)), and `wasm`.

## Dictionary Fixture

The Zig C ABI still accepts a deliberately small TSV fixture format:

```text
matrix	<right_size>	<left_size>
<row 0 i16 costs...>
entry	<surface>	<left_id>	<right_id>	<word_cost>	<feature>
```

The Rust binding now also accepts MeCab/Vibrato-style raw dictionary readers:

- `lex.csv`
- `matrix.def`
- `char.def`
- `unk.def`

This matches the input shape of `vibrato::SystemDictionaryBuilder::from_readers` and is the current compatibility path for differential tests and the CLI.

The `vibrato-system` feature can also load precompiled Vibrato dictionaries
directly from `system.dic` or zstd-compressed `system.dic.zst`:

```rust
let tokenizer = delarocha::VibratoSystemDictionary::from_path("system.dic.zst")?
    .into_tokenizer()
    .ignore_space(true)?
    .max_grouping_len(24);
let tokens = tokenizer.tokenize("これはテストです。")?;
```

## Rust Tests

```bash
cargo test
```

The CI workflow runs the Rust, Vibrato system dictionary, and Zig unit tests on
Linux, macOS, and Windows. It also runs `zig-ffi` tests and compiles the
Yokohama text benchmark on Linux and macOS; Windows currently exercises the
pure Rust, `vibrato-system`, and Zig test suites while the MSVC Zig FFI link
path is kept out of the matrix.

## Fuzzing

The repository has deterministic seeded fuzz-style tests that generate mixed
Japanese, ASCII, whitespace, punctuation, and emoji inputs on every CI run:

- `bindings/rust/tests/fuzz_tokenizer.rs` verifies Rust tokenization does not
  fail and that emitted token spans rebuild the original UTF-8 input.
- `bindings/rust/tests/zig_ffi.rs` verifies Zig binary count-only tokenization
  returns the same token count as full Zig tokenization for seeded random inputs.

Run them locally with:

```bash
cargo test -p delarocha
cargo test -p delarocha --features zig-ffi
```

Stress them with more generated inputs by overriding the deterministic seed
count and maximum generated input length:

```bash
DELAROCHA_FUZZ_SEEDS=100000 DELAROCHA_FUZZ_MAX_LEN=256 cargo test -p delarocha --test fuzz_tokenizer
DELAROCHA_FUZZ_SEEDS=100000 DELAROCHA_FUZZ_MAX_LEN=256 cargo test -p delarocha --features zig-ffi --test zig_ffi
```

Coverage-guided fuzzing uses `cargo-fuzz` with libFuzzer. The `tokenize`
target fuzzes valid UTF-8 input against token span and surface invariants, and
the `dictionary` target fuzzes the compact dictionary parser for panic-free
error handling.

```bash
cargo install cargo-fuzz
cargo +nightly fuzz run tokenize -- -max_total_time=30
cargo +nightly fuzz run dictionary -- -max_total_time=30
```

## CLI

```bash
echo '本とカレー' | cargo run -p delarocha -- \
  --lex fixtures/lex.csv \
  --matrix fixtures/matrix.def \
  --char fixtures/char.def \
  --unk fixtures/unk.def \
  -O wakati
```

MeCab-compatible space skipping and unknown grouping options are available:

```bash
cargo run -p delarocha -- --lex lex.csv --matrix matrix.def --char char.def --unk unk.def -S -M 24
```

## WebAssembly Playground

The Rust tokenizer can be compiled to WebAssembly and used from a static
browser playground. The playground downloads MeCab ipadic source data, converts
it to UTF-8, and serves gzip-compressed dictionary assets next to the static UI:

```bash
rustup target add wasm32-unknown-unknown
cargo install -f wasm-bindgen-cli --version 0.2.120
cargo build -p delarocha --lib --target wasm32-unknown-unknown --features wasm --release
mkdir -p public/pkg
cp -R playground/. public/
python3 scripts/prepare_ipadic_playground.py --out-dir public/dic
wasm-bindgen \
  --target web \
  --out-dir public/pkg \
  --out-name delarocha \
  target/wasm32-unknown-unknown/release/delarocha.wasm
python3 -m http.server 4173 --directory public
```

Pushes to `main` build the same artifact and deploy it to GitHub Pages.

## Zig Tests

Requires Zig on `PATH`.

```bash
cd zig
zig build test
```

## Zig Core Benchmark

The pure Zig microbenchmark measures tokenizer core time without Rust/C ABI overhead.

```bash
cd zig
zig build bench -Doptimize=ReleaseFast
```

## Rust Binding To Zig C ABI

The `zig-ffi` feature links a prebuilt static Zig library for common Rust
targets, so downstream crates can use the Rust crate without installing Zig.
The bundled targets are:

- `aarch64-apple-darwin`
- `x86_64-apple-darwin`
- `aarch64-unknown-linux-gnu`
- `x86_64-unknown-linux-gnu`
- `i686-pc-windows-msvc`
- `x86_64-pc-windows-msvc`
- `wasm32-unknown-unknown`

The WASM artifact is built with Zig's `ReleaseSmall` optimization mode to keep
the download size low. Native artifacts continue to use `ReleaseFast`.

Set `DELAROCHA_BUILD_ZIG=1` to rebuild the static library from
`zig/src/lib.zig`. Unsupported targets also fall back to building from Zig
sources, so those environments still need Zig installed.

```bash
cargo test -p delarocha --features zig-ffi
```

To regenerate the checked-in libraries after changing the Zig sources, run
`scripts/build_prebuilt.sh` (on macOS, so the Darwin archives can be repacked
with 8-byte aligned members); see
[bindings/rust/prebuilt/README.md](https://github.com/bokuweb/delarocha/blob/main/bindings/rust/prebuilt/README.md).

Binary dictionaries loaded from a path (`ZigTokenizer::from_binary_path`,
`ZigTokenizer::count_only_from_binary_path`, and Zig's
`Tokenizer.initBinaryFile` / `Dictionary.fromBinaryFile`) are memory-mapped
read-only and borrowed for the tokenizer's lifetime: features, the connection
matrix, and all trie tables are used in place instead of being copied. Do not
truncate or rewrite such a file in place while a tokenizer uses it (write a new
file and rename it instead). `ZigTokenizer::from_binary_bytes` and Zig's
`Dictionary.fromBinaryFileCopy` keep a private copy when that cannot be
guaranteed.

Binary dictionaries use format version 4 (magic `DLRDIC04`). Every table
starts at a 16-byte aligned offset and entry features are located through a
separate offset table, so loading a memory-mapped dictionary does not read any
per-entry data: pages are only faulted in when tokenization touches them.
Files written by earlier versions (`DLRDIC01`, `DLRDIC02`, `DLRDIC03`) or by an unknown
format version are rejected with `UnsupportedDictionaryVersion` (Rust:
`Error::UnsupportedDictionaryVersion`), and corrupt tables or out-of-range
indices with `InvalidDictionary`; rebuild them from the raw MeCab dictionary
files with `ZigTokenizer::write_binary_from_raw_paths` (or Zig's
`Dictionary.toBinaryAlloc`). Rebuilding the same raw files produces
byte-identical output.

When writing a binary dictionary, the connection (left/right context) ids are
renumbered so that frequently used connection-matrix rows and columns sit next
to each other in memory. By default the order is estimated from the lexicon
alone (`ConnectionIdOrder::DictionaryPrior`);
`ZigTokenizer::write_binary_from_raw_paths_with_id_order` can instead keep the
raw ids (`Original`), rank them by a precomputed `id left_weight right_weight`
file (`WeightsFile`), or measure them by tokenizing a sample text
(`SampleText`; use text representative of, but not identical to, the text you
will tokenize). Renumbering is invisible to callers: token spans, word ids,
features and costs are unchanged, and no API exposes connection ids. On the
Yokohama benchmark it speeds up tokenization by roughly 2-4%.

Large dictionaries store entry features compactly: the leading CSV columns
(for IPADIC the six part-of-speech/conjugation columns) come from a small
shared table, and the remaining columns are encoded as back-references to the
surface, its katakana rendering, or an earlier column plus a literal suffix,
with a raw fallback per entry. The builder picks the layout from the data and
keeps raw features when the encoding would not be smaller (Zig:
`Dictionary.toBinaryAllocWithOptions(.{ .compact_features = false })` forces
raw). For IPADIC the feature data shrinks from 31.1 MB to 7.5 MB and the
dictionary file from 63.6 MB to 40.0 MB. Tokens still expose byte-identical
feature strings: they are decoded once per word into a small per-worker cache
(bounded to about 1 MiB) when features are requested, so span/count-only
tokenization does not decode anything, and features borrowed from a worker are
valid until the worker is used again.

For output-sensitive callers, `ZigWorker::tokenize_borrowed_views` returns a
`ZigTokenViews` collection backed by the worker's reusable metadata buffers.
Iterating it avoids both owned surface/feature strings and the per-call
`Vec<ZigTokenView>` allocation. The collection and its token views remain valid
until the worker is mutably used again. Each `ZigTokenView` carries the borrowed
surface and feature plus byte and character ranges (`range_byte`,
`range_char`), and `to_token()` reproduces the owned `ZigWorker::tokenize`
output exactly.

Callers that need owned tokens can pass a reusable vector to
`ZigWorker::tokenize_into`; existing `Token` string buffers are overwritten in
place, so a sentence loop stops allocating once the buffers warm up.
`tokenize_spans_into` does the same for span-only output.

Feature strings are checked for UTF-8 once per dictionary word id per worker
and memoized, rather than on every emitted token.

### Worker memory

Workers keep their lattice and token buffers between calls so steady-state
tokenization does not allocate. They grow to fit the largest input seen, about
60 bytes per input byte for full tokenization and 32 for count-only on IPADIC
(a 659 KB document leaves roughly 39 MB / 20 MB behind). To give that back:

- `retained_bytes()` reports the capacity currently held.
- `shrink_to(max_bytes)` frees buffers (largest first) until at most
  `max_bytes` remain; `shrink_to_fit()` frees everything. Later calls regrow
  what they need and return identical tokens.
- `set_retained_capacity_limit(Some(max_bytes))` trims automatically after any
  call that leaves more than `max_bytes` retained. Calls whose buffers stay
  below the limit never trim, so small-sentence loops keep reusing their
  buffers. The buffer holding the tokens just returned is kept (shrunk to the
  result) until a later call replaces it.

These exist on `ZigWorker` (native lattice, Rust-side token metadata, parked
`tokenize_into` tokens, and the UTF-8 memo) and on the pure-Rust `Worker`. In
Zig they are `Worker.retainedBytes`, `Worker.shrinkTo` / `Worker.shrink`, and
`Worker.setRetainedCapacityLimit`; the C ABI exports
`delarocha_worker_retained_bytes`, `delarocha_worker_shrink_to`, and
`delarocha_worker_set_retained_limit` (`SIZE_MAX` removes the limit).

## Benchmarks

Run the baseline benchmark:

```bash
cargo bench -p delarocha
```

Compare against Vibrato by enabling `vibrato-bench` and pointing to a compiled Vibrato dictionary. Compressed `.zst` dictionaries are decompressed through `zstd` before calling `vibrato::Dictionary::read`, matching Vibrato's API note.

```bash
VIBRATO_SYSTEM_DIC=/path/to/system.dic.zst \
  cargo bench -p delarocha --features vibrato-bench
```

A precompiled ipadic dictionary can be downloaded from Vibrato releases:

```bash
mkdir -p target/vibrato-dic
curl -L -o target/vibrato-dic/ipadic-mecab-2_7_0.tar.xz \
  https://github.com/daac-tools/vibrato/releases/download/v0.5.0/ipadic-mecab-2_7_0.tar.xz
tar -xf target/vibrato-dic/ipadic-mecab-2_7_0.tar.xz -C target/vibrato-dic
VIBRATO_SYSTEM_DIC="$PWD/target/vibrato-dic/ipadic-mecab-2_7_0/system.dic.zst" \
  cargo bench -p delarocha --features 'zig-ffi vibrato-bench' --bench tokenize
```

The Vibrato project and dictionary release information are available at <https://github.com/daac-tools/vibrato>.

### Vibrato-Style Benchmark

The `vibrato_style_benchmark` example mirrors the benchmark runner used by
`daac-tools/vibrato`: it reads newline-separated sentences from stdin, runs
10 warm runs per trial, repeats 10 trials, discards each trial's fastest and
slowest run, and prints `Elapsed_seconds_to_tokenize_all_sentences`.

```bash
cargo run -p delarocha --release --features zig-ffi \
  --example vibrato_style_benchmark -- \
  -i /path/to/delarocha.dic < test.txt
```

Use `--full` to benchmark full token materialization instead of the count-only
path. The default count-only mode matches Vibrato's benchmark loop shape by
tokenizing each sentence and accumulating token counts without formatting
token output.

`--full` materializes zero-copy token views (`tokenize_borrowed_views`: borrowed
surface and feature, byte and character ranges). This is the like-for-like
comparison with Vibrato, whose worker tokens also borrow the sentence and the
dictionary instead of allocating strings. Add `--owned` (`--full --owned`) to
measure the owned `Vec<Token>` API, which allocates two strings per token.

### Yokohama Ordinance Text Benchmark

To reproduce the long-text comparison used for the Yokohama City tax ordinance, download the HTML, extract normalized visible text, and run the dedicated example:

```bash
mkdir -p target/yokohama
curl -L \
  https://cgi.city.yokohama.lg.jp/somu/reiki/reiki_honbun/g202RG00000570.html \
  -o target/yokohama/g202RG00000570.html
python3 scripts/extract_yokohama_reiki_text.py \
  target/yokohama/g202RG00000570.html \
  target/yokohama/g202RG00000570.txt
YOKOHAMA_TEXT="$PWD/target/yokohama/g202RG00000570.txt" \
YOKOHAMA_BENCH_WARMUP=5 \
YOKOHAMA_BENCH_ITERATIONS=50 \
ZIG_RAW_DIC_DIR=/path/to/raw-ipadic \
VIBRATO_SYSTEM_DIC=/path/to/system.dic.zst \
  cargo run -p delarocha --release --features 'zig-ffi vibrato-bench' --example yokohama_text_bench
```

The example prints per-iteration wall-clock time and token count for `delarocha/binary-count-only`, `delarocha/raw-count-only`, and `vibrato/system-dic` on the same extracted text.

## Memory Comparison

The Rust example below reports RSS after dictionary load and after repeated tokenization for the fixture dictionary.

```bash
cargo run -p delarocha --release --features 'zig-ffi vibrato-bench' --example memory -- delarocha-zig
cargo run -p delarocha --release --features 'zig-ffi vibrato-bench' --example memory -- vibrato
cargo run -p delarocha --release --features 'zig-ffi vibrato-bench' --example memory -- delarocha-rust
```

For ipadic-scale dictionaries, set the dictionary paths and use the system dictionary modes:

```bash
ZIG_RAW_DIC_DIR=/path/to/raw-ipadic \
  cargo run -p delarocha --release --features 'zig-ffi vibrato-bench' --example memory -- delarocha-zig-ipadic-raw
ZIG_RAW_DIC_DIR=/path/to/raw-ipadic \
  cargo run -p delarocha --release --features 'zig-ffi vibrato-bench' --example memory -- delarocha-zig-ipadic-binary
VIBRATO_SYSTEM_DIC=/path/to/system.dic.zst \
  cargo run -p delarocha --release --features 'zig-ffi vibrato-bench' --example memory -- vibrato-system
```

## License

Licensed under either of [Apache License, Version 2.0](LICENSE-APACHE) or
[MIT license](LICENSE-MIT) at your option.
