//! Token-view workloads in the tokenizer-speed-bench harness style
//! (<https://github.com/legalforce-research/tokenizer-speed-bench>): all
//! stdin lines are read first, each line is one input, only the tokenize loop
//! is timed, and the result is printed as `Elapsed-<label>: <secs> [sec]`
//! (stdout) and `Words-<label>: <tokens>` (stderr). One process runs one
//! timed loop; repeat and interleave processes to collect statistics.
//!
//! ```text
//! cargo run --release -p delarocha --features zig-ffi --example views_speed_bench -- \
//!     ipadic.dic views-sf < corpus.txt
//! cargo run --release -p delarocha --features "zig-ffi vibrato-bench" \
//!     --example views_speed_bench -- system.dic.zst vibrato-sf < corpus.txt
//! ```
//!
//! Modes (`<dictionary>` is a delarocha binary dictionary for the first four
//! and a Vibrato `system.dic[.zst]` for the `vibrato-*` modes):
//!
//! - `raw`: `ZigWorker::tokenize_raw` (token count only).
//! - `views-len`: `tokenize_borrowed_views(line)?.len()`.
//! - `views-sf`: borrowed views, reading `surface()` and `feature()` of every
//!   token.
//! - `views-char`: borrowed views, reading `range_char()` of every token.
//! - `spans-feature`: `tokenize_raw`, then `copy_token_spans` into reusable
//!   buffers and `token_feature(i)` for every token, with a per-word-id cache
//!   of data derived from the feature (the call pattern of span-based
//!   integrations that do not use views).
//! - `vibrato-num`: Vibrato `tokenize()` + `num_tokens()` (needs the
//!   `vibrato-bench` feature).
//! - `vibrato-sf`: Vibrato, reading `surface()` and `feature()` of every token.
//!
//! The byte/char sums printed to stderr keep the reads from being optimized
//! out and let runs be compared for identical output.

#[cfg(feature = "zig-ffi")]
fn main() {
    use std::io::BufRead;

    let args: Vec<String> = std::env::args().collect();
    let (Some(dic), Some(mode)) = (args.get(1), args.get(2)) else {
        eprintln!("usage: views_speed_bench <dictionary> <mode> < corpus.txt");
        std::process::exit(2);
    };
    let lines: Vec<String> = std::io::stdin()
        .lock()
        .lines()
        .map(|line| line.expect("read stdin line"))
        .collect();

    // Timed passes over the corpus with the same worker (default 1). Pass 1
    // is the cold run the harness measures; later passes show the steady
    // state once per-word state (decoded features, UTF-8 memo) is warm.
    let passes: usize = std::env::var("VIEWS_BENCH_PASSES")
        .ok()
        .and_then(|value| value.parse().ok())
        .unwrap_or(1)
        .max(1);
    let results = match mode.as_str() {
        "raw" | "views-len" | "views-sf" | "views-char" | "spans-feature" => {
            run_delarocha(dic, mode, &lines, passes)
        }
        "vibrato-num" | "vibrato-sf" => run_vibrato(dic, mode, &lines, passes),
        _ => {
            eprintln!("unknown mode {mode}");
            std::process::exit(2);
        }
    };
    for (pass, (elapsed, words, checksum)) in results.into_iter().enumerate() {
        let label = if pass == 0 {
            mode.clone()
        } else {
            format!("{mode}-pass{}", pass + 1)
        };
        println!("Elapsed-{label}: {} [sec]", elapsed.as_secs_f64());
        eprintln!("Words-{label}: {words}");
        eprintln!("Checksum-{label}: {checksum}");
    }
}

/// Elapsed time, token count and checksum of one timed pass.
#[cfg(feature = "zig-ffi")]
type PassResult = (std::time::Duration, usize, usize);

#[cfg(feature = "zig-ffi")]
fn run_delarocha(dic: &str, mode: &str, lines: &[String], passes: usize) -> Vec<PassResult> {
    let tokenizer = delarocha::ffi::ZigTokenizer::from_binary_path(dic).expect("load dictionary");
    let mut worker = tokenizer.create_worker().expect("create worker");
    (0..passes)
        .map(|_| delarocha_pass(&mut worker, mode, lines))
        .collect()
}

#[cfg(feature = "zig-ffi")]
fn delarocha_pass(
    worker: &mut delarocha::ffi::ZigWorker<'_>,
    mode: &str,
    lines: &[String],
) -> PassResult {
    use std::hint::black_box;

    let mut words = 0usize;
    let mut checksum = 0usize;
    let start = std::time::Instant::now();
    match mode {
        "raw" => {
            for line in lines {
                words += worker.tokenize_raw(line).expect("tokenize");
            }
        }
        "views-len" => {
            for line in lines {
                words += worker
                    .tokenize_borrowed_views(line)
                    .expect("tokenize")
                    .len();
            }
        }
        "views-sf" => {
            for line in lines {
                let views = worker.tokenize_borrowed_views(line).expect("tokenize");
                words += views.len();
                for view in views.iter() {
                    checksum += black_box(view.surface()).len() + black_box(view.feature()).len();
                }
            }
        }
        "views-char" => {
            for line in lines {
                let views = worker.tokenize_borrowed_views(line).expect("tokenize");
                words += views.len();
                for view in views.iter() {
                    let range = black_box(view.range_char());
                    checksum += range.end - range.start;
                }
            }
        }
        "spans-feature" => {
            let (mut starts, mut ends, mut word_ids) = (Vec::new(), Vec::new(), Vec::new());
            let mut first_fields = std::collections::HashMap::<u32, String>::new();
            for line in lines {
                let count = worker.tokenize_raw(line).expect("tokenize");
                starts.resize(count, 0);
                ends.resize(count, 0);
                word_ids.resize(count, 0);
                let copied = worker
                    .copy_token_spans(&mut starts, &mut ends, &mut word_ids)
                    .expect("copy spans");
                words += copied;
                for index in 0..copied {
                    let feature = worker.token_feature(index);
                    let first = first_fields
                        .entry(word_ids[index])
                        .or_insert_with(|| feature.split(',').next().unwrap_or("").to_owned());
                    checksum += black_box(&line[starts[index]..ends[index]]).len()
                        + feature.len()
                        + first.len();
                }
            }
        }
        _ => unreachable!(),
    }
    (start.elapsed(), words, checksum)
}

#[cfg(all(feature = "zig-ffi", feature = "vibrato-bench"))]
fn run_vibrato(dic: &str, mode: &str, lines: &[String], passes: usize) -> Vec<PassResult> {
    use std::io::BufReader;

    let file = std::fs::File::open(dic).expect("open Vibrato dictionary");
    let dictionary = if dic.ends_with(".zst") {
        let decoder = zstd::Decoder::new(file).expect("zstd decoder");
        vibrato::Dictionary::read(BufReader::new(decoder)).expect("read Vibrato dictionary")
    } else {
        vibrato::Dictionary::read(BufReader::new(file)).expect("read Vibrato dictionary")
    };
    let tokenizer = vibrato::Tokenizer::new(dictionary);
    let mut worker = tokenizer.new_worker();
    (0..passes)
        .map(|_| vibrato_pass(&mut worker, mode, lines))
        .collect()
}

#[cfg(all(feature = "zig-ffi", feature = "vibrato-bench"))]
fn vibrato_pass(
    worker: &mut vibrato::tokenizer::worker::Worker<'_>,
    mode: &str,
    lines: &[String],
) -> PassResult {
    use std::hint::black_box;

    let mut words = 0usize;
    let mut checksum = 0usize;
    let start = std::time::Instant::now();
    match mode {
        "vibrato-num" => {
            for line in lines {
                worker.reset_sentence(line);
                worker.tokenize();
                words += worker.num_tokens();
            }
        }
        "vibrato-sf" => {
            for line in lines {
                worker.reset_sentence(line);
                worker.tokenize();
                words += worker.num_tokens();
                for token in worker.token_iter() {
                    checksum += black_box(token.surface()).len() + black_box(token.feature()).len();
                }
            }
        }
        _ => unreachable!(),
    }
    (start.elapsed(), words, checksum)
}

#[cfg(all(feature = "zig-ffi", not(feature = "vibrato-bench")))]
fn run_vibrato(_dic: &str, mode: &str, _lines: &[String], _passes: usize) -> Vec<PassResult> {
    eprintln!("mode {mode} needs the `vibrato-bench` feature");
    std::process::exit(2);
}

#[cfg(not(feature = "zig-ffi"))]
fn main() {
    eprintln!("views_speed_bench needs the `zig-ffi` feature");
}
