#![no_main]

use std::sync::OnceLock;

use delarocha::{SystemDictionaryBuilder, Tokenizer};
use libfuzzer_sys::fuzz_target;

const LEX_CSV: &str = include_str!("../../fixtures/vibrato/lex.csv");
const MATRIX_DEF: &str = include_str!("../../fixtures/vibrato/matrix.def");
const CHAR_DEF: &str = include_str!("../../fixtures/vibrato/char.def");
const UNK_DEF: &str = include_str!("../../fixtures/vibrato/unk.def");

fuzz_target!(|data: &[u8]| {
    let Ok(input) = std::str::from_utf8(data) else {
        return;
    };
    if input.len() > 8192 {
        return;
    }

    let tokenizer = tokenizer();
    let tokens = tokenizer
        .tokenize(input)
        .expect("tokenization should not fail for valid UTF-8 input");

    let mut rebuilt = String::new();
    let mut previous_end = 0;
    for token in &tokens {
        assert!(previous_end <= token.range_byte().start);
        assert!(input.is_char_boundary(token.range_byte().start));
        assert!(input.is_char_boundary(token.range_byte().end));
        rebuilt.push_str(token.surface());
        previous_end = token.range_byte().end;
    }
    assert_eq!(rebuilt, input);
    assert_eq!(previous_end, input.len());
});

fn tokenizer() -> &'static Tokenizer {
    static TOKENIZER: OnceLock<Tokenizer> = OnceLock::new();
    TOKENIZER.get_or_init(|| {
        let dictionary = SystemDictionaryBuilder::from_readers(
            LEX_CSV.as_bytes(),
            MATRIX_DEF.as_bytes(),
            CHAR_DEF.as_bytes(),
            UNK_DEF.as_bytes(),
        )
        .expect("fixture dictionary builds");
        Tokenizer::new(dictionary)
    })
}
