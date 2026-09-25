use delarocha::{Dictionary, SystemDictionaryBuilder, Tokenizer};

const DICT: &str = include_str!("../../../fixtures/minimal.dict");

#[test]
fn tokenizes_with_lowest_cost_path() {
    let dictionary = Dictionary::parse(DICT).expect("dictionary parses");
    let tokenizer = Tokenizer::new(dictionary);

    let tokens = tokenizer.tokenize("本とカレー").expect("tokenize succeeds");

    let surfaces: Vec<_> = tokens.iter().map(|token| token.surface.as_str()).collect();
    assert_eq!(surfaces, ["本と", "カレー"]);
    assert_eq!(tokens[0].byte_range(), 0..6);
    assert_eq!(tokens[1].byte_range(), 6..15);
    assert_eq!(tokens[0].feature, "compound,book-and");
}

#[test]
fn emits_unknown_tokens_on_utf8_boundaries() {
    let dictionary = Dictionary::parse(DICT).expect("dictionary parses");
    let tokenizer = Tokenizer::new(dictionary);

    let tokens = tokenizer.tokenize("本X🍛").expect("tokenize succeeds");

    let surfaces: Vec<_> = tokens.iter().map(|token| token.surface.as_str()).collect();
    assert_eq!(surfaces, ["本", "X", "🍛"]);
    assert_eq!(tokens[1].byte_range(), 3..4);
    assert_eq!(tokens[2].byte_range(), 4..8);
    assert!(tokens[1].is_unknown());
    assert!(tokens[2].is_unknown());
}

#[test]
fn worker_reuses_capacity_without_leaking_previous_tokens() {
    let dictionary = Dictionary::parse(DICT).expect("dictionary parses");
    let tokenizer = Tokenizer::new(dictionary);
    let mut worker = tokenizer.create_worker();

    let first = worker.tokenize("本とカレー").expect("tokenize succeeds");
    assert_eq!(
        first
            .iter()
            .map(|token| token.surface.as_str())
            .collect::<Vec<_>>(),
        ["本と", "カレー"]
    );

    let second = worker.tokenize("カレー").expect("tokenize succeeds");
    assert_eq!(
        second
            .iter()
            .map(|token| token.surface.as_str())
            .collect::<Vec<_>>(),
        ["カレー"]
    );
}

#[test]
fn count_only_matches_full_tokenization() {
    let dictionary = Dictionary::parse(DICT).expect("dictionary parses");
    let tokenizer = Tokenizer::new(dictionary);
    let mut worker = tokenizer.create_worker();

    for input in ["", "本とカレー", "本X🍛カレー", "カレー本と本とカレー"] {
        let full_count = tokenizer.tokenize(input).expect("tokenize succeeds").len();
        assert_eq!(
            tokenizer
                .tokenize_count(input)
                .expect("count tokenization succeeds"),
            full_count
        );
        assert_eq!(
            worker
                .tokenize_count(input)
                .expect("worker count tokenization succeeds"),
            full_count
        );
    }
}

#[test]
fn builds_from_mecab_style_readers() {
    let lexicon_csv = "自然,0,0,1,sizen
言語,0,0,4,gengo
処理,0,0,3,shori
自然言語,0,0,6,sizengengo
言語処理,0,0,5,gengoshori";
    let matrix_def = "1 1\n0 0 0";
    let char_def = "DEFAULT 0 1 0";
    let unk_def = "DEFAULT,0,0,100,*";

    let dictionary = SystemDictionaryBuilder::from_readers(
        lexicon_csv.as_bytes(),
        matrix_def.as_bytes(),
        char_def.as_bytes(),
        unk_def.as_bytes(),
    )
    .expect("dictionary builds");
    let tokenizer = Tokenizer::new(dictionary);

    let tokens = tokenizer
        .tokenize("自然言語処理")
        .expect("tokenize succeeds");

    assert_eq!(
        tokens
            .iter()
            .map(|token| token.surface.as_str())
            .collect::<Vec<_>>(),
        ["自然", "言語処理"]
    );
    assert_eq!(tokens[0].byte_range(), 0..6);
    assert_eq!(tokens[1].byte_range(), 6..18);
    assert_eq!(tokens[0].feature, "sizen");
    assert_eq!(tokens[1].total_cost, 6);
}

#[test]
fn groups_unknown_words_by_char_category() {
    let lexicon_csv = "本,0,0,1,noun";
    let matrix_def = "1 1\n0 0 0";
    let char_def = "DEFAULT 0 1 0\nALPHA 1 1 0\n0x0041..0x005A ALPHA";
    let unk_def = "DEFAULT,0,0,100,*\nALPHA,0,0,10,alpha";

    let dictionary = SystemDictionaryBuilder::from_readers(
        lexicon_csv.as_bytes(),
        matrix_def.as_bytes(),
        char_def.as_bytes(),
        unk_def.as_bytes(),
    )
    .expect("dictionary builds");
    let tokenizer = Tokenizer::new(dictionary);

    let tokens = tokenizer.tokenize("本ABC").expect("tokenize succeeds");

    assert_eq!(
        tokens
            .iter()
            .map(|token| token.surface.as_str())
            .collect::<Vec<_>>(),
        ["本", "ABC"]
    );
    assert!(tokens[1].is_unknown());
    assert_eq!(tokens[1].feature, "alpha");
    assert_eq!(tokens[1].byte_range(), 3..6);
}

#[test]
fn cached_unknown_grouping_preserves_reused_worker_results() {
    let dictionary = SystemDictionaryBuilder::from_readers(
        "a,0,0,10,system-alpha\n".as_bytes(),
        "1 1\n0 0 0\n".as_bytes(),
        "DEFAULT 0 1 0\nALPHA 1 1 24\n0x0061..0x007A ALPHA\n".as_bytes(),
        "DEFAULT,0,0,10000,default\nALPHA,0,0,1,unknown-alpha\n".as_bytes(),
    )
    .expect("dictionary builds");
    let tokenizer = Tokenizer::new(dictionary);
    let mut worker = tokenizer.create_worker();

    for input in ["aaaa", "aa", "aaaaaaaa", "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"] {
        let tokens = worker.tokenize(input).expect("tokenize succeeds");
        assert_eq!(tokens.len(), 1);
        assert_eq!(tokens[0].surface(), input);
        assert!(tokens[0].is_unknown());
        assert_eq!(worker.tokenize_count(input).expect("count succeeds"), 1);
    }
}

#[test]
fn ignore_space_matches_mecab_compatible_option() {
    let lexicon_csv = "mens,0,0,1,noun\nsecond,0,0,1,noun\nbag,0,0,1,noun";
    let matrix_def = "1 1\n0 0 0";
    let char_def = "DEFAULT 0 1 0\nSPACE 0 1 0\n0x0020 SPACE";
    let unk_def = "DEFAULT,0,0,100,*\nSPACE,0,0,100,space";
    let dictionary = SystemDictionaryBuilder::from_readers(
        lexicon_csv.as_bytes(),
        matrix_def.as_bytes(),
        char_def.as_bytes(),
        unk_def.as_bytes(),
    )
    .expect("dictionary builds");

    let tokenizer = Tokenizer::new(dictionary)
        .ignore_space(true)
        .expect("SPACE exists");
    let tokens = tokenizer
        .tokenize("mens second bag")
        .expect("tokenize succeeds");

    assert_eq!(
        tokens
            .iter()
            .map(|token| token.surface.as_str())
            .collect::<Vec<_>>(),
        ["mens", "second", "bag"]
    );
}

#[test]
fn max_grouping_len_limits_unknown_grouping() {
    let lexicon_csv = "本,0,0,1,noun";
    let matrix_def = "1 1\n0 0 0";
    let char_def = "DEFAULT 0 1 0\nALPHA 1 1 0\n0x0041..0x005A ALPHA";
    let unk_def = "DEFAULT,0,0,100,*\nALPHA,0,0,10,alpha";
    let dictionary = SystemDictionaryBuilder::from_readers(
        lexicon_csv.as_bytes(),
        matrix_def.as_bytes(),
        char_def.as_bytes(),
        unk_def.as_bytes(),
    )
    .expect("dictionary builds");

    let tokenizer = Tokenizer::new(dictionary).max_grouping_len(2);
    let tokens = tokenizer.tokenize("ABC").expect("tokenize succeeds");

    assert_eq!(
        tokens
            .iter()
            .map(|token| token.surface.as_str())
            .collect::<Vec<_>>(),
        ["ABC"]
    );
}

#[test]
fn long_input_keeps_byte_and_char_offsets_consistent() {
    let fixture_dir =
        std::path::Path::new(env!("CARGO_MANIFEST_DIR")).join("../../fixtures/vibrato");
    let open = |name: &str| std::fs::File::open(fixture_dir.join(name)).expect("fixture exists");
    let dictionary = SystemDictionaryBuilder::from_readers(
        open("lex.csv"),
        open("matrix.def"),
        open("char.def"),
        open("unk.def"),
    )
    .expect("fixture dictionary builds");
    let tokenizer = Tokenizer::new(dictionary);

    let unit = "京都東京都に行った。 アイウエオ本とカレー🍛 abc 123\n";
    let input = unit.repeat(4096);
    assert!(input.len() > 256 * 1024);

    let mut worker = tokenizer.create_worker();
    let tokens = worker.tokenize(&input).expect("tokenize succeeds").to_vec();
    assert_eq!(worker.tokenize_count(&input).unwrap(), tokens.len());

    let unit_tokens = tokenizer.tokenize(unit).expect("tokenize succeeds");
    let unit_chars = unit.chars().count();
    let mut byte = 0;
    let mut chars = 0;
    for (i, token) in tokens.iter().enumerate() {
        assert_eq!(
            token.start, byte,
            "token {i} starts where the previous ended"
        );
        assert_eq!(token.start_char, chars, "token {i} char start");
        assert_eq!(&input[token.byte_range()], token.surface);
        chars += token.surface.chars().count();
        byte = token.end;
        assert_eq!(token.end_char, chars, "token {i} char end");

        // Every unit ends with a newline, so the long input is the unit's
        // tokenization repeated with shifted offsets.
        let unit_token = &unit_tokens[i % unit_tokens.len()];
        let repeat = i / unit_tokens.len();
        assert_eq!(token.surface, unit_token.surface);
        assert_eq!(token.word_id, unit_token.word_id);
        assert_eq!(token.start, unit_token.start + repeat * unit.len());
        assert_eq!(
            token.start_char,
            unit_token.start_char + repeat * unit_chars
        );
    }
    assert_eq!(byte, input.len());
    assert_eq!(chars, input.chars().count());
}
