use std::env;
use std::path::{Path, PathBuf};
use std::process::Command;

fn main() {
    println!("cargo:rerun-if-env-changed=CARGO_FEATURE_ZIG_FFI");
    println!("cargo:rerun-if-env-changed=DELAROCHA_BUILD_ZIG");
    println!("cargo:rerun-if-changed=prebuilt");
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
    let target = env::var("TARGET").expect("TARGET is set");
    let zig_target = zig_target(&target);
    let target_os = env::var("CARGO_CFG_TARGET_OS").unwrap_or_default();
    let target_env = env::var("CARGO_CFG_TARGET_ENV").unwrap_or_default();
    let lib_name = if target_env == "msvc" {
        "delarocha_zig.lib"
    } else {
        "libdelarocha_zig.a"
    };

    let prebuilt_dir = manifest_dir.join("prebuilt").join(&target);
    let prebuilt_lib = prebuilt_dir.join(lib_name);
    if env::var_os("DELAROCHA_BUILD_ZIG").is_none() && prebuilt_lib.exists() {
        // Release artifacts are checked in for common targets so downstream
        // crates can use the Rust crate without installing Zig. Set
        // DELAROCHA_BUILD_ZIG=1 when developing delarocha itself and you need
        // to rebuild the native library from the current Zig sources.
        link_static_library(&prebuilt_dir);
        return;
    }

    let zig_lib = manifest_dir.join("../../zig/src/lib.zig");
    let out_dir = PathBuf::from(env::var_os("OUT_DIR").expect("OUT_DIR is set"));
    let out_lib = if target_env == "msvc" {
        out_dir.join("delarocha_zig.lib")
    } else {
        out_dir.join("libdelarocha_zig.a")
    };

    let mut command = Command::new("zig");
    command
        .arg("build-lib")
        .arg(zig_lib)
        .args(["-O", "ReleaseFast", "-static"])
        .args(["-target", zig_target]);

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
        .expect("failed to invoke zig; install Zig, use a supported prebuilt target, or build without --features zig-ffi");

    assert!(status.success(), "zig build-lib failed");
    link_static_library(&out_dir);
}

fn link_static_library(dir: &Path) {
    println!("cargo:rustc-link-search=native={}", dir.display());
    println!("cargo:rustc-link-lib=static=delarocha_zig");
}

fn zig_target(rust_target: &str) -> &str {
    match rust_target {
        "aarch64-apple-darwin" => "aarch64-macos",
        "x86_64-apple-darwin" => "x86_64-macos",
        "x86_64-unknown-linux-gnu" => "x86_64-linux-gnu",
        "aarch64-unknown-linux-gnu" => "aarch64-linux-gnu",
        "x86_64-pc-windows-msvc" => "x86_64-windows-msvc",
        "i686-pc-windows-msvc" => "x86-windows-msvc",
        "wasm32-unknown-unknown" => "wasm32-freestanding",
        _ => rust_target,
    }
}
