use delarocha::{SystemDictionaryBuilder, Tokenizer};

const LEX_CSV: &str = include_str!("../../../fixtures/vibrato/lex.csv");
const MATRIX_DEF: &str = include_str!("../../../fixtures/vibrato/matrix.def");
const CHAR_DEF: &str = include_str!("../../../fixtures/vibrato/char.def");
const UNK_DEF: &str = include_str!("../../../fixtures/vibrato/unk.def");

#[test]
fn seeded_fuzz_tokenize_preserves_input_spans() {
    let dictionary = SystemDictionaryBuilder::from_readers(
        LEX_CSV.as_bytes(),
        MATRIX_DEF.as_bytes(),
        CHAR_DEF.as_bytes(),
        UNK_DEF.as_bytes(),
    )
    .expect("fixture dictionary builds");
    let tokenizer = Tokenizer::new(dictionary);

    for seed in 0..512 {
        let input = fuzz_string(seed);
        let tokens = tokenizer.tokenize(&input).expect("tokenization succeeds");
        let mut rebuilt = String::new();
        let mut previous_end = 0;
        for token in &tokens {
            assert!(
                previous_end <= token.range_byte().start,
                "token byte ranges must be monotonic for seed {seed}: {input:?}"
            );
            assert!(
                input.is_char_boundary(token.range_byte().start)
                    && input.is_char_boundary(token.range_byte().end),
                "token byte ranges must stay on UTF-8 boundaries for seed {seed}: {input:?}"
            );
            rebuilt.push_str(token.surface());
            previous_end = token.range_byte().end;
        }
        assert_eq!(rebuilt, input, "token surfaces must rebuild seed {seed}");
        assert_eq!(
            previous_end,
            input.len(),
            "last token must end at input length for seed {seed}: {input:?}"
        );
    }
}

fn fuzz_string(seed: u64) -> String {
    const POOL: &[char] = &[
        '本', 'と', 'カ', 'レ', 'ー', '東', '京', '都', 'に', '行', 'く', '一', '橋', '大', '学',
        '院', '0', '1', '9', 'a', 'Z', ' ', '\n', '。', '、', '・', 'X', '🍛', '😀',
    ];

    let mut rng = XorShift64(seed.wrapping_mul(0x9e37_79b9_7f4a_7c15) ^ 0xa5a5_5a5a_dead_beef);
    let len = (rng.next() % 96) as usize;
    let mut out = String::new();
    for _ in 0..len {
        let ch = POOL[(rng.next() as usize) % POOL.len()];
        out.push(ch);
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
