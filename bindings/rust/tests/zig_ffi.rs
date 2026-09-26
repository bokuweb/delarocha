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
    assert_eq!(tokens[0].range_char(), 0..2);
    assert_eq!(tokens[1].range_char(), 2..5);
}

#[test]
fn zig_ffi_full_tokenize_accepts_interior_nul() {
    let dict_path =
        std::path::Path::new(env!("CARGO_MANIFEST_DIR")).join("../../fixtures/minimal.dict");
    let tokenizer = ZigTokenizer::from_path(dict_path).expect("Zig tokenizer loads fixture");
    let mut worker = tokenizer.create_worker().expect("Zig worker is created");

    let tokens = worker
        .tokenize("本\0カレー")
        .expect("Zig bytes tokenize succeeds");

    assert_eq!(
        tokens
            .iter()
            .map(|token| token.surface.as_str())
            .collect::<Vec<_>>(),
        ["本", "\0", "カレー"]
    );
    assert_eq!(tokens[0].range_char(), 0..1);
    assert_eq!(tokens[1].range_char(), 1..2);
    assert_eq!(tokens[2].range_char(), 2..5);
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
fn zig_ffi_reads_binary_dictionary_from_bytes() {
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
    let bytes = std::fs::read(&binary_path).expect("read binary fixture");
    let tokenizer =
        ZigTokenizer::from_binary_bytes(&bytes).expect("Zig tokenizer loads binary bytes");
    let mut worker = tokenizer.create_worker().expect("Zig worker is created");

    assert_eq!(worker.tokenize_count("本とカレー").unwrap(), 2);
}

#[test]
fn zig_ffi_mmap_binary_dictionary_keeps_compact_features() {
    let fixture_dir = std::path::Path::new(env!("CARGO_MANIFEST_DIR")).join("../../fixtures");
    let temp_dir = tempfile::tempdir().expect("create temp dir");
    let lex_path = temp_dir.path().join("lex.csv");
    let binary_path = temp_dir.path().join("compact.dic");
    let mut lexicon = String::new();
    for index in 0..33 {
        lexicon.push_str(&format!("語{index},0,0,10,feature-{index}\n"));
    }
    std::fs::write(&lex_path, lexicon).expect("write large enough lexicon");

    ZigTokenizer::write_binary_from_raw_paths(
        &lex_path,
        fixture_dir.join("matrix.def"),
        fixture_dir.join("char.def"),
        fixture_dir.join("unk.def"),
        &binary_path,
    )
    .expect("Zig writes compact binary dictionary");
    let tokenizer =
        ZigTokenizer::from_binary_path(&binary_path).expect("Zig tokenizer mmaps binary fixture");
    let mut worker = tokenizer.create_worker().expect("Zig worker is created");

    let tokens = worker.tokenize("語32").expect("Zig tokenize succeeds");
    assert_eq!(tokens[0].surface, "語32");
    assert_eq!(tokens[0].feature, "feature-32");
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
fn zig_ffi_returns_zero_copy_token_views() {
    let fixture_dir = std::path::Path::new(env!("CARGO_MANIFEST_DIR")).join("../../fixtures");
    let tokenizer = ZigTokenizer::from_raw_paths(
        fixture_dir.join("lex.csv"),
        fixture_dir.join("matrix.def"),
        fixture_dir.join("char.def"),
        fixture_dir.join("unk.def"),
    )
    .expect("Zig tokenizer loads raw fixture");
    let mut worker = tokenizer.create_worker().expect("Zig worker is created");

    let views = worker
        .tokenize_views("本とカレー")
        .expect("Zig tokenize views succeeds");
    assert_eq!(views.len(), 2);
    assert_eq!(views[0].surface, "本と");
    assert_eq!(views[0].feature, "compound,book-and");
    assert_eq!(views[0].start..views[0].end, 0..6);

    let borrowed = worker
        .tokenize_borrowed_views("本とカレー")
        .expect("Zig borrowed views succeed");
    assert_eq!(borrowed.len(), 2);
    let first = borrowed.get(0).expect("first borrowed token exists");
    assert_eq!(first.surface, "本と");
    assert_eq!(first.feature, "compound,book-and");
    assert_eq!(first.start..first.end, 0..6);
    assert_eq!(borrowed.iter().count(), 2);
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

    for seed in 0..fuzz_seed_count() {
        let input = fuzz_string(seed, fuzz_max_len());
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

fn fuzz_seed_count() -> u64 {
    std::env::var("DELAROCHA_FUZZ_SEEDS")
        .ok()
        .and_then(|value| value.parse().ok())
        .unwrap_or(512)
}

fn fuzz_max_len() -> usize {
    std::env::var("DELAROCHA_FUZZ_MAX_LEN")
        .ok()
        .and_then(|value| value.parse().ok())
        .unwrap_or(80)
}

fn fuzz_string(seed: u64, max_len: usize) -> String {
    const POOL: &[char] = &[
        '本', 'と', 'カ', 'レ', 'ー', '東', '京', '都', 'に', '行', 'く', '0', '1', 'a', ' ', '\n',
        '。', 'X', '🍛',
    ];

    let mut rng = XorShift64(seed.wrapping_mul(0x9e37_79b9_7f4a_7c15) ^ 0x1234_abcd_55aa_aa55);
    // Keep CI deterministic and small by default, while allowing local stress
    // runs to widen the generated input length with DELAROCHA_FUZZ_MAX_LEN.
    let len = if max_len == 0 {
        0
    } else {
        (rng.next() % max_len as u64) as usize
    };
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

fn write_fixture_binary(dir: &std::path::Path) -> Vec<u8> {
    let fixture_dir = std::path::Path::new(env!("CARGO_MANIFEST_DIR")).join("../../fixtures");
    let binary_path = dir.join("fixture.dic");
    ZigTokenizer::write_binary_from_raw_paths(
        fixture_dir.join("lex.csv"),
        fixture_dir.join("matrix.def"),
        fixture_dir.join("char.def"),
        fixture_dir.join("unk.def"),
        &binary_path,
    )
    .expect("Zig writes binary dictionary");
    std::fs::read(&binary_path).expect("read binary fixture")
}

// Loads through both the copying byte loader and the mmap-borrowing path
// loader, which alias the file for the matrix and trie tables.
fn load_binary_both_ways(dir: &std::path::Path, bytes: &[u8]) -> Vec<delarocha::Error> {
    let path = dir.join("corrupt.dic");
    std::fs::write(&path, bytes).expect("write corrupt dictionary");
    vec![
        ZigTokenizer::from_binary_bytes(bytes)
            .err()
            .expect("byte load must fail"),
        ZigTokenizer::from_binary_path(&path)
            .err()
            .expect("mmap load must fail"),
        ZigTokenizer::count_only_from_binary_path(&path)
            .err()
            .expect("count-only load must fail"),
    ]
}

#[test]
fn zig_ffi_rejects_stale_binary_dictionary_version() {
    let temp_dir = tempfile::tempdir().expect("create temp dir");
    let mut bytes = write_fixture_binary(temp_dir.path());
    assert_eq!(&bytes[..8], b"DLRDIC03");
    bytes[..8].copy_from_slice(b"DLRDIC02");
    for err in load_binary_both_ways(temp_dir.path(), &bytes) {
        assert!(
            matches!(&err, delarocha::Error::UnsupportedDictionaryVersion(message) if message.contains("rebuild")),
            "unexpected error: {err}"
        );
    }
}

#[test]
fn zig_ffi_rejects_truncated_binary_dictionary() {
    let temp_dir = tempfile::tempdir().expect("create temp dir");
    let bytes = write_fixture_binary(temp_dir.path());
    for len in [0, 7, 8, 20, bytes.len() / 2, bytes.len() - 1] {
        for err in load_binary_both_ways(temp_dir.path(), &bytes[..len]) {
            assert!(
                matches!(&err, delarocha::Error::InvalidDictionary(message) if message.contains("InvalidDictionary")),
                "unexpected error at len {len}: {err}"
            );
        }
    }
}

#[test]
fn zig_ffi_rejects_out_of_range_connection_id() {
    let temp_dir = tempfile::tempdir().expect("create temp dir");
    let mut bytes = write_fixture_binary(temp_dir.path());
    // Header: magic, then six u32 counts. The first entry record starts with
    // its surface length followed by the u16 left id.
    let left_id_offset = 8 + 6 * 4 + 4;
    bytes[left_id_offset..left_id_offset + 2].copy_from_slice(&u16::MAX.to_le_bytes());
    for err in load_binary_both_ways(temp_dir.path(), &bytes) {
        assert!(
            matches!(err, delarocha::Error::InvalidDictionary(_)),
            "unexpected error: {err}"
        );
    }
}

#[test]
fn zig_ffi_rejects_stale_binary_dictionary_file() {
    // Optional: point this at a DLRDIC02 dictionary built by an older release.
    let Some(path) = std::env::var_os("DELAROCHA_STALE_BINARY_DIC") else {
        return;
    };
    let err = ZigTokenizer::from_binary_path(&path)
        .err()
        .expect("stale dictionary must be rejected");
    assert!(
        matches!(err, delarocha::Error::UnsupportedDictionaryVersion(_)),
        "unexpected error: {err}"
    );
    println!("{err}");
}
