use delarocha::{Dictionary, Tokenizer};
use std::hint::black_box;
use std::path::{Path, PathBuf};
use std::process::Command;

const DICT: &str = include_str!("../../../fixtures/minimal.dict");
const SENTENCES: &[&str] = &[
    "本とカレー",
    "本とカレー本とカレー",
    "本X🍛カレー",
    "カレー本と本とカレー",
];

fn main() {
    let mode = std::env::args()
        .nth(1)
        .unwrap_or_else(|| "delarocha-rust".to_owned());
    let base = current_rss_kb();
    match mode.as_str() {
        "delarocha-rust" => run_delarocha_rust(base),
        #[cfg(feature = "zig-ffi")]
        "delarocha-zig" => run_delarocha_zig(base),
        #[cfg(feature = "zig-ffi")]
        "delarocha-zig-ipadic-raw" => run_delarocha_zig_ipadic_raw(base),
        #[cfg(feature = "zig-ffi")]
        "delarocha-zig-ipadic-binary" => run_delarocha_zig_ipadic_binary(base),
        #[cfg(feature = "vibrato-bench")]
        "vibrato" => run_vibrato(base),
        #[cfg(feature = "vibrato-bench")]
        "vibrato-system" => run_vibrato_system(base),
        other => {
            eprintln!("unknown mode: {other}");
            std::process::exit(2);
        }
    }
}

fn run_delarocha_rust(base: usize) {
    let dictionary = Dictionary::parse(DICT).expect("fixture dictionary parses");
    let tokenizer = Tokenizer::new(dictionary);
    print_rss("delarocha-rust", "loaded", base);

    let mut worker = tokenizer.create_worker();
    let mut checksum = 0usize;
    for _ in 0..100_000 {
        for sentence in SENTENCES {
            checksum = checksum.wrapping_add(worker.tokenize(black_box(sentence)).unwrap().len());
        }
    }
    black_box(checksum);
    print_rss("delarocha-rust", "tokenized", base);
}

#[cfg(feature = "zig-ffi")]
fn run_delarocha_zig(base: usize) {
    let fixture_dir = Path::new(env!("CARGO_MANIFEST_DIR")).join("../../fixtures");
    let tokenizer = delarocha::ffi::ZigTokenizer::from_raw_paths(
        fixture_dir.join("lex.csv"),
        fixture_dir.join("matrix.def"),
        fixture_dir.join("char.def"),
        fixture_dir.join("unk.def"),
    )
    .expect("Zig tokenizer loads raw fixture dictionary");
    print_rss("delarocha-zig", "loaded", base);

    let mut worker = tokenizer.create_worker().expect("Zig worker is created");
    let batch = delarocha::ffi::ZigBatch::new(SENTENCES);
    let mut checksum = 0usize;
    for _ in 0..100_000 {
        checksum = checksum.wrapping_add(
            worker
                .tokenize_count_batch(black_box(&batch))
                .expect("Zig tokenizes batch"),
        );
    }
    black_box(checksum);
    print_rss("delarocha-zig", "tokenized", base);
}

#[cfg(feature = "zig-ffi")]
fn ipadic_raw_dir() -> PathBuf {
    std::env::var_os("ZIG_RAW_DIC_DIR")
        .map(PathBuf::from)
        .expect("set ZIG_RAW_DIC_DIR to a raw dictionary directory")
}

#[cfg(feature = "zig-ffi")]
fn run_delarocha_zig_ipadic_raw(base: usize) {
    let raw_dir = ipadic_raw_dir();
    let tokenizer = delarocha::ffi::ZigTokenizer::from_raw_paths(
        raw_dir.join("lex.csv"),
        raw_dir.join("matrix.def"),
        raw_dir.join("char.def"),
        raw_dir.join("unk.def"),
    )
    .expect("Zig tokenizer loads raw ipadic dictionary");
    run_delarocha_zig_worker(base, "delarocha-zig-ipadic-raw", tokenizer);
}

#[cfg(feature = "zig-ffi")]
fn run_delarocha_zig_ipadic_binary(base: usize) {
    let raw_dir = ipadic_raw_dir();
    let binary_path =
        Path::new(env!("CARGO_MANIFEST_DIR")).join("../../target/tmp/memory-zig-ipadic.dic");
    std::fs::create_dir_all(binary_path.parent().expect("binary path has parent"))
        .expect("create target tmp dir");
    delarocha::ffi::ZigTokenizer::write_binary_from_raw_paths(
        raw_dir.join("lex.csv"),
        raw_dir.join("matrix.def"),
        raw_dir.join("char.def"),
        raw_dir.join("unk.def"),
        &binary_path,
    )
    .expect("Zig writes binary ipadic dictionary");
    let tokenizer = delarocha::ffi::ZigTokenizer::from_binary_path(&binary_path)
        .expect("Zig tokenizer loads binary ipadic dictionary");
    run_delarocha_zig_worker(base, "delarocha-zig-ipadic-binary", tokenizer);
}

#[cfg(feature = "zig-ffi")]
fn run_delarocha_zig_worker(base: usize, name: &str, tokenizer: delarocha::ffi::ZigTokenizer) {
    print_rss(name, "loaded", base);

    let mut worker = tokenizer.create_worker().expect("Zig worker is created");
    let batch = delarocha::ffi::ZigBatch::new(SENTENCES);
    let mut checksum = 0usize;
    for _ in 0..100_000 {
        checksum = checksum.wrapping_add(
            worker
                .tokenize_count_batch(black_box(&batch))
                .expect("Zig tokenizes batch"),
        );
    }
    black_box(checksum);
    print_rss(name, "tokenized", base);
}

#[cfg(feature = "vibrato-bench")]
fn run_vibrato(base: usize) {
    const LEX_CSV: &str = include_str!("../../../fixtures/lex.csv");
    const MATRIX_DEF: &str = include_str!("../../../fixtures/matrix.def");
    const CHAR_DEF: &str = include_str!("../../../fixtures/char.def");
    const UNK_DEF: &str = include_str!("../../../fixtures/unk.def");

    let dictionary = vibrato::SystemDictionaryBuilder::from_readers(
        LEX_CSV.as_bytes(),
        MATRIX_DEF.as_bytes(),
        CHAR_DEF.as_bytes(),
        UNK_DEF.as_bytes(),
    )
    .expect("build Vibrato fixture dictionary");
    let tokenizer = vibrato::Tokenizer::new(dictionary);
    print_rss("vibrato", "loaded", base);

    let mut worker = tokenizer.new_worker();
    let mut checksum = 0usize;
    for _ in 0..100_000 {
        for sentence in SENTENCES {
            worker.reset_sentence(black_box(sentence));
            worker.tokenize();
            checksum = checksum.wrapping_add(worker.num_tokens());
        }
    }
    black_box(checksum);
    print_rss("vibrato", "tokenized", base);
}

#[cfg(feature = "vibrato-bench")]
fn run_vibrato_system(base: usize) {
    use std::fs::File;
    use std::io::BufReader;

    let path = std::env::var_os("VIBRATO_SYSTEM_DIC")
        .map(PathBuf::from)
        .expect("set VIBRATO_SYSTEM_DIC to system.dic or system.dic.zst");
    let file = File::open(&path).expect("open VIBRATO_SYSTEM_DIC");
    let dictionary = if path.extension().is_some_and(|ext| ext == "zst") {
        let decoder = zstd::Decoder::new(file).expect("create zstd decoder");
        vibrato::Dictionary::read(BufReader::new(decoder)).expect("read compressed Vibrato dict")
    } else {
        vibrato::Dictionary::read(BufReader::new(file)).expect("read Vibrato dict")
    };
    let tokenizer = vibrato::Tokenizer::new(dictionary);
    print_rss("vibrato-system", "loaded", base);

    let mut worker = tokenizer.new_worker();
    let mut checksum = 0usize;
    for _ in 0..100_000 {
        for sentence in SENTENCES {
            worker.reset_sentence(black_box(sentence));
            worker.tokenize();
            checksum = checksum.wrapping_add(worker.num_tokens());
        }
    }
    black_box(checksum);
    print_rss("vibrato-system", "tokenized", base);
}

fn print_rss(name: &str, phase: &str, base: usize) {
    let rss = current_rss_kb();
    println!(
        "{name},{phase},rss_kb={rss},delta_kb={}",
        rss.saturating_sub(base)
    );
}

fn current_rss_kb() -> usize {
    let pid = std::process::id().to_string();
    let output = Command::new("ps")
        .args(["-o", "rss=", "-p", &pid])
        .output()
        .expect("ps is available");
    String::from_utf8_lossy(&output.stdout)
        .trim()
        .parse()
        .expect("ps rss output is numeric")
}
