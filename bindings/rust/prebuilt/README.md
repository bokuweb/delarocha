# Prebuilt Zig FFI Libraries

This directory contains static libraries built from `zig/src/lib.zig` for
common Rust targets. `build.rs` links these artifacts when the `zig-ffi`
feature is enabled, which lets downstream Rust crates use delarocha without
installing Zig.

Set `DELAROCHA_BUILD_ZIG=1` to ignore these artifacts and rebuild the static
library from Zig sources.
