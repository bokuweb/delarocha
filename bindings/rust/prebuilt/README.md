# Prebuilt Zig FFI Libraries

This directory contains static libraries built from `zig/src/lib.zig` for
common Rust targets. `build.rs` links these artifacts when the `zig-ffi`
feature is enabled, which lets downstream Rust crates use delarocha without
installing Zig.

Set `DELAROCHA_BUILD_ZIG=1` to ignore these artifacts and rebuild the static
library from Zig sources.

| Rust target                 | Zig target            | Mode         | File                 |
| --------------------------- | --------------------- | ------------ | -------------------- |
| `aarch64-apple-darwin`      | `aarch64-macos`       | ReleaseFast  | `libdelarocha_zig.a` |
| `x86_64-apple-darwin`       | `x86_64-macos`        | ReleaseFast  | `libdelarocha_zig.a` |
| `x86_64-unknown-linux-gnu`  | `x86_64-linux-gnu`    | ReleaseFast, `-fPIC` | `libdelarocha_zig.a` |
| `aarch64-unknown-linux-gnu` | `aarch64-linux-gnu`   | ReleaseFast, `-fPIC` | `libdelarocha_zig.a` |
| `x86_64-pc-windows-msvc`    | `x86_64-windows-msvc` | ReleaseFast  | `delarocha_zig.lib`  |
| `i686-pc-windows-msvc`      | `x86-windows-msvc`    | ReleaseFast  | `delarocha_zig.lib`  |
| `wasm32-unknown-unknown`    | `wasm32-freestanding` | ReleaseSmall | `libdelarocha_zig.a` |

## Regenerating

Rebuild the libraries whenever the Zig sources or the C ABI change. Use Zig
0.16.0 (the version CI uses) and run from the repository root, preferably on
macOS:

```bash
scripts/build_prebuilt.sh                        # all targets
scripts/build_prebuilt.sh x86_64-unknown-linux-gnu wasm32-unknown-unknown
```

The script reads the Rust-to-Zig target mapping from `build.rs` and uses the
same flags `build.rs` passes when building from source (`-O ReleaseFast`,
`ReleaseSmall` for WASM, `-fPIC` on Linux, `-static`), so the checked-in
artifacts match what `DELAROCHA_BUILD_ZIG=1` would produce.

### Darwin archive alignment

Apple's linker rejects static archives whose 64-bit Mach-O members do not
start at an 8-byte aligned file offset (`64-bit mach-o member ... not 8-byte
aligned`). Zig's archiver does not guarantee that alignment, and some local
linker versions accept a misaligned archive that the macOS CI linker rejects.
The script therefore repacks each Darwin archive after building:

```bash
ar x libdelarocha_zig.a && chmod 644 *.o
ZERO_AR_DATE=1 xcrun libtool -static -o libdelarocha_zig.a libdelarocha_zig_zcu.o
```

`xcrun libtool` only exists on macOS. On other hosts the script refuses to
build Darwin targets unless `DELAROCHA_DARWIN_REPACK=zig-ar` is set, in which
case it repacks with `zig ar --format=darwin` (also 8-byte aligned; the
checked-in archives are made with libtool).

Every Darwin archive is verified with `scripts/check_ar_alignment.py`, and CI
runs the same check on all platforms:

```bash
python3 scripts/check_ar_alignment.py
```

### Expected differences

Rebuilding from the same sources produces the same exported symbols and code.
Byte-level differences are expected and harmless: the objects embed the
absolute path of the checkout and Zig cache directory in debug info, plus
archive timestamps. Only commit regenerated libraries when the Zig sources
actually changed.
