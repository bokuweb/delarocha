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
fn zig_ffi_mmap_count_only_compact_dictionary_and_truncated_files() {
    let fixture_dir = std::path::Path::new(env!("CARGO_MANIFEST_DIR")).join("../../fixtures");
    let temp_dir = tempfile::tempdir().expect("create temp dir");
    let lex_path = temp_dir.path().join("lex.csv");
    let binary_path = temp_dir.path().join("compact.dic");
    let mut lexicon = String::new();
    for index in 0..40 {
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

    let full = ZigTokenizer::from_binary_path(&binary_path).expect("Zig mmaps full binary");
    let count_only =
        ZigTokenizer::count_only_from_binary_path(&binary_path).expect("Zig mmaps count-only");
    let mut full_worker = full.create_worker().expect("full worker is created");
    let mut count_worker = count_only.create_worker().expect("count worker is created");
    for sentence in ["語1語22語39", "語3X🍛語0", ""] {
        assert_eq!(
            count_worker.tokenize_count(sentence).unwrap(),
            full_worker.tokenize_count(sentence).unwrap()
        );
    }
    drop(count_worker);
    drop(count_only);
    let tokens = full_worker
        .tokenize("語39")
        .expect("full tokenize succeeds");
    assert_eq!(tokens[0].feature, "feature-39");

    let bytes = std::fs::read(&binary_path).expect("read binary");
    for len in [0, 8, bytes.len() / 2, bytes.len() - 1] {
        let truncated = temp_dir.path().join(format!("truncated-{len}.dic"));
        std::fs::write(&truncated, &bytes[..len]).expect("write truncated binary");
        assert!(ZigTokenizer::from_binary_path(&truncated).is_err());
        assert!(ZigTokenizer::count_only_from_binary_path(&truncated).is_err());
        assert!(ZigTokenizer::from_binary_bytes(&bytes[..len]).is_err());
    }

    // Dictionaries written by an older binary format version are rejected
    // with an explicit error instead of being misread.
    for magic in [b"DLRDIC01", b"DLRDIC02", b"DLRDIC03"] {
        let mut legacy = bytes.clone();
        legacy[..magic.len()].copy_from_slice(magic);
        let legacy_path = temp_dir.path().join("legacy.dic");
        std::fs::write(&legacy_path, &legacy).expect("write legacy binary");
        for result in [
            ZigTokenizer::from_binary_path(&legacy_path),
            ZigTokenizer::count_only_from_binary_path(&legacy_path),
            ZigTokenizer::from_binary_bytes(&legacy),
        ] {
            let message = result.err().expect("legacy format is rejected").to_string();
            assert!(
                message.contains("UnsupportedDictionaryVersion"),
                "unexpected error: {message}"
            );
        }
    }
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
fn zig_ffi_token_views_expose_char_ranges() {
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
        .tokenize_borrowed_views("本X🍛カレー")
        .expect("Zig borrowed views succeed");
    let tokens: Vec<_> = views
        .iter()
        .map(|view| {
            (
                view.surface(),
                view.range_byte(),
                view.range_char(),
                view.is_unknown(),
            )
        })
        .collect();
    assert_eq!(views.iter().len(), tokens.len());
    assert_eq!(tokens.first(), Some(&("本", 0..3, 0..1, false)));
    // The fixture's DEFAULT unknown category groups the remaining characters,
    // including the 4-byte emoji, into one unknown token.
    assert_eq!(tokens.last(), Some(&("X🍛カレー", 3..17, 1..6, true)));
    assert!(views.get(tokens.len()).is_none());
}

#[test]
fn zig_ffi_borrowed_views_match_owned_tokens() {
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

    let raw = ZigTokenizer::from_raw_paths(
        fixture_dir.join("lex.csv"),
        fixture_dir.join("matrix.def"),
        fixture_dir.join("char.def"),
        fixture_dir.join("unk.def"),
    )
    .expect("Zig tokenizer loads raw fixture");
    let mmap = ZigTokenizer::from_binary_path(&binary_path).expect("Zig mmaps binary fixture");

    for tokenizer in [&raw, &mmap] {
        let mut worker = tokenizer.create_worker().expect("Zig worker is created");
        let mut reused_tokens = Vec::new();
        let mut reused_spans = Vec::new();
        let fixed = [
            "本とカレー",
            "本\0カレー",
            "",
            " 本 と ",
            "カレー本と本とカレー",
        ];
        let inputs = fixed
            .iter()
            .map(|input| input.to_string())
            .chain((0..fuzz_seed_count()).map(|seed| fuzz_string(seed, fuzz_max_len())));
        for input in inputs {
            let owned = worker.tokenize(&input).expect("owned tokenize succeeds");

            let views = worker
                .tokenize_borrowed_views(&input)
                .expect("borrowed views succeed");
            assert_eq!(views.len(), owned.len(), "{input:?}");
            let from_views: Vec<_> = views.iter().map(|view| view.to_token()).collect();
            assert_eq!(from_views, owned, "{input:?}");
            for (index, token) in owned.iter().enumerate() {
                let view = views.get(index).expect("view exists");
                assert_eq!(view.surface(), token.surface(), "{input:?}");
                assert_eq!(view.feature(), token.feature(), "{input:?}");
                assert_eq!(view.range_byte(), token.range_byte(), "{input:?}");
                assert_eq!(view.range_char(), token.range_char(), "{input:?}");
                assert_eq!(view.is_unknown(), token.is_unknown(), "{input:?}");
            }

            let collected: Vec<delarocha::Token> = worker
                .tokenize_views(&input)
                .expect("views succeed")
                .into_iter()
                .map(Into::into)
                .collect();
            assert_eq!(collected, owned, "{input:?}");

            // Reusing the output vector across sentences of different lengths
            // must not leak stale token data.
            worker
                .tokenize_into(&input, &mut reused_tokens)
                .expect("tokenize_into succeeds");
            assert_eq!(reused_tokens, owned, "{input:?}");

            worker
                .tokenize_spans_into(&input, &mut reused_spans)
                .expect("tokenize_spans_into succeeds");
            let spans: Vec<_> = owned
                .iter()
                .map(|token| (token.start, token.end, token.word_id))
                .collect();
            assert_eq!(
                reused_spans
                    .iter()
                    .map(|span| (span.start, span.end, span.word_id))
                    .collect::<Vec<_>>(),
                spans,
                "{input:?}"
            );
            assert_eq!(
                worker.tokenize_spans(&input).expect("spans succeed"),
                reused_spans,
                "{input:?}"
            );
        }
    }
}

#[test]
fn zig_ffi_compact_features_match_raw_dictionary_on_every_path() {
    let fixture_dir = std::path::Path::new(env!("CARGO_MANIFEST_DIR")).join("../../fixtures");
    let temp_dir = tempfile::tempdir().expect("create temp dir");
    let lex_path = temp_dir.path().join("lex.csv");
    let binary_path = temp_dir.path().join("compact.dic");
    // MeCab-style features: a shared part-of-speech prefix plus base form,
    // reading, and pronunciation columns select the compact encoding. The
    // last entry carries invalid UTF-8 in a literal column.
    let mut lexicon = Vec::new();
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
    lexicon.extend_from_slice("不正,0,0,1,名詞,一般,*,*,*,*,不正,フセイ\u{30fc},".as_bytes());
    lexicon.extend_from_slice(b"\xff\n");
    std::fs::write(&lex_path, lexicon).expect("write lexicon");

    let paths = |lex: &std::path::Path| {
        (
            lex.to_path_buf(),
            fixture_dir.join("matrix.def"),
            fixture_dir.join("char.def"),
            fixture_dir.join("unk.def"),
        )
    };
    let (lex, matrix, char_def, unk) = paths(&lex_path);
    ZigTokenizer::write_binary_from_raw_paths(&lex, &matrix, &char_def, &unk, &binary_path)
        .expect("Zig writes binary dictionary");
    let raw = ZigTokenizer::from_raw_paths(&lex, &matrix, &char_def, &unk)
        .expect("Zig tokenizer loads raw lexicon");
    let mmap = ZigTokenizer::from_binary_path(&binary_path).expect("Zig mmaps binary");
    let bytes = std::fs::read(&binary_path).expect("read binary");
    let copied = ZigTokenizer::from_binary_bytes(&bytes).expect("Zig copies binary");

    let inputs = ["語1語22ご7ご39XYZ", "ご0語0不正ご0", "", "本とカレー🍛語39"];
    let mut raw_worker = raw.create_worker().expect("raw worker");
    for tokenizer in [&mmap, &copied] {
        let mut worker = tokenizer.create_worker().expect("worker");
        for _ in 0..2 {
            for input in inputs {
                let expected = raw_worker.tokenize(input).expect("raw tokenize");
                assert_eq!(worker.tokenize(input).expect("tokenize"), expected);
                let views = worker
                    .tokenize_borrowed_views(input)
                    .expect("borrowed views");
                let from_views: Vec<_> = views.iter().map(|view| view.to_token()).collect();
                assert_eq!(from_views, expected);

                // Features stay available after span-only tokenization and
                // after the input buffer is gone.
                let spans = worker.tokenize_spans(input).expect("spans");
                assert_eq!(spans.len(), expected.len());
                let owned_input = input.to_string();
                let count = worker.tokenize_raw(&owned_input).expect("raw tokenize");
                drop(owned_input);
                assert_eq!(count, expected.len());
                for (index, token) in expected.iter().enumerate() {
                    assert_eq!(worker.token_feature(index), token.feature, "{input:?}");
                }
            }
        }
    }
    let invalid = raw_worker.tokenize("不正").expect("tokenize invalid");
    assert_eq!(invalid[0].feature, "");
    let valid = raw_worker.tokenize("ご3").expect("tokenize valid");
    assert_eq!(
        valid[0].feature,
        "動詞,自立,*,*,五段・ラ行,基本形,ご3る,ゴ3,ゴー3"
    );
}

#[test]
fn zig_ffi_invalid_utf8_feature_is_empty_on_every_path() {
    let fixture_dir = std::path::Path::new(env!("CARGO_MANIFEST_DIR")).join("../../fixtures");
    let temp_dir = tempfile::tempdir().expect("create temp dir");
    let lex_path = temp_dir.path().join("lex.csv");
    let mut lexicon = std::fs::read(fixture_dir.join("lex.csv")).expect("read fixture lexicon");
    lexicon.extend_from_slice(b"\xe8\xaa\x9e,0,0,1,bad-\xff-feature\n");
    std::fs::write(&lex_path, lexicon).expect("write lexicon with invalid feature");

    let tokenizer = ZigTokenizer::from_raw_paths(
        &lex_path,
        fixture_dir.join("matrix.def"),
        fixture_dir.join("char.def"),
        fixture_dir.join("unk.def"),
    )
    .expect("Zig tokenizer loads raw lexicon");
    let mut worker = tokenizer.create_worker().expect("Zig worker is created");

    // Tokenize twice so the second pass exercises the per-word UTF-8 memo.
    for _ in 0..2 {
        let owned = worker
            .tokenize("本語カレー")
            .expect("owned tokenize succeeds");
        let bad = owned
            .iter()
            .find(|token| token.surface == "語")
            .expect("invalid-feature word is tokenized");
        assert_eq!(bad.feature, "");
        let good = owned
            .iter()
            .find(|token| token.surface == "カレー")
            .expect("valid word is tokenized");
        assert_eq!(good.feature, "noun,curry");

        let views = worker
            .tokenize_borrowed_views("本語カレー")
            .expect("borrowed views succeed");
        let from_views: Vec<_> = views.iter().map(|view| view.to_token()).collect();
        assert_eq!(from_views, owned);
    }
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

#[test]
fn pure_rust_matches_zig_ffi_on_fuzz_and_long_inputs() {
    // Uses the MeCab-style minimal fixture. On fixtures/vibrato the two
    // implementations already disagree (the " " lexicon surface and some
    // unknown-word grouping), independent of the pure-Rust dictionary lookup.
    let fixture_dir = std::path::Path::new(env!("CARGO_MANIFEST_DIR")).join("../../fixtures");
    let open = |name: &str| std::fs::File::open(fixture_dir.join(name)).expect("fixture exists");
    let pure = delarocha::Tokenizer::new(
        delarocha::SystemDictionaryBuilder::from_readers(
            open("lex.csv"),
            open("matrix.def"),
            open("char.def"),
            open("unk.def"),
        )
        .expect("pure dictionary builds"),
    );
    let zig = ZigTokenizer::from_raw_paths(
        fixture_dir.join("lex.csv"),
        fixture_dir.join("matrix.def"),
        fixture_dir.join("char.def"),
        fixture_dir.join("unk.def"),
    )
    .expect("Zig tokenizer loads raw fixture");
    let mut pure_worker = pure.create_worker();
    let mut zig_worker = zig.create_worker().expect("Zig worker is created");

    let long = "本とカレー 本X🍛カレー 東京に行く。abc 123\n".repeat(4096);
    let inputs = (0..fuzz_seed_count())
        .map(|seed| fuzz_string(seed, fuzz_max_len()))
        .chain([long]);
    for input in inputs {
        let expected = zig_worker.tokenize(&input).expect("Zig tokenize succeeds");
        let actual = pure_worker
            .tokenize(&input)
            .expect("pure tokenize succeeds");
        let context = input.get(..input.len().min(120));
        assert_eq!(actual.len(), expected.len(), "token count for {context:?}");
        for (a, e) in actual.iter().zip(&expected) {
            assert_eq!(a.surface, e.surface, "{context:?}");
            assert_eq!(a.byte_range(), e.byte_range(), "{context:?}");
            assert_eq!(a.range_char(), e.range_char(), "{context:?}");
            assert_eq!(a.is_unknown(), e.is_unknown(), "{context:?}");
            assert_eq!(a.feature, e.feature, "{context:?}");
        }
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
