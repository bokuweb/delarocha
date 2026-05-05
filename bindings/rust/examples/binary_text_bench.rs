#[cfg(feature = "zig-ffi")]
use std::hint::black_box;
#[cfg(feature = "zig-ffi")]
use std::path::PathBuf;
#[cfg(feature = "zig-ffi")]
use std::time::{Duration, Instant};

#[cfg(feature = "zig-ffi")]
fn main() {
    let text_path = std::env::var_os("DELAROCHA_BENCH_TEXT")
        .map(PathBuf::from)
        .expect("set DELAROCHA_BENCH_TEXT to an input text file");
    let dict_path = std::env::var_os("DELAROCHA_BINARY_DIC")
        .map(PathBuf::from)
        .expect("set DELAROCHA_BINARY_DIC to a delarocha binary dictionary");
    let warmup = env_usize("DELAROCHA_BENCH_WARMUP", 5);
    let iterations = env_usize("DELAROCHA_BENCH_ITERATIONS", 50);
    let text = std::fs::read_to_string(&text_path).expect("read input text");

    println!(
        "input: {} bytes, {} chars",
        text.len(),
        text.chars().count()
    );

    if std::env::var_os("DELAROCHA_BENCH_FULL").is_some() {
        let tokenizer =
            delarocha::ffi::ZigTokenizer::from_binary_path(&dict_path).expect("load binary dictionary");
        let mut worker = tokenizer.create_worker().expect("create worker");
        for _ in 0..warmup {
            black_box(worker.tokenize(black_box(&text)).expect("tokenize"));
        }
        let mut checksum = 0usize;
        let elapsed = measure(iterations, || {
            checksum = checksum.wrapping_add(worker.tokenize(black_box(&text)).expect("tokenize").len());
        });
        print_result("delarocha/binary-full-tokenize", elapsed, iterations, checksum);
    } else {
        let tokenizer = delarocha::ffi::ZigTokenizer::count_only_from_binary_path(&dict_path)
            .expect("load binary count-only dictionary");
        let mut worker = tokenizer.create_worker().expect("create worker");

        for _ in 0..warmup {
            black_box(worker.tokenize_count_assume_valid(black_box(&text)));
        }
        let mut checksum = 0usize;
        let elapsed = measure(iterations, || {
            checksum = checksum.wrapping_add(worker.tokenize_count_assume_valid(black_box(&text)));
        });
        print_result("delarocha/binary-count-only", elapsed, iterations, checksum);
    }
}

#[cfg(not(feature = "zig-ffi"))]
fn main() {
    eprintln!("build with --features zig-ffi");
}

#[cfg(feature = "zig-ffi")]
fn env_usize(name: &str, default: usize) -> usize {
    std::env::var(name)
        .ok()
        .and_then(|value| value.parse::<usize>().ok())
        .unwrap_or(default)
}

#[cfg(feature = "zig-ffi")]
fn measure(iterations: usize, mut f: impl FnMut()) -> Duration {
    let iterations = iterations.max(1);
    let start = Instant::now();
    for _ in 0..iterations {
        f();
    }
    start.elapsed()
}

#[cfg(feature = "zig-ffi")]
fn print_result(name: &str, elapsed: Duration, iterations: usize, checksum: usize) {
    let iterations = iterations.max(1);
    let per_iter = elapsed.as_secs_f64() / iterations as f64;
    println!(
        "{name}: {:.3} ms/iter ({:.3} s total, {iterations} iters), checksum={checksum}",
        per_iter * 1000.0,
        elapsed.as_secs_f64(),
    );
}
