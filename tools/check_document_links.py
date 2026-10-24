#!/usr/bin/env python3
"""Check owned Markdown links offline, including in a Git-free source export.

CommonMark tokens distinguish rendered links/images from code examples. HTML
href/src and explicit ids are included. Check local paths and GitHub heading
fragments; accept source-line fragment syntax used by historical audit citations.
Remote destinations are never requested.
"""

import argparse
from dataclasses import dataclass
from html.parser import HTMLParser
import os
from pathlib import Path
import re
import unicodedata
from urllib.parse import unquote, urlsplit

from markdown_it import MarkdownIt
from markdown_it.token import Token


EXCLUDED = {
    ".git", ".venv", ".venv-litert", ".dart_tool", ".pytest_cache",
    "__pycache__", "build", "dist", "third_party", "node_modules",
}
SOURCE_LINE = re.compile(r"L[1-9][0-9]*(?:-L[1-9][0-9]*)?")


@dataclass(frozen=True)
class Link:
    line: int
    target: str


class HtmlLinks(HTMLParser):
    def __init__(self, first_line: int) -> None:
        super().__init__(convert_charrefs=True)
        self.first_line = first_line
        self.links: list[Link] = []
        self.ids: set[str] = set()

    def handle_starttag(self, tag: str, attrs: list[tuple[str, str | None]]) -> None:
        for key, value in attrs:
            if value is None:
                continue
            if key == "id" or (tag == "a" and key == "name"):
                self.ids.add(value)
            elif key in {"href", "src"}:
                self.links.append(Link(self.first_line + self.getpos()[0] - 1, value))


def _html(content: str, line: int, result: list[Link], ids: set[str]) -> None:
    parser = HtmlLinks(line)
    parser.feed(content)
    result.extend(parser.links)
    ids.update(parser.ids)


def links(text: str) -> tuple[list[Link], set[str]]:
    result: list[Link] = []
    ids: set[str] = set()
    for block in MarkdownIt("commonmark").parse(text):
        line = block.map[0] + 1 if block.map else 1
        if block.type == "html_block":
            _html(block.content, line, result, ids)
        elif block.type == "inline":
            for child in block.children or []:
                if child.type in {"link_open", "image"}:
                    target = child.attrGet("src" if child.type == "image" else "href")
                    if isinstance(target, str):
                        result.append(Link(line, target))
                elif child.type == "html_inline":
                    _html(child.content, line, result, ids)
                line += 1 if child.type in {"softbreak", "hardbreak"} else child.content.count("\n")
    return result, ids


def _heading_text(children: list[Token]) -> str:
    return "".join(
        " " if token.type in {"softbreak", "hardbreak"} else token.content
        for token in children
        if token.type in {"text", "code_inline", "image", "softbreak", "hardbreak"}
    )


def anchors(text: str) -> set[str]:
    _, used = links(text)
    tokens = MarkdownIt("commonmark").parse(text)
    for index, token in enumerate(tokens):
        if token.type != "heading_open":
            continue
        value = _heading_text(tokens[index + 1].children or []).lower()
        slug = "".join(
            "-" if char.isspace() else char
            for char in value
            if char.isspace() or char in {"-", "_"}
            or unicodedata.category(char)[0] in {"L", "M", "N"}
        )
        candidate, count = slug, 0
        while candidate in used:
            count += 1
            candidate = f"{slug}-{count}"
        used.add(candidate)
    return used


def check(root: Path) -> tuple[int, list[str]]:
    root = root.resolve()
    if not root.is_dir():
        raise ValueError("Documentation root must be an existing directory")
    problems: list[str] = []
    count = 0
    documents: list[Path] = []
    for directory, children, filenames in os.walk(root):
        children[:] = sorted(name for name in children if name not in EXCLUDED)
        documents.extend(Path(directory) / name for name in sorted(filenames)
                         if name.endswith(".md"))
    fragments: dict[Path, set[str]] = {}
    for document in documents:
        if document.is_symlink():
            continue
        for link in links(document.read_text(encoding="utf-8"))[0]:
            location = f"{document.relative_to(root)}:{link.line}: {link.target!r}"
            try:
                url = urlsplit(link.target)
            except ValueError:
                problems.append(f"{location}: invalid destination")
                continue
            if url.scheme or url.netloc:
                continue
            count += 1
            base = root if url.path.startswith("/") else document.parent
            target = (base / unquote(url.path).lstrip("/")).resolve() if url.path else document
            if not target.is_relative_to(root):
                problems.append(f"{location}: leaves repository")
            elif not target.exists():
                problems.append(f"{location}: missing path")
            elif url.fragment:
                if target.is_dir():
                    target = target / "README.md"
                fragment = unquote(url.fragment)
                if SOURCE_LINE.fullmatch(fragment):
                    continue
                if target.suffix.lower() == ".md" and target.is_file():
                    if target not in fragments:
                        fragments[target] = anchors(target.read_text(encoding="utf-8"))
                    if fragment not in fragments[target]:
                        problems.append(f"{location}: missing heading or anchor")
                else:
                    problems.append(f"{location}: unsupported file fragment")
    return count, problems


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--root", type=Path, default=Path(__file__).resolve().parents[1])
    args = parser.parse_args()
    try:
        count, problems = check(args.root)
    except ValueError as error:
        parser.error(str(error))
    for problem in problems:
        print(problem)
    print(f"Checked {count} local links; {len(problems)} problems")
    return int(bool(problems))


if __name__ == "__main__":
    raise SystemExit(main())
