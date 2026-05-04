# delarocha

[![CI](https://github.com/bokuweb/delarocha/actions/workflows/ci.yml/badge.svg)](https://github.com/bokuweb/delarocha/actions/workflows/ci.yml)

- runtime dictionary loader
- `Tokenizer` / reusable `Worker`
- AoS nodes
- dense row-major connection matrix
- minimal unknown word handling
- C ABI for Rust bindings
- `cargo bench` harness for comparison with Vibrato

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

Set `DELAROCHA_BUILD_ZIG=1` to rebuild the static library from
`zig/src/lib.zig`. Unsupported targets also fall back to building from Zig
sources, so those environments still need Zig installed.

```bash
cargo test -p delarocha --features zig-ffi
```

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
