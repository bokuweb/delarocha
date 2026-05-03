use criterion::{Criterion, criterion_group, criterion_main};
use delarocha::{Dictionary, Tokenizer};
use std::hint::black_box;
use std::path::{Path, PathBuf};

const DICT: &str = include_str!("../../../fixtures/minimal.dict");
#[cfg(feature = "vibrato-bench")]
const LEX_CSV: &str = include_str!("../../../fixtures/lex.csv");
#[cfg(feature = "vibrato-bench")]
const MATRIX_DEF: &str = include_str!("../../../fixtures/matrix.def");
#[cfg(feature = "vibrato-bench")]
const CHAR_DEF: &str = include_str!("../../../fixtures/char.def");
#[cfg(feature = "vibrato-bench")]
const UNK_DEF: &str = include_str!("../../../fixtures/unk.def");
const SENTENCES: &[&str] = &[
    "本とカレー",
    "本とカレー本とカレー",
    "本X🍛カレー",
    "カレー本と本とカレー",
];

fn bench_delarocha(c: &mut Criterion) {
    let dictionary = Dictionary::parse(DICT).expect("fixture dictionary parses");
    let tokenizer = Tokenizer::new(dictionary);
    let mut worker = tokenizer.create_worker();

    c.bench_function("delarocha/rust-baseline", |b| {
        b.iter(|| {
            for sentence in SENTENCES {
                black_box(worker.tokenize(black_box(sentence)).unwrap());
            }
        });
    });
}

#[cfg(feature = "zig-ffi")]
fn bench_zig_ffi(c: &mut Criterion) {
    let fixture_dir = Path::new(env!("CARGO_MANIFEST_DIR")).join("../../fixtures");
    let tokenizer = delarocha::ffi::ZigTokenizer::from_raw_paths(
        fixture_dir.join("lex.csv"),
        fixture_dir.join("matrix.def"),
        fixture_dir.join("char.def"),
        fixture_dir.join("unk.def"),
    )
    .expect("Zig tokenizer loads raw fixture dictionary");
    let mut worker = tokenizer.create_worker().expect("Zig worker is created");

    c.bench_function("delarocha/zig-ffi", |b| {
        b.iter(|| {
            for sentence in SENTENCES {
                black_box(worker.tokenize_count(black_box(sentence)).unwrap());
            }
        });
    });

    let batch = delarocha::ffi::ZigBatch::new(SENTENCES);
    c.bench_function("delarocha/zig-ffi-batch", |b| {
        b.iter(|| {
            black_box(worker.tokenize_count_batch(black_box(&batch)).unwrap());
        });
    });

    let Some(raw_dir) = std::env::var_os("ZIG_RAW_DIC_DIR").map(PathBuf::from) else {
        eprintln!("skip Zig ipadic bench: set ZIG_RAW_DIC_DIR to raw dictionary directory");
        return;
    };

    let raw_tokenizer = delarocha::ffi::ZigTokenizer::count_only_from_raw_paths(
        raw_dir.join("lex.csv"),
        raw_dir.join("matrix.def"),
        raw_dir.join("char.def"),
        raw_dir.join("unk.def"),
    )
    .expect("Zig tokenizer loads count-only raw ipadic dictionary");
    let mut raw_worker = raw_tokenizer
        .create_worker()
        .expect("Zig raw ipadic worker is created");
    c.bench_function("delarocha/zig-ffi-ipadic-raw-count-only", |b| {
        b.iter(|| {
            for sentence in SENTENCES {
                black_box(raw_worker.tokenize_count_assume_valid(black_box(sentence)));
            }
        });
    });
    drop(raw_worker);
    drop(raw_tokenizer);

    let target_tmp = Path::new(env!("CARGO_MANIFEST_DIR")).join("../../target/tmp");
    std::fs::create_dir_all(&target_tmp).expect("create target tmp dir");
    let binary_path = target_tmp.join("zig-ipadic.dic");
    delarocha::ffi::ZigTokenizer::write_binary_from_raw_paths(
        raw_dir.join("lex.csv"),
        raw_dir.join("matrix.def"),
        raw_dir.join("char.def"),
        raw_dir.join("unk.def"),
        &binary_path,
    )
    .expect("Zig writes binary ipadic dictionary");
    let binary_tokenizer = delarocha::ffi::ZigTokenizer::count_only_from_binary_path(&binary_path)
        .expect("Zig tokenizer loads count-only binary ipadic dictionary");
    let mut binary_worker = binary_tokenizer
        .create_worker()
        .expect("Zig binary ipadic worker is created");
    c.bench_function("delarocha/zig-ffi-ipadic-binary-count-only", |b| {
        b.iter(|| {
            for sentence in SENTENCES {
                black_box(binary_worker.tokenize_count_assume_valid(black_box(sentence)));
            }
        });
    });

    c.bench_function("delarocha/zig-ffi-ipadic-binary-count-only-batch", |b| {
        b.iter(|| {
            black_box(binary_worker.tokenize_count_batch_assume_valid(black_box(&batch)));
        });
    });
}

#[cfg(not(feature = "zig-ffi"))]
fn bench_zig_ffi(_c: &mut Criterion) {}

#[cfg(feature = "vibrato-bench")]
fn bench_vibrato(c: &mut Criterion) {
    use std::fs::File;
    use std::io::BufReader;
    use std::path::PathBuf;

    let Some(path) = std::env::var_os("VIBRATO_SYSTEM_DIC").map(PathBuf::from) else {
        eprintln!("skip vibrato bench: set VIBRATO_SYSTEM_DIC to system.dic or system.dic.zst");
        return;
    };

    let file = File::open(&path).expect("open VIBRATO_SYSTEM_DIC");
    let dictionary = if path.extension().is_some_and(|ext| ext == "zst") {
        let decoder = zstd::Decoder::new(file).expect("create zstd decoder");
        vibrato::Dictionary::read(BufReader::new(decoder)).expect("read compressed Vibrato dict")
    } else {
        vibrato::Dictionary::read(BufReader::new(file)).expect("read Vibrato dict")
    };
    let tokenizer = vibrato::Tokenizer::new(dictionary);
    let mut worker = tokenizer.new_worker();

    c.bench_function("vibrato/system-dic", |b| {
        b.iter(|| {
            for sentence in SENTENCES {
                worker.reset_sentence(black_box(sentence));
                worker.tokenize();
                black_box(worker.num_tokens());
            }
        });
    });
}

#[cfg(feature = "vibrato-bench")]
fn bench_vibrato_raw_fixture(c: &mut Criterion) {
    let dictionary = vibrato::SystemDictionaryBuilder::from_readers(
        LEX_CSV.as_bytes(),
        MATRIX_DEF.as_bytes(),
        CHAR_DEF.as_bytes(),
        UNK_DEF.as_bytes(),
    )
    .expect("build Vibrato fixture dictionary");
    let tokenizer = vibrato::Tokenizer::new(dictionary);
    let mut worker = tokenizer.new_worker();

    c.bench_function("vibrato/raw-fixture", |b| {
        b.iter(|| {
            for sentence in SENTENCES {
                worker.reset_sentence(black_box(sentence));
                worker.tokenize();
                black_box(worker.num_tokens());
            }
        });
    });
}

#[cfg(not(feature = "vibrato-bench"))]
fn bench_vibrato(_c: &mut Criterion) {}

#[cfg(not(feature = "vibrato-bench"))]
fn bench_vibrato_raw_fixture(_c: &mut Criterion) {}

fn benches(c: &mut Criterion) {
    bench_delarocha(c);
    bench_zig_ffi(c);
    bench_vibrato_raw_fixture(c);
    bench_vibrato(c);
}

criterion_group!(tokenize, benches);
criterion_main!(tokenize);
