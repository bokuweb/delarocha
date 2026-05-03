# delarocha

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

## Rust Tests

```bash
cargo test
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

The `zig-ffi` feature compiles `zig/src/lib.zig` into a static library from `bindings/rust/build.rs`.

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

## Memory Comparison

The Rust example below reports RSS after dictionary load and after repeated tokenization for the fixture dictionary.

```bash
cargo run -p delarocha --release --features 'zig-ffi vibrato-bench' --example memory -- delarocha-zig
cargo run -p delarocha --release --features 'zig-ffi vibrato-bench' --example memory -- vibrato
cargo run -p delarocha --release --features 'zig-ffi vibrato-bench' --example memory -- delarocha-rust
```
