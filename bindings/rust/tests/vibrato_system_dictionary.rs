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
    let dictionary = vibrato::SystemDictionaryBuilder::from_readers(
        LEX_CSV.as_bytes(),
        MATRIX_DEF.as_bytes(),
        CHAR_DEF.as_bytes(),
        UNK_DEF.as_bytes(),
    )
    .expect("build Vibrato fixture dictionary");
    let mut raw = Vec::new();
    dictionary
        .write(&mut raw)
        .expect("write Vibrato dictionary");
    zstd::stream::encode_all(raw.as_slice(), 0).expect("compress Vibrato dictionary")
}
