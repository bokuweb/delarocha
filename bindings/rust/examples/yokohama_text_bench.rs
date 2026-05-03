use std::hint::black_box;
use std::io::BufReader;
use std::path::{Path, PathBuf};
use std::time::{Duration, Instant};

fn main() {
    let text_path = std::env::var_os("YOKOHAMA_TEXT")
        .map(PathBuf::from)
        .expect("set YOKOHAMA_TEXT to the extracted Yokohama ordinance text file");
    let text = std::fs::read_to_string(&text_path).expect("read input text");
    let warmup = env_usize("YOKOHAMA_BENCH_WARMUP", 5);
    let iterations = env_usize("YOKOHAMA_BENCH_ITERATIONS", 50);

    println!(
        "input: {} bytes, {} chars",
        text.len(),
        text.chars().count()
    );

    #[cfg(feature = "zig-ffi")]
    run_delarocha_binary_count_only(&text, warmup, iterations);
    #[cfg(feature = "zig-ffi")]
    run_delarocha_raw_count_only(&text, warmup, iterations);
    #[cfg(feature = "vibrato-bench")]
    run_vibrato_system(&text, warmup, iterations);
}

#[cfg(feature = "zig-ffi")]
fn run_delarocha_binary_count_only(text: &str, warmup: usize, iterations: usize) {
    let raw_dir = ipadic_raw_dir();
    let binary_path =
        Path::new(env!("CARGO_MANIFEST_DIR")).join("../../target/tmp/yokohama-zig-ipadic.dic");
    std::fs::create_dir_all(binary_path.parent().expect("binary path has parent"))
        .expect("create target tmp dir");
    delarocha::ffi::ZigTokenizer::write_binary_from_raw_paths(
        raw_dir.join("lex.csv"),
        raw_dir.join("matrix.def"),
        raw_dir.join("char.def"),
        raw_dir.join("unk.def"),
        &binary_path,
    )
    .expect("write delarocha binary dictionary");
    let tokenizer = delarocha::ffi::ZigTokenizer::count_only_from_binary_path(&binary_path)
        .expect("load delarocha binary count-only dictionary");
    let mut worker = tokenizer.create_worker().expect("create delarocha worker");

    for _ in 0..warmup {
        black_box(worker.tokenize_count_assume_valid(black_box(text)));
    }
    let mut checksum = 0usize;
    let elapsed = measure(iterations, || {
        checksum = checksum.wrapping_add(worker.tokenize_count_assume_valid(black_box(text)));
    });
    print_result(
        "delarocha/binary-count-only",
        elapsed,
        iterations,
        checksum / iterations.max(1),
    );
}

#[cfg(feature = "zig-ffi")]
fn run_delarocha_raw_count_only(text: &str, warmup: usize, iterations: usize) {
    let raw_dir = ipadic_raw_dir();
    let tokenizer = delarocha::ffi::ZigTokenizer::count_only_from_raw_paths(
        raw_dir.join("lex.csv"),
        raw_dir.join("matrix.def"),
        raw_dir.join("char.def"),
        raw_dir.join("unk.def"),
    )
    .expect("load delarocha raw count-only dictionary");
    let mut worker = tokenizer.create_worker().expect("create delarocha worker");

    for _ in 0..warmup {
        black_box(worker.tokenize_count_assume_valid(black_box(text)));
    }
    let mut checksum = 0usize;
    let elapsed = measure(iterations, || {
        checksum = checksum.wrapping_add(worker.tokenize_count_assume_valid(black_box(text)));
    });
    print_result(
        "delarocha/raw-count-only",
        elapsed,
        iterations,
        checksum / iterations.max(1),
    );
}

#[cfg(feature = "zig-ffi")]
fn ipadic_raw_dir() -> PathBuf {
    std::env::var_os("ZIG_RAW_DIC_DIR")
        .map(PathBuf::from)
        .expect("set ZIG_RAW_DIC_DIR to a raw dictionary directory")
}

#[cfg(feature = "vibrato-bench")]
fn run_vibrato_system(text: &str, warmup: usize, iterations: usize) {
    let path = std::env::var_os("VIBRATO_SYSTEM_DIC")
        .map(PathBuf::from)
        .expect("set VIBRATO_SYSTEM_DIC to system.dic or system.dic.zst");
    let file = std::fs::File::open(&path).expect("open Vibrato dictionary");
    let dictionary = if path.extension().is_some_and(|ext| ext == "zst") {
        let decoder = zstd::Decoder::new(file).expect("create zstd decoder");
        vibrato::Dictionary::read(BufReader::new(decoder)).expect("read compressed Vibrato dict")
    } else {
        vibrato::Dictionary::read(BufReader::new(file)).expect("read Vibrato dict")
    };
    let tokenizer = vibrato::Tokenizer::new(dictionary);
    let mut worker = tokenizer.new_worker();

    for _ in 0..warmup {
        worker.reset_sentence(black_box(text));
        worker.tokenize();
        black_box(worker.num_tokens());
    }
    let mut checksum = 0usize;
    let elapsed = measure(iterations, || {
        worker.reset_sentence(black_box(text));
        worker.tokenize();
        checksum = checksum.wrapping_add(worker.num_tokens());
    });
    print_result(
        "vibrato/system-dic",
        elapsed,
        iterations,
        checksum / iterations.max(1),
    );
}

fn env_usize(name: &str, default: usize) -> usize {
    std::env::var(name)
        .ok()
        .and_then(|value| value.parse::<usize>().ok())
        .unwrap_or(default)
}

fn measure(iterations: usize, mut f: impl FnMut()) -> Duration {
    let iterations = iterations.max(1);
    let start = Instant::now();
    for _ in 0..iterations {
        f();
    }
    start.elapsed()
}

fn print_result(name: &str, elapsed: Duration, iterations: usize, tokens: usize) {
    let iterations = iterations.max(1);
    let per_iter = elapsed.as_secs_f64() / iterations as f64;
    println!(
        "{name}: {:.3} ms/iter ({:.3} s total, {iterations} iters), tokens={tokens}",
        per_iter * 1000.0,
        elapsed.as_secs_f64(),
    );
}
