//! Pins the observable behavior of `ZigWorker::tokenize_borrowed_views` and
//! `ZigTokenViews` against independently derived expectations: the owned
//! `tokenize` output, per-index feature lookups (`token_feature`), and
//! character offsets recomputed from the input with `str::chars`.
#![cfg(feature = "zig-ffi")]

use std::path::{Path, PathBuf};

use delarocha::Token;
use delarocha::ffi::{ZigTokenView, ZigTokenViews, ZigTokenizer, ZigWorker};

fn fixture_dir() -> PathBuf {
    Path::new(env!("CARGO_MANIFEST_DIR")).join("../../fixtures")
}

fn raw_fixture_tokenizer() -> ZigTokenizer {
    let dir = fixture_dir();
    ZigTokenizer::from_raw_paths(
        dir.join("lex.csv"),
        dir.join("matrix.def"),
        dir.join("char.def"),
        dir.join("unk.def"),
    )
    .expect("Zig tokenizer loads raw fixture")
}

/// Raw, mmap'd binary, and copied binary tokenizers for the minimal fixture,
/// plus the same three for a lexicon whose MeCab-style features select the
/// compact feature encoding (decoded per worker) and that contains one
/// invalid-UTF-8 feature.
fn all_tokenizers(dir: &Path) -> Vec<(&'static str, ZigTokenizer)> {
    let fixtures = fixture_dir();
    let binary_path = dir.join("fixture.dic");
    ZigTokenizer::write_binary_from_raw_paths(
        fixtures.join("lex.csv"),
        fixtures.join("matrix.def"),
        fixtures.join("char.def"),
        fixtures.join("unk.def"),
        &binary_path,
    )
    .expect("Zig writes binary fixture");
    let bytes = std::fs::read(&binary_path).expect("read binary fixture");

    let lex_path = dir.join("compact-lex.csv");
    let compact_path = dir.join("compact.dic");
    let mut lexicon = std::fs::read(fixtures.join("lex.csv")).expect("read fixture lexicon");
    for index in 0..40 {
        lexicon.extend_from_slice(
            format!("語{index},0,0,10,名詞,一般,*,*,*,*,語{index},ゴ{index},ゴ{index}\n")
                .as_bytes(),
        );
        lexicon.extend_from_slice(
            format!(
                "ご{index},0,0,12,動詞,自立,*,*,五段・ラ行,基本形,ご{index}る,ゴ{index},ゴー{index}\n"
            )
            .as_bytes(),
        );
    }
    lexicon.extend_from_slice("不正,0,0,1,名詞,一般,*,*,*,*,不正,フセイ,".as_bytes());
    lexicon.extend_from_slice(b"\xff\n");
    lexicon.extend_from_slice(b"\xe8\xaa\x9e,0,0,1,bad-\xff-feature\n");
    std::fs::write(&lex_path, lexicon).expect("write compact lexicon");
    ZigTokenizer::write_binary_from_raw_paths(
        &lex_path,
        fixtures.join("matrix.def"),
        fixtures.join("char.def"),
        fixtures.join("unk.def"),
        &compact_path,
    )
    .expect("Zig writes compact binary");
    let compact_bytes = std::fs::read(&compact_path).expect("read compact binary");

    vec![
        ("raw", raw_fixture_tokenizer()),
        (
            "mmap",
            ZigTokenizer::from_binary_path(&binary_path).expect("mmap binary"),
        ),
        (
            "bytes",
            ZigTokenizer::from_binary_bytes(&bytes).expect("copy binary"),
        ),
        (
            "compact-raw",
            ZigTokenizer::from_raw_paths(
                &lex_path,
                fixtures.join("matrix.def"),
                fixtures.join("char.def"),
                fixtures.join("unk.def"),
            )
            .expect("raw compact lexicon"),
        ),
        (
            "compact-mmap",
            ZigTokenizer::from_binary_path(&compact_path).expect("mmap compact"),
        ),
        (
            "compact-bytes",
            ZigTokenizer::from_binary_bytes(&compact_bytes).expect("copy compact"),
        ),
    ]
}

const FIXED_INPUTS: &[&str] = &[
    "",
    "本とカレー",
    "本X🍛カレー",
    "🍛",
    "🍛🍛本🍛",
    "本\0カレー",
    " 本 と ",
    "カレー本と本とカレー",
    "abc 123\nXYZ",
    "語1語22ご7ご39XYZ",
    "ご0語0不正ご0",
    "本語カレー",
    "語",
    "本とカレー🍛語39",
];

/// Expected tokens derived without the view code path: spans and word ids
/// from the owned API, features from per-index `token_feature` lookups, and
/// character offsets recounted from the input.
fn expected_tokens(worker: &mut ZigWorker<'_>, input: &str) -> Vec<Token> {
    let owned = worker.tokenize(input).expect("owned tokenize");
    let count = worker.tokenize_raw(input).expect("raw tokenize");
    assert_eq!(count, owned.len(), "{input:?}");
    let mut previous_end = 0;
    for (index, token) in owned.iter().enumerate() {
        assert!(previous_end <= token.start && token.start <= token.end);
        assert_eq!(&input[token.start..token.end], token.surface, "{input:?}");
        assert_eq!(
            token.start_char,
            input[..token.start].chars().count(),
            "{input:?}"
        );
        assert_eq!(
            token.end_char,
            input[..token.end].chars().count(),
            "{input:?}"
        );
        assert_eq!(worker.token_feature(index), token.feature, "{input:?}");
        assert_eq!(token.total_cost, 0);
        previous_end = token.end;
    }
    owned
}

fn assert_view_matches(view: &ZigTokenView<'_>, token: &Token, context: &str) {
    // Public fields.
    assert_eq!(view.surface, token.surface, "{context}");
    assert_eq!(view.feature, token.feature, "{context}");
    assert_eq!(view.start, token.start, "{context}");
    assert_eq!(view.end, token.end, "{context}");
    assert_eq!(view.start_char, token.start_char, "{context}");
    assert_eq!(view.end_char, token.end_char, "{context}");
    assert_eq!(view.word_id, token.word_id, "{context}");
    // Accessors.
    assert_eq!(view.surface(), token.surface(), "{context}");
    assert_eq!(view.feature(), token.feature(), "{context}");
    assert_eq!(view.range_byte(), token.range_byte(), "{context}");
    assert_eq!(view.range_char(), token.range_char(), "{context}");
    assert_eq!(view.word_id(), token.word_id, "{context}");
    assert_eq!(view.is_unknown(), token.is_unknown(), "{context}");
    assert_eq!(&view.to_token(), token, "{context}");
    assert_eq!(&Token::from(view.clone()), token, "{context}");
}

/// Checks every public way of reading `views` against `expected`.
fn assert_views_match(views: ZigTokenViews<'_>, expected: &[Token], input: &str, seed: u64) {
    let context = format!("{input:?}");
    assert_eq!(views.len(), expected.len(), "{context}");
    assert_eq!(views.is_empty(), expected.is_empty(), "{context}");

    // Sequential iteration, including ExactSizeIterator bookkeeping.
    let mut iter = views.iter();
    assert_eq!(iter.len(), expected.len(), "{context}");
    assert_eq!(
        iter.size_hint(),
        (expected.len(), Some(expected.len())),
        "{context}"
    );
    for (index, token) in expected.iter().enumerate() {
        let view = iter.next().expect("iterator yields every token");
        assert_view_matches(&view, token, &format!("{context} iter #{index}"));
        assert_eq!(iter.len(), expected.len() - index - 1, "{context}");
    }
    assert!(iter.next().is_none(), "{context}");
    assert_eq!(iter.len(), 0);

    // Iterator adapters see the same order.
    let collected: Vec<Token> = views.iter().map(Token::from).collect();
    assert_eq!(collected, expected, "{context}");
    assert_eq!(views.iter().count(), expected.len(), "{context}");
    if let Some(last) = expected.last() {
        assert_eq!(
            views.iter().last().map(|view| view.to_token()).as_ref(),
            Some(last)
        );
    }
    let skipped: Vec<Token> = views.iter().skip(1).map(Token::from).collect();
    assert_eq!(
        skipped,
        expected.iter().skip(1).cloned().collect::<Vec<_>>()
    );

    // Sequential, reverse and pseudo-random `get`.
    for (index, token) in expected.iter().enumerate() {
        let view = views.get(index).expect("view exists");
        assert_view_matches(&view, token, &format!("{context} get #{index}"));
    }
    for (index, token) in expected.iter().enumerate().rev() {
        let view = views.get(index).expect("view exists");
        assert_view_matches(&view, token, &format!("{context} rev get #{index}"));
    }
    if !expected.is_empty() {
        let mut rng = XorShift64(seed ^ 0x5151_7272_9393_a4a4);
        for _ in 0..(expected.len() * 2).min(256) {
            let index = (rng.next() % expected.len() as u64) as usize;
            let view = views.get(index).expect("view exists");
            assert_view_matches(&view, &expected[index], &format!("{context} rand #{index}"));
        }
    }
    assert!(views.get(expected.len()).is_none(), "{context}");
    assert!(views.get(usize::MAX).is_none(), "{context}");

    // Interleaved iterators and `get` calls do not disturb each other, and
    // the views handle is `Copy`.
    let copy = views;
    let pairs: Vec<(Token, Token)> = views
        .iter()
        .zip(copy.iter())
        .map(|(a, b)| (a.to_token(), b.to_token()))
        .collect();
    for (index, (a, b)) in pairs.iter().enumerate() {
        assert_eq!(a, &expected[index]);
        assert_eq!(b, &expected[index]);
    }
    let mut forward = views.iter();
    for (index, token) in expected.iter().enumerate() {
        let back = expected.len() - 1 - index;
        let from_get = views.get(back).expect("view exists");
        assert_view_matches(&from_get, &expected[back], &context);
        let from_iter = forward.next().expect("iterator yields every token");
        assert_view_matches(&from_iter, token, &context);
    }
}

#[test]
fn borrowed_views_match_independent_expectations_on_fixed_and_fuzz_inputs() {
    let temp_dir = tempfile::tempdir().expect("create temp dir");
    for (name, tokenizer) in all_tokenizers(temp_dir.path()) {
        let mut worker = tokenizer.create_worker().expect("worker");
        let inputs = FIXED_INPUTS
            .iter()
            .map(|input| input.to_string())
            .chain((0..fuzz_seed_count()).map(|seed| fuzz_string(seed, fuzz_max_len())));
        for (seed, input) in inputs.enumerate() {
            let expected = expected_tokens(&mut worker, &input);
            let views = worker
                .tokenize_borrowed_views(&input)
                .unwrap_or_else(|err| panic!("{name}: views for {input:?}: {err}"));
            assert_views_match(views, &expected, &input, seed as u64);

            let vec_views = worker.tokenize_views(&input).expect("tokenize_views");
            assert_eq!(vec_views.len(), expected.len());
            for (view, token) in vec_views.iter().zip(&expected) {
                assert_view_matches(view, token, &format!("{name} {input:?}"));
            }
        }
    }
}

#[test]
fn borrowed_views_on_long_inputs_with_emoji_and_unknown_words() {
    let temp_dir = tempfile::tempdir().expect("create temp dir");
    let long = "本とカレー 本X🍛カレー 東京に行く。abc 123\n語7ご3不正🍛🍛\n".repeat(512);
    for (name, tokenizer) in all_tokenizers(temp_dir.path()) {
        let mut worker = tokenizer.create_worker().expect("worker");
        let expected = expected_tokens(&mut worker, &long);
        assert!(expected.iter().any(|token| token.is_unknown()), "{name}");
        assert!(expected.iter().any(|token| !token.is_unknown()), "{name}");
        assert!(
            expected
                .iter()
                .any(|token| token.surface.contains('🍛') && token.end - token.start >= 4),
            "{name}"
        );
        let views = worker.tokenize_borrowed_views(&long).expect("views");
        assert_views_match(views, &expected, &long[..64], 7);
    }
}

#[test]
fn borrowed_views_fall_back_to_empty_feature_for_invalid_utf8() {
    let temp_dir = tempfile::tempdir().expect("create temp dir");
    for (name, tokenizer) in all_tokenizers(temp_dir.path())
        .into_iter()
        .filter(|(name, _)| name.starts_with("compact"))
    {
        let mut worker = tokenizer.create_worker().expect("worker");
        // Several rounds so later rounds hit the per-word-id UTF-8 memo, and
        // random access first so the memo is filled out of order.
        for round in 0..3 {
            for input in ["本語カレー", "不正", "語ご1不正語語", "語"] {
                let expected = expected_tokens(&mut worker, input);
                let bad: Vec<_> = expected
                    .iter()
                    .filter(|token| token.surface == "語" || token.surface == "不正")
                    .collect();
                assert!(!bad.is_empty(), "{name} {input:?}");
                assert!(bad.iter().all(|token| token.feature.is_empty()));
                let views = worker.tokenize_borrowed_views(input).expect("views");
                if round == 0 {
                    for index in (0..views.len()).rev() {
                        let view = views.get(index).expect("view");
                        assert_view_matches(&view, &expected[index], input);
                    }
                }
                assert_views_match(views, &expected, input, round);
            }
        }
    }
}

#[test]
fn borrowed_views_empty_input() {
    let tokenizer = raw_fixture_tokenizer();
    let mut worker = tokenizer.create_worker().expect("worker");
    // Before and after a non-empty sentence.
    for input in ["", "本とカレー", ""] {
        let views = worker.tokenize_borrowed_views(input).expect("views");
        if input.is_empty() {
            assert_eq!(views.len(), 0);
            assert!(views.is_empty());
            assert!(views.get(0).is_none());
            assert_eq!(views.iter().len(), 0);
            assert!(views.iter().next().is_none());
        } else {
            assert_eq!(views.len(), 2);
        }
    }
}

#[test]
fn borrowed_views_survive_worker_reuse_and_capacity_limits() {
    let temp_dir = tempfile::tempdir().expect("create temp dir");
    let long = "語1語22ご7ご39XYZ本とカレー🍛".repeat(300);
    let inputs = [
        "本とカレー",
        long.as_str(),
        "",
        "ご0語0不正ご0",
        long.as_str(),
        "🍛",
    ];
    for (name, tokenizer) in all_tokenizers(temp_dir.path()) {
        let mut reference = tokenizer.create_worker().expect("worker");
        let expected: Vec<Vec<Token>> = inputs
            .iter()
            .map(|input| expected_tokens(&mut reference, input))
            .collect();

        for limit in [None, Some(0), Some(512), Some(64 * 1024)] {
            let mut worker = tokenizer.create_worker().expect("worker");
            worker.set_retained_capacity_limit(limit);
            let mut kept = Vec::new();
            for (seed, (input, expected)) in inputs.iter().zip(&expected).enumerate() {
                let views = worker.tokenize_borrowed_views(input).expect("views");
                // Length first (no token data read), then everything.
                assert_eq!(views.len(), expected.len(), "{name} {limit:?}");
                assert_views_match(views, expected, input, seed as u64);
                kept.push(views.iter().map(Token::from).collect::<Vec<_>>());

                // Other worker calls in between must not leak into the next
                // views.
                worker.tokenize_spans(input).expect("spans");
                worker.tokenize_count(input).expect("count");
                worker.tokenize_raw("本").expect("raw");
            }
            worker.shrink_to_fit();
            let views = worker.tokenize_borrowed_views(&long).expect("views");
            assert_views_match(views, &expected[1], &long, 11);
            // Owned copies taken from earlier views are unaffected by reuse.
            assert_eq!(kept, expected, "{name} {limit:?}");
        }
    }
}

fn fuzz_seed_count() -> u64 {
    std::env::var("DELAROCHA_FUZZ_SEEDS")
        .ok()
        .and_then(|value| value.parse().ok())
        .unwrap_or(256)
}

fn fuzz_max_len() -> usize {
    std::env::var("DELAROCHA_FUZZ_MAX_LEN")
        .ok()
        .and_then(|value| value.parse().ok())
        .unwrap_or(80)
}

fn fuzz_string(seed: u64, max_len: usize) -> String {
    const POOL: &[char] = &[
        '本', 'と', 'カ', 'レ', 'ー', '東', '京', 'に', '行', 'く', '0', '1', 'a', ' ', '\n', '。',
        'X', '🍛', '語', 'ご', '不', '正', '\0', 'é',
    ];
    let mut rng = XorShift64(seed.wrapping_mul(0x9e37_79b9_7f4a_7c15) ^ 0x0bad_cafe_dead_beef);
    let len = if max_len == 0 {
        0
    } else {
        (rng.next() % max_len as u64) as usize
    };
    (0..len)
        .map(|_| POOL[(rng.next() as usize) % POOL.len()])
        .collect()
}

struct XorShift64(u64);

impl XorShift64 {
    fn next(&mut self) -> u64 {
        let mut x = self.0.max(1);
        x ^= x << 13;
        x ^= x >> 7;
        x ^= x << 17;
        self.0 = x;
        x
    }
}
