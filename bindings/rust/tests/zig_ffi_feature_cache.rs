//! Pins feature bytes for dictionaries with compact (format v4) features
//! across decode-cache pressure: every entry of a generated lexicon whose
//! decoded features exceed the per-worker decode cache, repeated and distinct
//! words, several workers and threads on one tokenizer, deferred feature
//! resolution, and the shrink / retained-capacity APIs.
#![cfg(feature = "zig-ffi")]

use std::collections::HashMap;

use delarocha::Token;
use delarocha::ffi::{ZigTokenizer, ZigWorker};

// Characters of the generated three-character surfaces: hiragana (rendered
// as katakana in readings), katakana and kanji, all three bytes in UTF-8.
const CHARS: &[&str] = &[
    "あ", "い", "う", "え", "お", "か", "き", "く", "け", "こ", "さ", "し", "す", "せ", "そ", "た",
    "ち", "つ", "て", "と", "な", "に", "ぬ", "ね", "の", "は", "ひ", "ふ", "ア", "イ", "ウ", "エ",
    "オ", "本", "語", "猫", "犬", "山", "川", "空",
];

// Enough entries that their decoded features (about 1.6 MB) exceed the
// per-worker decode cache limit (1 MiB) several times over a pass.
const ENTRY_COUNT: usize = 24_000;
const INVALID_ENTRY: usize = 7;
// One shared arena chunk (256 KiB), well below the decoded total.
const SMALL_SHARED_LIMIT: usize = 256 << 10;

struct Fixture {
    _dir: tempfile::TempDir,
    lex: std::path::PathBuf,
    matrix: std::path::PathBuf,
    char_def: std::path::PathBuf,
    unk: std::path::PathBuf,
    binary: std::path::PathBuf,
    /// Surface -> expected feature (`""` for the invalid UTF-8 entry).
    features: HashMap<String, String>,
    surfaces: Vec<String>,
    lines: Vec<String>,
}

fn katakana(text: &str) -> String {
    text.chars()
        .map(|ch| match ch {
            '\u{3041}'..='\u{3096}' => char::from_u32(ch as u32 + 0x60).unwrap(),
            other => other,
        })
        .collect()
}

/// Distinct three-character surfaces, so a concatenation of surfaces
/// tokenizes into exactly those entries, with MeCab-style features of several
/// shapes (surface, katakana and column references, long literals, short
/// rows, one invalid UTF-8 literal) that select the compact encoding.
fn fixture() -> Fixture {
    let dir = tempfile::tempdir().expect("temp dir");
    let n = CHARS.len();
    let mut lex = Vec::new();
    let mut features = HashMap::new();
    let mut surfaces = Vec::new();
    for i in 0..ENTRY_COUNT {
        let surface = format!(
            "{}{}{}",
            CHARS[i % n],
            CHARS[(i / n) % n],
            CHARS[i / (n * n)]
        );
        let kana = katakana(&surface);
        let feature = match i % 6 {
            0 => format!("名詞,一般,*,*,*,*,{surface},{kana},{kana}"),
            1 => format!("動詞,自立,*,*,五段・ラ行,基本形,{surface}る,{kana},{kana}ー"),
            2 => format!("名詞,固有名詞,人名,姓,*,*,{surface},{kana}{i},{kana}{i}"),
            3 => format!("記号,{i}"),
            4 => format!(
                "副詞,一般,*,*,*,*,{surface},{kana},{kana},長い説明文その{i}は特徴列の長さを稼ぐためのものです"
            ),
            _ => format!(
                "名詞,サ変接続,*,*,*,*,{},{kana},{}",
                &surface[..3],
                &kana[3..]
            ),
        };
        lex.extend_from_slice(format!("{surface},0,0,{},{feature}", 10 + i % 7).as_bytes());
        if i == INVALID_ENTRY {
            lex.push(0xff);
            features.insert(surface.clone(), String::new());
        } else {
            features.insert(surface.clone(), feature);
        }
        lex.push(b'\n');
        surfaces.push(surface);
    }
    let paths = (
        dir.path().join("lex.csv"),
        dir.path().join("matrix.def"),
        dir.path().join("char.def"),
        dir.path().join("unk.def"),
        dir.path().join("compact.dic"),
    );
    std::fs::write(&paths.0, lex).expect("write lexicon");
    std::fs::write(&paths.1, "1 1\n0 0 0\n").expect("write matrix");
    std::fs::write(
        &paths.2,
        "DEFAULT 0 1 0\nALPHA 1 1 0\n0x0041..0x005A ALPHA\n",
    )
    .expect("write char.def");
    std::fs::write(&paths.3, "DEFAULT,0,0,30000,*\nALPHA,0,0,10,alpha\n").expect("write unk.def");
    ZigTokenizer::write_binary_from_raw_paths(&paths.0, &paths.1, &paths.2, &paths.3, &paths.4)
        .expect("write binary dictionary");
    let lines = lines(&surfaces);
    Fixture {
        _dir: dir,
        lex: paths.0,
        matrix: paths.1,
        char_def: paths.2,
        unk: paths.3,
        binary: paths.4,
        features,
        surfaces,
        lines,
    }
}

/// Runs of consecutive entries (some followed by an unknown word), one
/// entry repeated, and a strided sweep revisiting every entry.
fn lines(surfaces: &[String]) -> Vec<String> {
    let mut lines = Vec::new();
    let mut seed = 0x5eed_u64;
    let mut next = move || {
        seed = seed
            .wrapping_mul(6364136223846793005)
            .wrapping_add(1442695040888963407);
        (seed >> 33) as usize
    };
    let mut start = 0;
    while start < surfaces.len() {
        let len = (1 + next() % 40).min(surfaces.len() - start);
        let mut line = surfaces[start..start + len].concat();
        if len % 5 == 0 {
            line.push_str("ABC");
        }
        lines.push(line);
        start += len;
    }
    lines.push(surfaces[3].repeat(200));
    let mut line = String::new();
    let mut index = 0;
    for _ in 0..surfaces.len() {
        line.push_str(&surfaces[index]);
        index = (index + 7919) % surfaces.len();
        if line.len() > 300 {
            lines.push(std::mem::take(&mut line));
        }
    }
    lines.push(line);
    lines.push(String::new());
    lines
}

impl Fixture {
    fn raw_tokenizer(&self) -> ZigTokenizer {
        ZigTokenizer::from_raw_paths(&self.lex, &self.matrix, &self.char_def, &self.unk)
            .expect("raw tokenizer")
    }

    fn compact_tokenizers(&self) -> Vec<(&'static str, ZigTokenizer)> {
        let bytes = std::fs::read(&self.binary).expect("read binary");
        assert_eq!(&bytes[..8], b"DLRDIC04");
        // Header field 17 (feature encoding) is 1 for compact features.
        assert_eq!(
            u32::from_le_bytes(bytes[8 + 4 * 17..8 + 4 * 18].try_into().unwrap()),
            1,
            "the generated lexicon must select compact features"
        );
        let limited = |limit: usize, mut tokenizer: ZigTokenizer| {
            tokenizer.set_shared_feature_limit(limit);
            tokenizer
        };
        vec![
            (
                "mmap",
                ZigTokenizer::from_binary_path(&self.binary).expect("mmap binary"),
            ),
            (
                "bytes",
                ZigTokenizer::from_binary_bytes(&bytes).expect("copy binary"),
            ),
            // No sharing: every worker decodes through its own bounded cache.
            (
                "unshared",
                limited(
                    0,
                    ZigTokenizer::from_binary_path(&self.binary).expect("mmap binary"),
                ),
            ),
            // Room for part of the features: the rest use the worker caches.
            (
                "small-shared",
                limited(
                    SMALL_SHARED_LIMIT,
                    ZigTokenizer::from_binary_bytes(&bytes).expect("copy binary"),
                ),
            ),
        ]
    }

    /// Expected tokens per line, from the raw-lexicon tokenizer (verbatim
    /// features), checked against the generated lexicon.
    fn expected(&self) -> Vec<Vec<Token>> {
        let raw = self.raw_tokenizer();
        let mut worker = raw.create_worker().expect("raw worker");
        self.lines
            .iter()
            .map(|line| {
                let tokens = worker.tokenize(line).expect("raw tokenize");
                let mut end = 0;
                for token in &tokens {
                    assert_eq!(token.start, end);
                    end = token.end;
                    let expected = if token.is_unknown() {
                        "alpha"
                    } else {
                        &self.features[&token.surface]
                    };
                    assert_eq!(token.feature, expected, "{line:?}");
                }
                assert_eq!(end, line.len());
                tokens
            })
            .collect()
    }
}

fn views_as_tokens(worker: &mut ZigWorker<'_>, line: &str) -> Vec<Token> {
    worker
        .tokenize_borrowed_views(line)
        .expect("views")
        .iter()
        .map(|view| view.to_token())
        .collect()
}

fn spans_and_features(worker: &mut ZigWorker<'_>, line: &str) -> Vec<(usize, usize, u32, String)> {
    let count = worker.tokenize_raw(line).expect("tokenize_raw");
    let (mut starts, mut ends, mut ids) = (vec![0; count], vec![0; count], vec![0; count]);
    let copied = worker
        .copy_token_spans(&mut starts, &mut ends, &mut ids)
        .expect("copy spans");
    assert_eq!(copied, count);
    (0..count)
        .map(|index| {
            (
                starts[index],
                ends[index],
                ids[index],
                worker.token_feature(index).to_owned(),
            )
        })
        .collect()
}

fn expected_spans(tokens: &[Token]) -> Vec<(usize, usize, u32, String)> {
    tokens
        .iter()
        .map(|token| (token.start, token.end, token.word_id, token.feature.clone()))
        .collect()
}

#[test]
fn every_entry_feature_matches_the_lexicon() {
    let fixture = fixture();
    let expected = fixture.expected();
    let mut seen: Vec<bool> = vec![false; fixture.surfaces.len()];
    for tokens in &expected {
        for token in tokens.iter().filter(|token| !token.is_unknown()) {
            seen[token.word_id as usize] = true;
            assert_eq!(fixture.surfaces[token.word_id as usize], token.surface);
        }
    }
    assert!(seen.iter().all(|&seen| seen), "every entry is tokenized");
    assert_eq!(fixture.features[&fixture.surfaces[INVALID_ENTRY]], "");
    assert_eq!(fixture.raw_tokenizer().shared_feature_bytes(), 0);

    for (name, tokenizer) in fixture.compact_tokenizers() {
        let mut owned = tokenizer.create_worker().expect("worker");
        let mut views = tokenizer.create_worker().expect("worker");
        let mut spans = tokenizer.create_worker().expect("worker");
        for pass in 0..2 {
            for (line, expected) in fixture.lines.iter().zip(&expected) {
                assert_eq!(
                    &owned.tokenize(line).expect("tokenize"),
                    expected,
                    "{name} pass {pass}"
                );
                assert_eq!(
                    &views_as_tokens(&mut views, line),
                    expected,
                    "{name} pass {pass}"
                );
                assert_eq!(
                    spans_and_features(&mut spans, line),
                    expected_spans(expected),
                    "{name} pass {pass}"
                );
            }
        }
        // The shared table is tokenizer-level memory, bounded by its limit
        // plus the 4-byte-per-entry index.
        let shared = tokenizer.shared_feature_bytes();
        let index = 4 * ENTRY_COUNT;
        match name {
            "unshared" => assert_eq!(shared, 0),
            "small-shared" => assert!(
                shared > 0 && shared <= SMALL_SHARED_LIMIT + index,
                "{shared}"
            ),
            _ => assert!(
                shared > SMALL_SHARED_LIMIT && shared <= (40 << 20) + index,
                "{shared}"
            ),
        }
    }
}

#[test]
fn feature_paths_agree_under_decode_cache_pressure() {
    let fixture = fixture();
    let expected = fixture.expected();
    // Visit lines in a scrambled order so cache restarts land at different
    // points than in line order.
    let order: Vec<usize> = (0..fixture.lines.len())
        .map(|index| index * 7 % fixture.lines.len())
        .collect();
    for (name, tokenizer) in fixture.compact_tokenizers() {
        let mut owned = tokenizer.create_worker().expect("worker");
        let mut views = tokenizer.create_worker().expect("worker");
        let mut reverse = tokenizer.create_worker().expect("worker");
        let mut lazy = tokenizer.create_worker().expect("worker");
        let mut spans = tokenizer.create_worker().expect("worker");
        let mut capped = tokenizer.create_worker().expect("worker");
        capped.set_retained_capacity_limit(Some(4096));
        let mut roomy = tokenizer.create_worker().expect("worker");
        roomy.set_retained_capacity_limit(Some(2 << 20));
        let mut shrinking = tokenizer.create_worker().expect("worker");
        for pass in 0..2 {
            for (step, &index) in order.iter().enumerate() {
                let (line, expected) = (&fixture.lines[index], &expected[index]);
                let context = format!("{name} pass {pass} line {index}");
                assert_eq!(
                    &owned.tokenize(line).expect("tokenize"),
                    expected,
                    "{context}"
                );
                assert_eq!(&views_as_tokens(&mut views, line), expected, "{context}");

                // Random access from the back resolves features first.
                let got = reverse.tokenize_borrowed_views(line).expect("views");
                for i in (0..got.len()).rev() {
                    assert_eq!(
                        got.get(i).expect("view").to_token(),
                        expected[i],
                        "{context}"
                    );
                }

                // Lines whose features are never read leave them pending
                // until the next call replaces them.
                let pending = lazy.tokenize_borrowed_views(line).expect("views");
                assert_eq!(pending.len(), expected.len());
                if step % 3 == 0 {
                    assert_eq!(&views_as_tokens(&mut lazy, line), expected, "{context}");
                }

                assert_eq!(
                    spans_and_features(&mut spans, line),
                    expected_spans(expected),
                    "{context}"
                );

                for worker in [&mut capped, &mut roomy] {
                    assert_eq!(
                        &worker.tokenize(line).expect("tokenize"),
                        expected,
                        "{context}"
                    );
                    assert_eq!(&views_as_tokens(worker, line), expected, "{context}");
                    assert_eq!(
                        spans_and_features(worker, line),
                        expected_spans(expected),
                        "{context}"
                    );
                }

                assert_eq!(
                    &views_as_tokens(&mut shrinking, line),
                    expected,
                    "{context}"
                );
                match step % 4 {
                    0 => shrinking.shrink_to_fit(),
                    1 => shrinking.shrink_to(step * 131 % (1 << 20)),
                    2 => shrinking.shrink_to(usize::MAX),
                    _ => {}
                }
                assert_eq!(
                    &shrinking.tokenize(line).expect("tokenize"),
                    expected,
                    "{context}"
                );
            }
        }
    }
}

#[test]
fn workers_on_several_threads_share_one_tokenizer() {
    let fixture = fixture();
    let expected = fixture.expected();
    for (name, tokenizer) in fixture.compact_tokenizers() {
        std::thread::scope(|scope| {
            for thread in 0..4 {
                let (tokenizer, fixture, expected) = (&tokenizer, &fixture, &expected);
                scope.spawn(move || {
                    let mut worker = tokenizer.create_worker().expect("worker");
                    let count = fixture.lines.len();
                    for pass in 0..2 {
                        for step in 0..count {
                            // Each thread starts at a different line.
                            let index = (step + thread * count / 4) % count;
                            let line = &fixture.lines[index];
                            let context =
                                format!("{name} thread {thread} pass {pass} line {index}");
                            if (step + thread) % 2 == 0 {
                                assert_eq!(
                                    &views_as_tokens(&mut worker, line),
                                    &expected[index],
                                    "{context}"
                                );
                            } else {
                                assert_eq!(
                                    &worker.tokenize(line).expect("tokenize"),
                                    &expected[index],
                                    "{context}"
                                );
                            }
                        }
                    }
                });
            }
        });
    }
}
