# SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
"""Shared text-scrubbing for source-reading hygiene gates over `.dart` files.

Extracted out of `scripts/check-error-surface.py`, which was the first gate
to need this: a raw substring or brace-counting scan over Dart source is
fooled by a comment or string literal that happens to contain the exact
shape being searched for. Any new source-reading gate over Dart files should
import `strip_block_comments` from here rather than writing its own scanner,
per this project's own rule that a source-reading gate must strip comments
and strings before matching.
"""


def strip_block_comments(text: str) -> str:
    """Blanks `//` and `/* ... */` comment text to spaces, keeping every
    line and column where it was so line numbers downstream stay accurate.

    String-aware: a `//`, `/*` or `*/` inside a `'...'` or `"..."` literal is
    left alone rather than misread as a comment boundary, which would blank
    real code sitting between two such string literals.

    Line comments are blanked, not just skipped, so a gate built on this
    cannot be fooled by a doc comment that happens to mention the exact
    code shape it is searching for.
    """
    out: list[str] = []
    i, n = 0, len(text)
    while i < n:
        if text[i] in "'\"":
            i = _copy_string(text, i, out)
        elif text.startswith("//", i):
            i = _blank_line_comment(text, i, out)
        elif text.startswith("/*", i):
            i = _blank_block_comment(text, i, out)
        else:
            out.append(text[i])
            i += 1
    return "".join(out)


def _copy_string(text: str, start: int, out: list[str]) -> int:
    """Copies the literal opening at [start] through its closing quote, escapes included."""
    quote, i, n = text[start], start + 1, len(text)
    out.append(quote)
    while i < n:
        c = text[i]
        if c == "\\" and i + 1 < n:
            out.append(text[i : i + 2])
            i += 2
            continue
        out.append(c)
        i += 1
        if c == quote:
            break
    return i


def _blank_line_comment(text: str, start: int, out: list[str]) -> int:
    end = text.find("\n", start)
    end = len(text) if end == -1 else end
    out.append(" " * (end - start))
    return end


def _blank_block_comment(text: str, start: int, out: list[str]) -> int:
    end = text.find("*/", start + 2)
    end = len(text) if end == -1 else end + 2
    out.append("".join("\n" if ch == "\n" else " " for ch in text[start:end]))
    return end
