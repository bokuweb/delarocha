#![cfg(feature = "vibrato-system")]

use delarocha::VibratoSystemDictionary;

const LEX_CSV: &str = include_str!("../../../fixtures/vibrato/lex.csv");
const MATRIX_DEF: &str = include_str!("../../../fixtures/vibrato/matrix.def");
const CHAR_DEF: &str = include_str!("../../../fixtures/vibrato/char.def");
const UNK_DEF: &str = include_str!("../../../fixtures/vibrato/unk.def");

#[test]
fn reads_vibrato_system_dic_zst_from_path() {
    let temp_dir = tempfile::tempdir().expect("create temp dir");
    let dict_path = temp_dir.path().join("system.dic.zst");
    std::fs::write(&dict_path, compressed_vibrato_dictionary()).expect("write compressed dict");

    let tokenizer = VibratoSystemDictionary::from_path(&dict_path)
        .expect("read compressed Vibrato system dictionary")
        .into_tokenizer()
        .ignore_space(true)
        .expect("enable MeCab-compatible space handling")
        .max_grouping_len(24);
    let tokens = tokenizer.tokenize("京都東京都京都").unwrap();

    assert_eq!(
        tokens
            .iter()
            .map(|token| token.surface())
            .collect::<Vec<_>>(),
        ["京都", "東京都", "京都"]
    );
    assert_eq!(tokens[0].range_byte(), 0..6);
    assert_eq!(tokens[1].range_byte(), 6..15);
    assert_eq!(tokens[2].range_byte(), 15..21);
}

#[test]
fn reads_vibrato_system_dic_zst_from_reader() {
    let tokenizer = VibratoSystemDictionary::read_zstd(compressed_vibrato_dictionary().as_slice())
        .expect("read compressed Vibrato system dictionary")
        .into_tokenizer();

    let tokens = tokenizer.tokenize("東京都").unwrap();
    assert_eq!(tokens.len(), 1);
    assert_eq!(tokens[0].surface(), "東京都");
    assert_eq!(
        tokens[0].feature(),
        "東京都,名詞,固有名詞,地名,一般,*,*,トウキョウト,東京都,*,B,5/9,*,5/9,*"
    );
}

#[test]
fn reusable_worker_exposes_borrowed_tokens() {
    let tokenizer = VibratoSystemDictionary::read_zstd(compressed_vibrato_dictionary().as_slice())
        .expect("read compressed Vibrato system dictionary")
        .into_tokenizer();
    let mut worker = tokenizer.new_worker();

    worker.tokenize("京都東京都");
    assert_eq!(
        worker
            .token_iter()
            .map(|token| token.surface().to_owned())
            .collect::<Vec<_>>(),
        ["京都", "東京都"]
    );

    worker.tokenize("東京都");
    let tokens = worker.token_iter().collect::<Vec<_>>();
    assert_eq!(tokens.len(), 1);
    assert_eq!(tokens[0].surface(), "東京都");
    assert_eq!(tokens[0].range_byte(), 0..9);
    assert!(!tokens[0].is_unknown());
}

#[test]
fn reusable_worker_can_visit_tokens_with_raw_word_ids() {
    let tokenizer = VibratoSystemDictionary::read_zstd(compressed_vibrato_dictionary().as_slice())
        .expect("read compressed Vibrato system dictionary")
        .into_tokenizer();
    let mut worker = tokenizer.new_worker();

    let mut visited = Vec::new();
    worker.tokenize_with("京都東京都", |index, token| {
        visited.push((
            index,
            token.surface().to_owned(),
            token.raw_word_id(),
            token.word_id(),
        ));
    });

    assert_eq!(worker.num_tokens(), 2);
    assert_eq!(visited[0].0, 0);
    assert_eq!(visited[0].1, "京都");
    assert_eq!(visited[0].2, visited[0].3);
    assert_eq!(visited[1].0, 1);
    assert_eq!(visited[1].1, "東京都");
    assert_eq!(visited[1].2, visited[1].3);
}

#[test]
fn reusable_worker_can_expose_underlying_vibrato_worker() {
    let tokenizer = VibratoSystemDictionary::read_zstd(compressed_vibrato_dictionary().as_slice())
        .expect("read compressed Vibrato system dictionary")
        .into_tokenizer();
    let mut worker = tokenizer.new_worker();

    let vibrato_worker = worker.as_vibrato_worker_mut();
    vibrato_worker.reset_sentence("京都東京都");
    vibrato_worker.tokenize();

    assert_eq!(worker.as_vibrato_worker().num_tokens(), 2);
    assert_eq!(
        worker
            .as_vibrato_worker()
            .token_iter()
            .map(|token| token.surface().to_owned())
            .collect::<Vec<_>>(),
        ["京都", "東京都"]
    );
}

#[test]
fn reads_real_vibrato_system_dic_zst_when_env_set() {
    let Ok(path) = std::env::var("VIBRATO_SYSTEM_DIC") else {
        return;
    };
    let tokenizer = VibratoSystemDictionary::from_path(path)
        .expect("read real compressed Vibrato system dictionary")
        .into_tokenizer()
        .ignore_space(true)
        .expect("enable MeCab-compatible space handling")
        .max_grouping_len(24);

    let tokens = tokenizer.tokenize("これはテストです。").unwrap();
    assert!(!tokens.is_empty());
    assert_eq!(
        tokens
            .iter()
            .map(|token| token.surface())
            .collect::<String>(),
        "これはテストです。"
    );
}

fn compressed_vibrato_dictionary() -> Vec<u8> {
    let lex_csv = normalize_lf(LEX_CSV);
    let matrix_def = normalize_lf(MATRIX_DEF);
    let char_def = normalize_lf(CHAR_DEF);
    let unk_def = normalize_lf(UNK_DEF);
    let dictionary = vibrato::SystemDictionaryBuilder::from_readers(
        lex_csv.as_bytes(),
        matrix_def.as_bytes(),
        char_def.as_bytes(),
        unk_def.as_bytes(),
    )
    .expect("build Vibrato fixture dictionary");
    let mut raw = Vec::new();
    dictionary
        .write(&mut raw)
        .expect("write Vibrato dictionary");
    zstd::stream::encode_all(raw.as_slice(), 0).expect("compress Vibrato dictionary")
}

fn normalize_lf(input: &str) -> String {
    input.replace("\r\n", "\n")
}
