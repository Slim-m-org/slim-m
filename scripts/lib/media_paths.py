# SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
"""Reads the server's media module for every place it names a file on disk.

test_backup_covers_every_media_file.py compares what this finds with what
backup_side_files.py declares, so a new kind of file cannot reach main with
nothing mirroring it.
"""
import re
from pathlib import Path

MEDIA_SRC = Path(__file__).resolve().parents[2] / "crates" / "slimm-server" / "src" / "media"

_TEST_MODULE = re.compile(r"#\[cfg\(test\)\]\s*(?:pub(?:\([^)]*\))?\s+)?mod\s+\w+\s*\{")
_ROOT_DIRECTORY = re.compile(r"\broot\s*\.join\(\s*\"([^\"]+)\"\s*\)")
_BUILDER = re.compile(r"(?<!fn )\b(attachments_dir|avatars_dir|avatar_path|attachment_path)\s*(\.join)?\s*\(")
_WRITER = re.compile(r"\bpub (?:async )?fn (write_\w+)\(")
_CHAR_LITERAL = re.compile(r"'(?:\\.|[^\\'])'")
_CONSTANT = r'\bconst {name}: &str = "([^"]*)";'


def strip_comments(text):
    """Drops `//` and `/* */` comments outside string and character literals."""
    out, i, n = [], 0, len(text)
    while i < n:
        if text[i] == '"':
            end = i + 1
            while end < n and text[end] != '"':
                end += 2 if text[end] == "\\" else 1
            out.append(text[i:end + 1])
            i = end + 1
        elif _CHAR_LITERAL.match(text, i):
            end = _CHAR_LITERAL.match(text, i).end()
            out.append(text[i:end])
            i = end
        elif text.startswith("//", i):
            i = text.find("\n", i) if "\n" in text[i:] else n
        elif text.startswith("/*", i):
            close = text.find("*/", i + 2)
            i = n if close < 0 else close + 2
        else:
            out.append(text[i])
            i += 1
    return "".join(out)


def production_code(text):
    """The source with comments gone and its trailing test module cut off."""
    code = strip_comments(text)
    found = _TEST_MODULE.search(code)
    return code[:found.start()] if found else code


def sources(media_src=MEDIA_SRC):
    files = sorted(path for path in Path(media_src).rglob("*.rs") if path.name != "tests.rs")
    return {path.relative_to(media_src).as_posix(): production_code(path.read_text())
            for path in files}


def _argument(code, start):
    """The text between the parenthesis at `start` and its match, on one line."""
    depth, i = 0, start
    while i < len(code):
        if code[i] == '"':
            i = code.index('"', i + 1)
        elif code[i] == "(":
            depth += 1
        elif code[i] == ")":
            depth -= 1
            if depth == 0:
                return " ".join(code[start + 1:i].split())
        i += 1
    return code[start + 1:].strip()


def directories(code_by_file):
    """Every directory the media root is given."""
    return {name for code in code_by_file.values() for name in _ROOT_DIRECTORY.findall(code)}


def file_names(code_by_file):
    """Every name joined onto the attachment or avatar directory, as (builder, expression)."""
    found = set()
    for code in code_by_file.values():
        for match in _BUILDER.finditer(code):
            is_directory = match.group(1).endswith("_dir")
            if is_directory != bool(match.group(2)):
                continue
            found.add((match.group(1), _argument(code, match.end() - 1)))
    return found


def writers(code_by_file):
    return {name for code in code_by_file.values() for name in _WRITER.findall(code)}


def constant(code_by_file, name):
    pattern = re.compile(_CONSTANT.format(name=name))
    for code in code_by_file.values():
        found = pattern.search(code)
        if found:
            return found.group(1)
    return None
