#!/usr/bin/env bash
# Regenerate the prebuilt Zig static libraries in bindings/rust/prebuilt/.
#
# Usage:
#   scripts/build_prebuilt.sh [--out-dir DIR] [RUST_TARGET ...]
#
# With no targets, every target mapped in bindings/rust/build.rs (`zig_target`)
# is rebuilt. Libraries are written to DIR/<rust-target>/ (default:
# bindings/rust/prebuilt). The Zig invocation mirrors build.rs exactly:
#
#   zig build-lib zig/src/lib.zig -O <mode> -static -target <zig-target> \
#       [-fPIC on Linux] -femit-bin=<lib>
#
# where <mode> is ReleaseSmall for wasm32-unknown-unknown and ReleaseFast
# otherwise, and <lib> is delarocha_zig.lib for *-msvc targets and
# libdelarocha_zig.a elsewhere. Keep this script in sync with build.rs.
#
# Darwin archives are repacked after building: Zig's archiver does not
# guarantee that the Mach-O member starts at an 8-byte aligned offset, and
# Apple's linker rejects misaligned 64-bit members. On macOS the repack uses
# `xcrun libtool -static` (with ZERO_AR_DATE=1 for reproducible headers). On
# other hosts, Darwin targets fail unless DELAROCHA_DARWIN_REPACK=zig-ar is set,
# which repacks with `zig ar --format=darwin` instead (aligned, but the
# checked-in archives are produced with libtool on macOS). Every Darwin archive
# is verified with scripts/check_ar_alignment.py.
#
# Requires Zig 0.16.0 (the version CI uses) and python3.

set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
build_rs="$repo_root/bindings/rust/build.rs"
zig_lib="$repo_root/zig/src/lib.zig"
out_dir="$repo_root/bindings/rust/prebuilt"
expected_zig_version="0.16.0"

die() {
    echo "build_prebuilt.sh: error: $*" >&2
    exit 1
}

targets=()
while [[ $# -gt 0 ]]; do
    case "$1" in
        --out-dir)
            [[ $# -ge 2 ]] || die "--out-dir needs a value"
            out_dir="$2"
            shift 2
            ;;
        -h | --help)
            sed -n '2,/^$/p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
            exit 0
            ;;
        -*)
            die "unknown option: $1"
            ;;
        *)
            targets+=("$1")
            shift
            ;;
    esac
done

command -v zig >/dev/null 2>&1 || die "zig is not on PATH (need Zig $expected_zig_version)"
command -v python3 >/dev/null 2>&1 || die "python3 is not on PATH"
zig_version="$(zig version)"
if [[ "$zig_version" != "$expected_zig_version" ]]; then
    echo "build_prebuilt.sh: warning: zig $zig_version found, CI uses $expected_zig_version" >&2
fi

# Rust target -> Zig target pairs, parsed from the `zig_target` match in build.rs
# so the two cannot drift apart.
mapping="$(
    sed -n '/^fn zig_target(/,/^}/p' "$build_rs" |
        sed -n 's/^[[:space:]]*"\([^"]*\)"[[:space:]]*=>[[:space:]]*"\([^"]*\)",.*/\1 \2/p'
)"
[[ -n "$mapping" ]] || die "could not parse the zig_target mapping from $build_rs"

zig_target_for() {
    awk -v t="$1" '$1 == t { print $2 }' <<<"$mapping"
}

if [[ ${#targets[@]} -eq 0 ]]; then
    while read -r rust_target _; do
        targets+=("$rust_target")
    done <<<"$mapping"
fi

host_os="$(uname -s)"
repack_mode=""
for rust_target in "${targets[@]}"; do
    [[ -n "$(zig_target_for "$rust_target")" ]] ||
        die "unknown target '$rust_target'; build.rs maps: $(awk '{print $1}' <<<"$mapping" | tr '\n' ' ')"
    if [[ "$rust_target" == *-apple-darwin && -z "$repack_mode" ]]; then
        if [[ "$host_os" == "Darwin" ]]; then
            command -v xcrun >/dev/null 2>&1 || die "xcrun not found; install the Xcode command line tools"
            repack_mode="libtool"
        elif [[ "${DELAROCHA_DARWIN_REPACK:-}" == "zig-ar" ]]; then
            repack_mode="zig-ar"
        else
            die "Darwin target '$rust_target' must be repacked with Apple's libtool, which needs a macOS host. \
Run this script on macOS, pass only non-Darwin targets, or set DELAROCHA_DARWIN_REPACK=zig-ar to repack with 'zig ar --format=darwin'."
        fi
    fi
done

work_dir="$(mktemp -d "${TMPDIR:-/tmp}/delarocha-prebuilt.XXXXXX")"
trap 'rm -rf "$work_dir"' EXIT

for rust_target in "${targets[@]}"; do
    zig_target="$(zig_target_for "$rust_target")"

    # Same decisions as build.rs: optimization_mode(), the Linux -fPIC branch,
    # and the MSVC library name.
    if [[ "$rust_target" == "wasm32-unknown-unknown" ]]; then
        mode="ReleaseSmall"
    else
        mode="ReleaseFast"
    fi
    extra_flags=()
    if [[ "$rust_target" == *-linux-* ]]; then
        extra_flags+=("-fPIC")
    fi
    if [[ "$rust_target" == *-msvc ]]; then
        lib_name="delarocha_zig.lib"
    else
        lib_name="libdelarocha_zig.a"
    fi

    target_work="$work_dir/$rust_target"
    mkdir -p "$target_work"
    echo "==> $rust_target (zig -target $zig_target -O $mode ${extra_flags[*]:-})"
    (
        cd "$target_work"
        zig build-lib "$zig_lib" -O "$mode" -static -target "$zig_target" \
            ${extra_flags[@]+"${extra_flags[@]}"} \
            "-femit-bin=$target_work/$lib_name"
    )

    if [[ "$rust_target" == *-apple-darwin ]]; then
        repack="$target_work/repack"
        mkdir -p "$repack"
        (
            cd "$repack"
            ar x "$target_work/$lib_name"
            rm -f __.SYMDEF*
            chmod 644 ./*.o
            objects=(./*.o)
            if [[ "$repack_mode" == "libtool" ]]; then
                ZERO_AR_DATE=1 xcrun libtool -static -o "$repack/$lib_name" "${objects[@]}"
            else
                zig ar --format=darwin rcsD "$repack/$lib_name" "${objects[@]}"
            fi
        )
        mv "$repack/$lib_name" "$target_work/$lib_name"
        python3 "$repo_root/scripts/check_ar_alignment.py" "$target_work/$lib_name"
    fi

    mkdir -p "$out_dir/$rust_target"
    mv "$target_work/$lib_name" "$out_dir/$rust_target/$lib_name"
    echo "    wrote $out_dir/$rust_target/$lib_name ($(wc -c <"$out_dir/$rust_target/$lib_name" | tr -d ' ') bytes)"
done
