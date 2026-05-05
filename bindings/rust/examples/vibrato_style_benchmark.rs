#[cfg(feature = "zig-ffi")]
use std::hint::black_box;
#[cfg(feature = "zig-ffi")]
use std::io::BufRead;
#[cfg(feature = "zig-ffi")]
use std::path::PathBuf;
#[cfg(feature = "zig-ffi")]
use std::time::Instant;

#[cfg(feature = "zig-ffi")]
const RUNS: usize = 10;
#[cfg(feature = "zig-ffi")]
const TRIALS: usize = 10;

#[cfg(feature = "zig-ffi")]
fn main() -> Result<(), Box<dyn std::error::Error>> {
    let args = Args::parse()?;
    let tokenizer = if args.full {
        TokenizerMode::Full(delarocha::ffi::ZigTokenizer::from_binary_path(&args.dic)?)
    } else {
        TokenizerMode::CountOnly(delarocha::ffi::ZigTokenizer::count_only_from_binary_path(
            &args.dic,
        )?)
    };
    let mut worker = tokenizer.create_worker()?;

    let lines: Vec<_> = std::io::stdin().lock().lines().collect::<Result<_, _>>()?;

    let mut measure = |timer: &mut Timer| {
        let mut n_words = 0usize;
        for _ in 0..args.runs {
            timer.start();
            for line in &lines {
                n_words = n_words.wrapping_add(worker.benchmark_tokenize_count(line, args.full));
            }
            timer.stop();
        }
        dbg!(n_words);
    };

    let mut timer = Timer::new();

    timer.reset();
    measure(&mut timer);
    println!("Warmup: {}", timer.average());

    let (mut min, mut max, mut avg) = (0.0, 0.0, 0.0);
    for _ in 0..args.trials {
        timer.reset();
        measure(&mut timer);
        timer.discard_min();
        timer.discard_max();
        min += timer.min();
        avg += timer.average();
        max += timer.max();
    }

    min /= args.trials as f64;
    avg /= args.trials as f64;
    max /= args.trials as f64;

    println!("Number_of_sentences: {}", lines.len());
    println!("Elapsed_seconds_to_tokenize_all_sentences: [{min},{avg},{max}]");

    Ok(())
}

#[cfg(not(feature = "zig-ffi"))]
fn main() {
    eprintln!("build with --features zig-ffi");
}

#[cfg(feature = "zig-ffi")]
struct Args {
    dic: PathBuf,
    full: bool,
    runs: usize,
    trials: usize,
}

#[cfg(feature = "zig-ffi")]
impl Args {
    fn parse() -> Result<Self, Box<dyn std::error::Error>> {
        let mut dic = None;
        let mut full = false;
        let mut runs = RUNS;
        let mut trials = TRIALS;
        let mut args = std::env::args_os().skip(1);
        while let Some(arg) = args.next() {
            match arg.to_string_lossy().as_ref() {
                "-i" | "--dic" | "--binary-dic" => {
                    dic = args.next().map(PathBuf::from);
                }
                "--full" => full = true,
                "--runs" => {
                    runs = args
                        .next()
                        .ok_or("missing value for --runs")?
                        .to_string_lossy()
                        .parse()?;
                }
                "--trials" => {
                    trials = args
                        .next()
                        .ok_or("missing value for --trials")?
                        .to_string_lossy()
                        .parse()?;
                }
                "-h" | "--help" => {
                    print_help();
                    std::process::exit(0);
                }
                other => return Err(format!("unknown argument: {other}").into()),
            }
        }

        if runs < 3 {
            return Err("--runs must be at least 3 because min/max runs are discarded".into());
        }
        if trials == 0 {
            return Err("--trials must be greater than 0".into());
        }

        Ok(Self {
            dic: dic.ok_or("set -i/--dic to a delarocha binary dictionary")?,
            full,
            runs,
            trials,
        })
    }
}

#[cfg(feature = "zig-ffi")]
fn print_help() {
    println!(
        "Usage: vibrato_style_benchmark -i <delarocha.dic> [--full] [--runs N] [--trials N]\n\n\
         Reads newline-separated sentences from stdin and prints the same summary fields as \
         daac-tools/vibrato's benchmark runner. Defaults match Vibrato: RUNS=10, TRIALS=10."
    );
}

#[cfg(feature = "zig-ffi")]
enum TokenizerMode {
    CountOnly(delarocha::ffi::ZigTokenizer),
    Full(delarocha::ffi::ZigTokenizer),
}

#[cfg(feature = "zig-ffi")]
impl TokenizerMode {
    fn create_worker(&self) -> delarocha::Result<delarocha::ffi::ZigWorker<'_>> {
        match self {
            Self::CountOnly(tokenizer) | Self::Full(tokenizer) => tokenizer.create_worker(),
        }
    }
}

#[cfg(feature = "zig-ffi")]
trait BenchmarkWorker {
    fn benchmark_tokenize_count(&mut self, input: &str, full: bool) -> usize;
}

#[cfg(feature = "zig-ffi")]
impl BenchmarkWorker for delarocha::ffi::ZigWorker<'_> {
    fn benchmark_tokenize_count(&mut self, input: &str, full: bool) -> usize {
        if full {
            self.tokenize(black_box(input))
                .expect("full tokenization succeeds")
                .len()
        } else {
            self.tokenize_count_assume_valid(black_box(input))
        }
    }
}

#[cfg(feature = "zig-ffi")]
struct Timer {
    times: Vec<f64>,
    start: Instant,
}

#[cfg(feature = "zig-ffi")]
impl Timer {
    fn new() -> Self {
        Self {
            times: Vec::new(),
            start: Instant::now(),
        }
    }

    fn start(&mut self) {
        self.start = Instant::now();
    }

    fn stop(&mut self) {
        self.times.push(self.start.elapsed().as_secs_f64());
    }

    fn reset(&mut self) {
        self.times.clear();
    }

    fn min(&self) -> f64 {
        self.times.iter().copied().reduce(f64::min).unwrap()
    }

    fn max(&self) -> f64 {
        self.times.iter().copied().reduce(f64::max).unwrap()
    }

    fn discard_min(&mut self) {
        let (index, _) = self
            .times
            .iter()
            .copied()
            .enumerate()
            .min_by(|(_, lhs), (_, rhs)| lhs.partial_cmp(rhs).unwrap())
            .unwrap();
        self.times.remove(index);
    }

    fn discard_max(&mut self) {
        let (index, _) = self
            .times
            .iter()
            .copied()
            .enumerate()
            .min_by(|(_, lhs), (_, rhs)| rhs.partial_cmp(lhs).unwrap())
            .unwrap();
        self.times.remove(index);
    }

    fn average(&self) -> f64 {
        self.times.iter().sum::<f64>() / self.times.len() as f64
    }
}
