use std::fs::File;
use std::io::{self, Read};

use delarocha::{Result, SystemDictionaryBuilder, Tokenizer};

fn main() {
    if let Err(err) = run() {
        eprintln!("{err}");
        std::process::exit(1);
    }
}

fn run() -> Result<()> {
    let mut args = std::env::args().skip(1);
    let mut lexicon = None;
    let mut matrix = None;
    let mut char_def = None;
    let mut unk_def = None;
    let mut ignore_space = false;
    let mut max_grouping_len = 0usize;
    let mut output = OutputMode::Mecab;

    while let Some(arg) = args.next() {
        match arg.as_str() {
            "--lex" => lexicon = args.next(),
            "--matrix" => matrix = args.next(),
            "--char" => char_def = args.next(),
            "--unk" => unk_def = args.next(),
            "-S" | "--ignore-space" => ignore_space = true,
            "-M" | "--max-grouping-len" => {
                max_grouping_len = args
                    .next()
                    .ok_or_else(|| {
                        delarocha::Error::InvalidDictionary("-M requires a value".into())
                    })?
                    .parse()
                    .map_err(|_| delarocha::Error::InvalidDictionary("invalid -M value".into()))?;
            }
            "-O" | "--output" => {
                output = match args.next().as_deref() {
                    Some("wakati") => OutputMode::Wakati,
                    Some("mecab") => OutputMode::Mecab,
                    Some(other) => {
                        return Err(delarocha::Error::InvalidDictionary(format!(
                            "unsupported output mode: {other}"
                        )));
                    }
                    None => {
                        return Err(delarocha::Error::InvalidDictionary(
                            "-O requires a value".into(),
                        ));
                    }
                }
            }
            "-h" | "--help" => {
                print_help();
                return Ok(());
            }
            other => {
                return Err(delarocha::Error::InvalidDictionary(format!(
                    "unknown argument: {other}"
                )));
            }
        }
    }

    let dictionary = SystemDictionaryBuilder::from_readers(
        File::open(required("--lex", lexicon)?)?,
        File::open(required("--matrix", matrix)?)?,
        File::open(required("--char", char_def)?)?,
        File::open(required("--unk", unk_def)?)?,
    )?;
    let tokenizer = Tokenizer::new(dictionary)
        .ignore_space(ignore_space)?
        .max_grouping_len(max_grouping_len);

    let mut input = String::new();
    io::stdin().read_to_string(&mut input)?;
    for line in input.lines() {
        let tokens = tokenizer.tokenize(line)?;
        match output {
            OutputMode::Mecab => {
                for token in tokens {
                    println!("{}\t{}", token.surface, token.feature);
                }
                println!("EOS");
            }
            OutputMode::Wakati => {
                println!(
                    "{}",
                    tokens
                        .iter()
                        .map(|token| token.surface.as_str())
                        .collect::<Vec<_>>()
                        .join(" ")
                );
            }
        }
    }

    Ok(())
}

#[derive(Clone, Copy)]
enum OutputMode {
    Mecab,
    Wakati,
}

fn required<'a>(name: &str, value: Option<String>) -> Result<String> {
    value.ok_or_else(|| delarocha::Error::InvalidDictionary(format!("{name} is required")))
}

fn print_help() {
    println!(
        "Usage: delarocha --lex lex.csv --matrix matrix.def --char char.def --unk unk.def [OPTIONS]\n\
         \n\
         Options:\n\
           -S, --ignore-space          Ignore SPACE category like MeCab\n\
           -M, --max-grouping-len N    Limit unknown grouping length\n\
           -O, --output mecab|wakati   Select output format"
    );
}
