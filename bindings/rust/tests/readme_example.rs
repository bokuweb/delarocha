//! Runs the README "Quick start" examples against the fixture dictionary.
//!
//! The README code itself is compiled as `no_run` doctests in the crate-level
//! docs of `src/lib.rs`; keep all three in sync.

use std::fs::File;
use std::path::{Path, PathBuf};

fn fixture(name: &str) -> PathBuf {
    Path::new(env!("CARGO_MANIFEST_DIR"))
        .join("../../fixtures")
        .join(name)
}

#[cfg(feature = "zig-ffi")]
#[test]
fn readme_quick_start_zig() -> delarocha::Result<()> {
    use delarocha::ffi::ZigTokenizer;

    let temp_dir = tempfile::tempdir()?;
    let dic = temp_dir.path().join("fixture.dic");

    ZigTokenizer::write_binary_from_raw_paths(
        fixture("lex.csv"),
        fixture("matrix.def"),
        fixture("char.def"),
        fixture("unk.def"),
        &dic,
    )?;

    let tokenizer = ZigTokenizer::from_binary_path(&dic)?;
    let mut worker = tokenizer.create_worker()?;
    let mut output = Vec::new();
    for sentence in ["本とカレー", "本と"] {
        for token in worker.tokenize_borrowed_views(sentence)?.iter() {
            output.push(format!("{}\t{}", token.surface(), token.feature()));
        }
    }
    assert_eq!(
        output,
        ["本と\tcompound,book-and", "カレー\tnoun,curry", "本と\tcompound,book-and"]
    );
    Ok(())
}

#[test]
fn readme_quick_start_pure_rust() -> delarocha::Result<()> {
    let dictionary = delarocha::SystemDictionaryBuilder::from_readers(
        File::open(fixture("lex.csv"))?,
        File::open(fixture("matrix.def"))?,
        File::open(fixture("char.def"))?,
        File::open(fixture("unk.def"))?,
    )?;
    let tokenizer = delarocha::Tokenizer::new(dictionary);
    let mut worker = tokenizer.create_worker();
    let output: Vec<String> = worker
        .tokenize("本とカレー")?
        .iter()
        .map(|token| format!("{}\t{}", token.surface(), token.feature()))
        .collect();
    assert_eq!(output, ["本と\tcompound,book-and", "カレー\tnoun,curry"]);
    Ok(())
}

/// Extracts the bodies of fenced code blocks that open with `fence`.
fn code_blocks(text: &str, fence: &str) -> Vec<String> {
    let mut blocks = Vec::new();
    let mut current: Option<Vec<&str>> = None;
    for line in text.lines() {
        match current.as_mut() {
            None if line == fence => current = Some(Vec::new()),
            None => {}
            Some(_) if line == "```" => blocks.push(current.take().unwrap().join("\n")),
            Some(lines) => lines.push(line),
        }
    }
    blocks
}

/// The README Quick start blocks are not compiled directly; they must match
/// the `no_run` doctests in the crate docs (minus hidden `# ` lines).
#[test]
fn readme_quick_start_matches_crate_doctests() {
    let root = Path::new(env!("CARGO_MANIFEST_DIR"));
    let readme = std::fs::read_to_string(root.join("../../README.md")).unwrap();
    let lib = std::fs::read_to_string(root.join("src/lib.rs")).unwrap();
    let crate_docs: String = lib
        .lines()
        .filter_map(|line| line.strip_prefix("//!"))
        .map(|line| line.strip_prefix(' ').unwrap_or(line))
        .filter(|line| !line.starts_with("# "))
        .collect::<Vec<_>>()
        .join("\n");

    let readme_blocks = code_blocks(&readme, "```rust,no_run");
    let doc_blocks = code_blocks(&crate_docs, "```no_run");
    assert_eq!(readme_blocks.len(), 2, "README Quick start code blocks");
    assert_eq!(readme_blocks, doc_blocks);
}
