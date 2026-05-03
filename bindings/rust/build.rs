use std::env;
use std::path::PathBuf;
use std::process::Command;

fn main() {
    println!("cargo:rerun-if-env-changed=CARGO_FEATURE_ZIG_FFI");
    println!("cargo:rerun-if-changed=../../zig/src/lib.zig");
    println!("cargo:rerun-if-changed=../../zig/src/dictionary.zig");
    println!("cargo:rerun-if-changed=../../zig/src/tokenizer.zig");
    println!("cargo:rerun-if-changed=../../zig/src/ffi.zig");
    println!("cargo:rerun-if-changed=../../zig/src/bench.zig");
    println!("cargo:rerun-if-changed=../../zig/build.zig");

    if env::var_os("CARGO_FEATURE_ZIG_FFI").is_none() {
        return;
    }

    let manifest_dir =
        PathBuf::from(env::var_os("CARGO_MANIFEST_DIR").expect("CARGO_MANIFEST_DIR is set"));
    let zig_lib = manifest_dir.join("../../zig/src/lib.zig");
    let out_dir = PathBuf::from(env::var_os("OUT_DIR").expect("OUT_DIR is set"));
    let target_os = env::var("CARGO_CFG_TARGET_OS").unwrap_or_default();
    let target_env = env::var("CARGO_CFG_TARGET_ENV").unwrap_or_default();
    let out_lib = if target_env == "msvc" {
        out_dir.join("delarocha_zig.lib")
    } else {
        out_dir.join("libdelarocha_zig.a")
    };

    let mut command = Command::new("zig");
    command
        .arg("build-lib")
        .arg(zig_lib)
        .args(["-O", "ReleaseFast", "-mcpu", "native", "-static"]);

    // Linux links this static Zig object into Rust test binaries, so it must be
    // position-independent. Without this, rust-lld rejects absolute relocations
    // in CI when building `--features zig-ffi`.
    if target_os == "linux" {
        command.arg("-fPIC");
    }

    let status = command
        .arg(format!("-femit-bin={}", out_lib.display()))
        .current_dir(&out_dir)
        .status()
        .expect("failed to invoke zig; install Zig or build without --features zig-ffi");

    assert!(status.success(), "zig build-lib failed");
    println!("cargo:rustc-link-search=native={}", out_dir.display());
    println!("cargo:rustc-link-lib=static=delarocha_zig");
}
