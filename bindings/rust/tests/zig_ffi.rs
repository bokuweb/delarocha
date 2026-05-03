#![cfg(feature = "zig-ffi")]

use delarocha::ffi::{ZigBatch, ZigTokenizer};

#[test]
fn zig_ffi_tokenizes_fixture_dictionary() {
    let dict_path =
        std::path::Path::new(env!("CARGO_MANIFEST_DIR")).join("../../fixtures/minimal.dict");
    let tokenizer = ZigTokenizer::from_path(dict_path).expect("Zig tokenizer loads fixture");
    let mut worker = tokenizer.create_worker().expect("Zig worker is created");

    let tokens = worker
        .tokenize("本とカレー")
        .expect("Zig tokenize succeeds");

    assert_eq!(
        tokens
            .iter()
            .map(|token| token.surface.as_str())
            .collect::<Vec<_>>(),
        ["本と", "カレー"]
    );
    assert_eq!(tokens[0].byte_range(), 0..6);
    assert_eq!(tokens[1].byte_range(), 6..15);
}

#[test]
fn zig_ffi_tokenizes_raw_dictionary() {
    let fixture_dir = std::path::Path::new(env!("CARGO_MANIFEST_DIR")).join("../../fixtures");
    let tokenizer = ZigTokenizer::from_raw_paths(
        fixture_dir.join("lex.csv"),
        fixture_dir.join("matrix.def"),
        fixture_dir.join("char.def"),
        fixture_dir.join("unk.def"),
    )
    .expect("Zig tokenizer loads raw fixture");
    let mut worker = tokenizer.create_worker().expect("Zig worker is created");

    let tokens = worker
        .tokenize("本とカレー")
        .expect("Zig tokenize succeeds");

    assert_eq!(
        tokens
            .iter()
            .map(|token| token.surface.as_str())
            .collect::<Vec<_>>(),
        ["本と", "カレー"]
    );
    assert_eq!(worker.tokenize_count("本とカレー").unwrap(), 2);
    let batch = ZigBatch::new(&["本とカレー", "本X🍛カレー"]);
    assert_eq!(worker.tokenize_count_batch(&batch).unwrap(), 4);
}

#[test]
fn zig_ffi_writes_and_reads_binary_dictionary() {
    let fixture_dir = std::path::Path::new(env!("CARGO_MANIFEST_DIR")).join("../../fixtures");
    let temp_dir = tempfile::tempdir().expect("create temp dir");
    let binary_path = temp_dir.path().join("fixture.dic");

    ZigTokenizer::write_binary_from_raw_paths(
        fixture_dir.join("lex.csv"),
        fixture_dir.join("matrix.def"),
        fixture_dir.join("char.def"),
        fixture_dir.join("unk.def"),
        &binary_path,
    )
    .expect("Zig writes binary dictionary");
    let tokenizer =
        ZigTokenizer::from_binary_path(&binary_path).expect("Zig tokenizer loads binary fixture");
    let mut worker = tokenizer.create_worker().expect("Zig worker is created");

    assert_eq!(worker.tokenize_count("本とカレー").unwrap(), 2);
}

#[test]
fn zig_ffi_count_only_matches_full_count() {
    let fixture_dir = std::path::Path::new(env!("CARGO_MANIFEST_DIR")).join("../../fixtures");
    let temp_dir = tempfile::tempdir().expect("create temp dir");
    let binary_path = temp_dir.path().join("fixture.dic");

    ZigTokenizer::write_binary_from_raw_paths(
        fixture_dir.join("lex.csv"),
        fixture_dir.join("matrix.def"),
        fixture_dir.join("char.def"),
        fixture_dir.join("unk.def"),
        &binary_path,
    )
    .expect("Zig writes binary dictionary");

    let full = ZigTokenizer::from_binary_path(&binary_path).expect("Zig loads full binary");
    let count_only = ZigTokenizer::count_only_from_binary_path(&binary_path)
        .expect("Zig loads count-only binary");
    let mut full_worker = full.create_worker().expect("full worker is created");
    let mut count_worker = count_only
        .create_worker()
        .expect("count-only worker is created");

    for sentence in ["本とカレー", "本X🍛カレー", "カレー本と本とカレー"] {
        assert_eq!(
            count_worker.tokenize_count(sentence).unwrap(),
            full_worker.tokenize_count(sentence).unwrap()
        );
    }
}

#[test]
fn zig_ffi_copies_token_spans_in_bulk() {
    let fixture_dir = std::path::Path::new(env!("CARGO_MANIFEST_DIR")).join("../../fixtures");
    let tokenizer = ZigTokenizer::from_raw_paths(
        fixture_dir.join("lex.csv"),
        fixture_dir.join("matrix.def"),
        fixture_dir.join("char.def"),
        fixture_dir.join("unk.def"),
    )
    .expect("Zig tokenizer loads raw fixture");
    let mut worker = tokenizer.create_worker().expect("Zig worker is created");

    let spans = worker
        .tokenize_spans("本とカレー")
        .expect("Zig tokenize spans succeeds");

    assert_eq!(spans.len(), 2);
    assert_eq!(spans[0].start..spans[0].end, 0..6);
    assert_eq!(spans[1].start..spans[1].end, 6..15);
    assert_eq!(spans[0].word_id, 3);
    assert_eq!(spans[1].word_id, 2);
}

#[test]
fn zig_ffi_seeded_fuzz_count_only_matches_full_tokenization() {
    let fixture_dir = std::path::Path::new(env!("CARGO_MANIFEST_DIR")).join("../../fixtures");
    let temp_dir = tempfile::tempdir().expect("create temp dir");
    let binary_path = temp_dir.path().join("fixture.dic");

    ZigTokenizer::write_binary_from_raw_paths(
        fixture_dir.join("lex.csv"),
        fixture_dir.join("matrix.def"),
        fixture_dir.join("char.def"),
        fixture_dir.join("unk.def"),
        &binary_path,
    )
    .expect("Zig writes binary dictionary");

    let full = ZigTokenizer::from_binary_path(&binary_path).expect("Zig loads full binary");
    let count_only = ZigTokenizer::count_only_from_binary_path(&binary_path)
        .expect("Zig loads count-only binary");
    let mut full_worker = full.create_worker().expect("full worker is created");
    let mut count_worker = count_only
        .create_worker()
        .expect("count-only worker is created");

    for seed in 0..512 {
        let input = fuzz_string(seed);
        let spans = full_worker.tokenize_spans(&input).unwrap_or_else(|err| {
            panic!("full tokenization succeeds for seed {seed}: {input:?}: {err}")
        });
        let count = count_worker.tokenize_count(&input).unwrap_or_else(|err| {
            panic!("count-only tokenization succeeds for seed {seed}: {input:?}: {err}")
        });
        assert_eq!(
            count,
            spans.len(),
            "count-only path must match full tokenization for seed {seed}: {input:?}"
        );
    }
}

fn fuzz_string(seed: u64) -> String {
    const POOL: &[char] = &[
        '本', 'と', 'カ', 'レ', 'ー', '東', '京', '都', 'に', '行', 'く', '0', '1', 'a', ' ', '\n',
        '。', 'X', '🍛',
    ];

    let mut rng = XorShift64(seed.wrapping_mul(0x9e37_79b9_7f4a_7c15) ^ 0x1234_abcd_55aa_aa55);
    let len = (rng.next() % 80) as usize;
    let mut out = String::new();
    for _ in 0..len {
        out.push(POOL[(rng.next() as usize) % POOL.len()]);
    }
    out
}

struct XorShift64(u64);

impl XorShift64 {
    fn next(&mut self) -> u64 {
        let mut x = self.0;
        x ^= x << 13;
        x ^= x >> 7;
        x ^= x << 17;
        self.0 = x;
        x
    }
}
