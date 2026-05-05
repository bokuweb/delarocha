#!/usr/bin/env python3
import argparse
import gzip
import hashlib
import shutil
import tarfile
import urllib.request
from pathlib import Path

IPADIC_URL = "https://deb.debian.org/debian/pool/main/m/mecab-ipadic/mecab-ipadic_2.7.0-20070801+main.orig.tar.gz"
IPADIC_SHA256 = "b62f527d881c504576baed9c6ef6561554658b175ce6ae0096a60307e49e3523"
SOURCE_DIR = "mecab-ipadic-2.7.0-20070801"


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--out-dir", default="public/dic")
    parser.add_argument("--work-dir", default="target/ipadic-playground")
    args = parser.parse_args()

    out_dir = Path(args.out_dir)
    work_dir = Path(args.work_dir)
    archive = work_dir / "mecab-ipadic-2.7.0-20070801.tar.gz"
    source_dir = work_dir / SOURCE_DIR

    work_dir.mkdir(parents=True, exist_ok=True)
    out_dir.mkdir(parents=True, exist_ok=True)

    if not archive.exists() or sha256(archive) != IPADIC_SHA256:
        download(archive)
    if sha256(archive) != IPADIC_SHA256:
        raise SystemExit(f"sha256 mismatch for {archive}")

    if not source_dir.exists():
        with tarfile.open(archive, "r:gz") as tar:
            safe_extract(tar, work_dir)

    write_gzip_text(out_dir / "lex.csv.gz", combined_lexicon(source_dir))
    write_gzip_text(out_dir / "matrix.def.gz", decode(source_dir / "matrix.def"))
    write_gzip_text(out_dir / "char.def.gz", decode(source_dir / "char.def"))
    write_gzip_text(out_dir / "unk.def.gz", decode(source_dir / "unk.def"))


def download(path: Path) -> None:
    tmp = path.with_suffix(path.suffix + ".tmp")
    with urllib.request.urlopen(IPADIC_URL) as response, tmp.open("wb") as output:
        shutil.copyfileobj(response, output)
    tmp.replace(path)


def safe_extract(tar: tarfile.TarFile, destination: Path) -> None:
    destination = destination.resolve()
    for member in tar.getmembers():
        target = (destination / member.name).resolve()
        if not str(target).startswith(str(destination) + "/"):
            raise SystemExit(f"refusing unsafe tar member: {member.name}")
    tar.extractall(destination)


def combined_lexicon(source_dir: Path) -> str:
    parts = []
    for csv_path in sorted(source_dir.glob("*.csv")):
        parts.append(decode(csv_path).rstrip("\n"))
    return "\n".join(part for part in parts if part) + "\n"


def decode(path: Path) -> str:
    return path.read_bytes().decode("euc_jp")


def write_gzip_text(path: Path, text: str) -> None:
    with gzip.open(path, "wt", encoding="utf-8", newline="") as output:
        output.write(text)


def sha256(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as input_file:
        for chunk in iter(lambda: input_file.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


if __name__ == "__main__":
    main()
