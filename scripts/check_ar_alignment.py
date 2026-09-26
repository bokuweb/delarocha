#!/usr/bin/env python3
"""Check that object members of Darwin static archives are 8-byte aligned.

Apple's linker rejects 64-bit Mach-O archive members whose data does not start
at an 8-byte aligned file offset ("64-bit mach-o member ... not 8-byte
aligned"). Some archivers (including Zig's) can emit 4-byte aligned members,
which older/local linkers accept but the macOS CI linker does not. This script
parses the `ar` container directly, so it runs on any OS.

Usage:
    check_ar_alignment.py [ARCHIVE ...]

With no arguments, every `bindings/rust/prebuilt/*-apple-darwin/*.a` archive in
the repository is checked. Exits non-zero if any member is misaligned or an
archive cannot be parsed.
"""

from __future__ import annotations

import sys
from pathlib import Path

AR_MAGIC = b"!<arch>\n"
HEADER_SIZE = 60
ALIGNMENT = 8


def members(data: bytes):
    """Yield (name, data_offset, size) for every archive member.

    For BSD long names (`#1/<len>`) the name is stored at the start of the
    member body, so the object data starts after it; that is the offset the
    linker checks.
    """
    if not data.startswith(AR_MAGIC):
        raise ValueError("not an ar archive (missing !<arch> magic)")
    offset = len(AR_MAGIC)
    while offset < len(data):
        if offset + HEADER_SIZE > len(data):
            raise ValueError(f"truncated member header at offset {offset}")
        header = data[offset : offset + HEADER_SIZE]
        if header[58:60] != b"`\n":
            raise ValueError(f"bad member header terminator at offset {offset}")
        raw_name = header[0:16].decode("ascii", "replace").rstrip()
        size = int(header[48:58].decode("ascii").strip())
        body = offset + HEADER_SIZE
        name = raw_name
        name_len = 0
        if raw_name.startswith("#1/"):
            name_len = int(raw_name[3:])
            name = data[body : body + name_len].rstrip(b"\0").decode("utf-8", "replace")
        if body + size > len(data):
            raise ValueError(f"member {name!r} extends past end of archive")
        yield name, body + name_len, size - name_len
        offset = body + size
        if offset % 2:
            offset += 1


def is_symbol_table(name: str) -> bool:
    return name.startswith("__.SYMDEF") or name in ("/", "//", "/SYM64/")


def check(path: Path) -> list[str]:
    errors = []
    data = path.read_bytes()
    try:
        entries = list(members(data))
    except ValueError as err:
        return [f"{path}: {err}"]
    objects = 0
    for name, data_offset, _size in entries:
        if is_symbol_table(name):
            continue
        objects += 1
        if data_offset % ALIGNMENT:
            errors.append(
                f"{path}: member {name!r} data starts at offset {data_offset}, "
                f"not {ALIGNMENT}-byte aligned (see bindings/rust/prebuilt/README.md)"
            )
    if objects == 0:
        errors.append(f"{path}: archive contains no object members")
    return errors


def main(argv: list[str]) -> int:
    if argv:
        paths = [Path(arg) for arg in argv]
    else:
        root = Path(__file__).resolve().parent.parent
        paths = sorted((root / "bindings/rust/prebuilt").glob("*-apple-darwin/*.a"))
        if not paths:
            print("no Darwin prebuilt archives found", file=sys.stderr)
            return 1
    errors = []
    for path in paths:
        found = check(path)
        errors.extend(found)
        if not found:
            print(f"ok: {path}")
    for error in errors:
        print(f"error: {error}", file=sys.stderr)
    return 1 if errors else 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
