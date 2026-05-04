use delarocha::{SystemDictionaryBuilder, Tokenizer};

const LEX_CSV: &str = include_str!("../../../fixtures/vibrato/lex.csv");
const USER_CSV: &str = include_str!("../../../fixtures/vibrato/user.csv");
const MATRIX_DEF: &str = include_str!("../../../fixtures/vibrato/matrix.def");
const CHAR_DEF: &str = include_str!("../../../fixtures/vibrato/char.def");
const UNK_DEF: &str = include_str!("../../../fixtures/vibrato/unk.def");

fn dict() -> delarocha::Dictionary {
    SystemDictionaryBuilder::from_readers(
        LEX_CSV.as_bytes(),
        MATRIX_DEF.as_bytes(),
        CHAR_DEF.as_bytes(),
        UNK_DEF.as_bytes(),
    )
    .unwrap()
}

fn user_dict() -> delarocha::Dictionary {
    dict()
        .reset_user_lexicon_from_reader(Some(USER_CSV.as_bytes()))
        .unwrap()
}

fn assert_token(
    token: &delarocha::Token,
    surface: &str,
    char_range: std::ops::Range<usize>,
    byte_range: std::ops::Range<usize>,
    feature: &str,
) {
    assert_eq!(token.surface(), surface);
    assert_eq!(token.range_char(), char_range);
    assert_eq!(token.range_byte(), byte_range);
    assert_eq!(token.feature(), feature);
}

#[test]
fn vibrato_test_tokenize_tokyo() {
    let tokenizer = Tokenizer::new(dict());
    let tokens = tokenizer.tokenize("東京都").unwrap();
    assert_eq!(tokens.len(), 1);
    assert_token(
        &tokens[0],
        "東京都",
        0..3,
        0..9,
        "東京都,名詞,固有名詞,地名,一般,*,*,トウキョウト,東京都,*,B,5/9,*,5/9,*",
    );
    assert_eq!(tokens[0].total_cost(), -79 + 5320);
}

#[test]
fn vibrato_test_tokenize_kyotokyo() {
    let tokenizer = Tokenizer::new(dict());
    let tokens = tokenizer.tokenize("京都東京都京都").unwrap();
    assert_eq!(tokens.len(), 3);
    assert_token(
        &tokens[0],
        "京都",
        0..2,
        0..6,
        "京都,名詞,固有名詞,地名,一般,*,*,キョウト,京都,*,A,*,*,*,1/5",
    );
    assert_token(
        &tokens[1],
        "東京都",
        2..5,
        6..15,
        "東京都,名詞,固有名詞,地名,一般,*,*,トウキョウト,東京都,*,B,5/9,*,5/9,*",
    );
    assert_token(
        &tokens[2],
        "京都",
        5..7,
        15..21,
        "京都,名詞,固有名詞,地名,一般,*,*,キョウト,京都,*,A,*,*,*,1/5",
    );
    assert_eq!(tokens[0].total_cost(), -79 + 5293);
    assert_eq!(tokens[1].total_cost(), tokens[0].total_cost() + 569 + 5320);
    assert_eq!(tokens[2].total_cost(), tokens[1].total_cost() - 352 + 5293);
}

#[test]
fn vibrato_test_tokenize_kyotokyo_with_user() {
    let tokenizer = Tokenizer::new(user_dict());
    let tokens = tokenizer.tokenize("京都東京都京都").unwrap();
    assert_eq!(tokens.len(), 2);
    assert_token(&tokens[0], "京都東京都", 0..5, 0..15, "カスタム名詞");
    assert_token(
        &tokens[1],
        "京都",
        5..7,
        15..21,
        "京都,名詞,固有名詞,地名,一般,*,*,キョウト,京都,*,A,*,*,*,1/5",
    );
    assert_eq!(tokens[0].total_cost(), -79 - 1000);
    assert_eq!(tokens[1].total_cost(), tokens[0].total_cost() - 352 + 5293);
}

#[test]
fn vibrato_test_space_variants() {
    let tokenizer = Tokenizer::new(dict());
    let tokens = tokenizer.tokenize("東京 都").unwrap();
    assert_eq!(tokens.len(), 3);
    assert_token(
        &tokens[0],
        "東京",
        0..2,
        0..6,
        "東京,名詞,固有名詞,地名,一般,*,*,トウキョウ,東京,*,A,*,*,*,*",
    );
    assert_token(
        &tokens[1],
        " ",
        2..3,
        6..7,
        " ,空白,*,*,*,*,*, , ,*,A,*,*,*,*",
    );
    assert_token(
        &tokens[2],
        "都",
        3..4,
        7..10,
        "都,名詞,普通名詞,一般,*,*,*,ト,都,*,A,*,*,*,*",
    );

    let ignored = Tokenizer::new(dict()).ignore_space(true).unwrap();
    let tokens = ignored.tokenize("東京 都").unwrap();
    assert_eq!(tokens.len(), 2);
    assert_token(
        &tokens[0],
        "東京",
        0..2,
        0..6,
        "東京,名詞,固有名詞,地名,一般,*,*,トウキョウ,東京,*,A,*,*,*,*",
    );
    assert_token(
        &tokens[1],
        "都",
        3..4,
        7..10,
        "都,名詞,普通名詞,一般,*,*,*,ト,都,*,A,*,*,*,*",
    );

    let tokens = ignored.tokenize("東京   都").unwrap();
    assert_eq!(tokens.len(), 2);
    assert_token(
        &tokens[0],
        "東京",
        0..2,
        0..6,
        "東京,名詞,固有名詞,地名,一般,*,*,トウキョウ,東京,*,A,*,*,*,*",
    );
    assert_token(
        &tokens[1],
        "都",
        5..6,
        9..12,
        "都,名詞,普通名詞,一般,*,*,*,ト,都,*,A,*,*,*,*",
    );

    let tokens = ignored.tokenize("   東京都").unwrap();
    assert_eq!(tokens.len(), 1);
    assert_token(
        &tokens[0],
        "東京都",
        3..6,
        3..12,
        "東京都,名詞,固有名詞,地名,一般,*,*,トウキョウト,東京都,*,B,5/9,*,5/9,*",
    );

    let tokens = ignored.tokenize("東京都   ").unwrap();
    assert_eq!(tokens.len(), 1);
    assert_token(
        &tokens[0],
        "東京都",
        0..3,
        0..9,
        "東京都,名詞,固有名詞,地名,一般,*,*,トウキョウト,東京都,*,B,5/9,*,5/9,*",
    );
}

#[test]
fn vibrato_test_kampersanda_variants() {
    let tokens = Tokenizer::new(dict()).tokenize("kampersanda").unwrap();
    assert_eq!(tokens.len(), 1);
    assert_token(
        &tokens[0],
        "kampersanda",
        0..11,
        0..11,
        "名詞,普通名詞,一般,*,*,*",
    );
    assert_eq!(tokens[0].total_cost(), 887 + 11633);

    let tokens = Tokenizer::new(user_dict()).tokenize("kampersanda").unwrap();
    assert_eq!(tokens.len(), 1);
    assert_token(&tokens[0], "kampersanda", 0..11, 0..11, "カスタム名詞");
    assert_eq!(tokens[0].total_cost(), 887 - 2000);

    let tokenizer = Tokenizer::new(dict())
        .ignore_space(true)
        .unwrap()
        .max_grouping_len(9);
    let tokens = tokenizer.tokenize("kampersanda").unwrap();
    assert_eq!(tokens.len(), 2);
    assert_token(&tokens[0], "k", 0..1, 0..1, "名詞,普通名詞,一般,*,*,*");
    assert_token(
        &tokens[1],
        "ampersanda",
        1..11,
        1..11,
        "名詞,普通名詞,一般,*,*,*",
    );
    assert_eq!(tokens[0].total_cost(), 887 + 11633);
    assert_eq!(
        tokens[1].total_cost(),
        tokens[0].total_cost() + 2341 + 11633
    );
}

#[test]
fn vibrato_test_remaining_tokenizer_cases() {
    let tokenizer = Tokenizer::new(dict());
    assert_eq!(tokenizer.tokenize("東京県に行く").unwrap().len(), 4);

    let tokens = tokenizer.tokenize("一橋大学大学院").unwrap();
    assert_eq!(tokens.len(), 1);
    assert_token(
        &tokens[0],
        "一橋大学大学院",
        0..7,
        0..21,
        "名詞,数,*,*,*,*,*",
    );

    assert_eq!(tokenizer.tokenize("").unwrap().len(), 0);

    let mut worker = tokenizer.new_worker();
    worker.reset_sentence("東京に行く");
    worker.tokenize();
    assert_eq!(worker.num_tokens(), 3);
    worker.reset_sentence("一橋大学大学院");
    worker.tokenize();
    assert_eq!(worker.num_tokens(), 1);
    worker.reset_sentence("");
    worker.tokenize();
    assert_eq!(worker.num_tokens(), 0);
    worker.reset_sentence("kampersanda");
    worker.tokenize();
    assert_eq!(worker.num_tokens(), 1);
}
