#!/usr/bin/env python3
"""Extract normalized visible text from Yokohama's ordinance HTML.

The tokenizer benchmark in `bindings/rust/examples/yokohama_text_bench.rs`
expects plain UTF-8 text. This helper keeps the input generation reproducible
without committing the downloaded ordinance HTML or extracted 600 KiB text.
"""

from __future__ import annotations

import argparse
from html import unescape
from html.parser import HTMLParser
from pathlib import Path


class VisibleTextExtractor(HTMLParser):
    """Collect visible text while preserving block boundaries as newlines."""

    def __init__(self) -> None:
        super().__init__(convert_charrefs=True)
        self._skip_depth = 0
        self.parts: list[str] = []

    def handle_starttag(self, tag: str, attrs: list[tuple[str, str | None]]) -> None:
        del attrs
        if tag in {"script", "style", "noscript"}:
            self._skip_depth += 1
        elif tag in {"p", "div", "br", "li", "h1", "h2", "h3", "tr"}:
            self.parts.append("\n")

    def handle_endtag(self, tag: str) -> None:
        if tag in {"script", "style", "noscript"} and self._skip_depth:
            self._skip_depth -= 1
        elif tag in {"p", "div", "li", "h1", "h2", "h3", "tr"}:
            self.parts.append("\n")

    def handle_data(self, data: str) -> None:
        if not self._skip_depth:
            self.parts.append(data)


def extract_text(html: str) -> str:
    """Return newline-separated visible text with intra-line whitespace folded."""

    parser = VisibleTextExtractor()
    parser.feed(html)
    text = unescape("".join(parser.parts))
    lines = (" ".join(line.split()) for line in text.splitlines())
    return "\n".join(line for line in lines if line)


def main() -> None:
    arg_parser = argparse.ArgumentParser(
        description="Extract normalized visible text from a saved Yokohama ordinance HTML file.",
    )
    arg_parser.add_argument("html", type=Path, help="input HTML path")
    arg_parser.add_argument("text", type=Path, help="output UTF-8 text path")
    args = arg_parser.parse_args()

    html = args.html.read_text(encoding="utf-8")
    args.text.write_text(extract_text(html) + "\n", encoding="utf-8")


if __name__ == "__main__":
    main()
