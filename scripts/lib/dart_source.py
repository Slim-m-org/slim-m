# SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
"""Shared text-scrubbing for source-reading hygiene gates over `.dart` files.

Extracted out of `scripts/check-error-surface.py`, which was the first gate
to need this: a raw substring or brace-counting scan over Dart source is
fooled by a comment or string literal that happens to contain the exact
shape being searched for. Any new source-reading gate over Dart files should
import `strip_block_comments` from here rather than writing its own scanner,
per this project's own rule that a source-reading gate must strip comments
and strings before matching.

Comments are always blanked. String contents are blanked only on request
(`blank_strings=True`), because some gates read a string's text on purpose.
"""


def strip_block_comments(text: str, blank_strings: bool = False) -> str:
    """Blanks `//` and `/* ... */` comment text to spaces, keeping every
    line and column where it was so line numbers downstream stay accurate.

    String-aware: a `//`, `/*` or `*/` inside a string literal is left alone
    rather than misread as a comment boundary, which would blank real code
    sitting between two such string literals. Single, double and triple
    quotes, raw strings and `${...}` interpolation are all lexed.

    Line comments are blanked, not just skipped, so a gate built on this
    cannot be fooled by a doc comment that happens to mention the exact
    code shape it is searching for.

    With [blank_strings] a string's contents are blanked too, delimiters and
    line breaks kept, so a test title or message that names a pattern is not
    counted as code. The code inside a `${...}` interpolation is kept.
    """
    out: list[str] = []
    _scan(text, 0, out, blank_strings, in_interpolation=False)
    return "".join(out)


def _scan(text: str, i: int, out: list[str], blank: bool, in_interpolation: bool) -> int:
    """Copies code from [i] and returns where it stopped: the end of [text], or
    just past the `}` that closes an interpolation."""
    n, depth = len(text), 0
    while i < n:
        c = text[i]
        if c in "'\"":
            i = _copy_string(text, i, out, blank, raw=_is_raw_prefix(text, i))
        elif text.startswith("//", i):
            i = _blank_line_comment(text, i, out)
        elif text.startswith("/*", i):
            i = _blank_block_comment(text, i, out)
        elif in_interpolation and c == "}" and depth == 0:
            out.append(c)
            return i + 1
        else:
            if in_interpolation and c in "{}":
                depth += 1 if c == "{" else -1
            out.append(c)
            i += 1
    return i


def _is_raw_prefix(text: str, quote_at: int) -> bool:
    """True when the quote at [quote_at] opens a Dart raw string, `r'...'`."""
    if quote_at == 0 or text[quote_at - 1] != "r":
        return False
    before = text[quote_at - 2] if quote_at >= 2 else " "
    return not (before.isalnum() or before in "_$")


def _copy_string(text: str, start: int, out: list[str], blank: bool, raw: bool) -> int:
    """Copies the literal opening at [start] through its closing quote.

    A backslash escapes the next character except in a raw string, where it
    is literal and `r'\\'` closes at its second quote. A single-line string
    also ends at a line break, which Dart never allows inside one, so a
    mis-lexed quote cannot swallow the rest of the file.
    """
    quote, n = text[start], len(text)
    delimiter = quote * 3 if text.startswith(quote * 3, start) else quote
    out.append(delimiter)
    i = start + len(delimiter)
    while i < n:
        if text.startswith(delimiter, i):
            out.append(delimiter)
            return i + len(delimiter)
        c = text[i]
        if c == "\n" and len(delimiter) == 1:
            return i
        if c == "\\" and not raw and i + 1 < n:
            out.append(_kept(text[i : i + 2], blank))
            i += 2
        elif c == "$" and not raw and text.startswith("{", i + 1):
            out.append("${")
            i = _scan(text, i + 2, out, blank, in_interpolation=True)
        else:
            out.append(_kept(c, blank))
            i += 1
    return i


def _kept(chars: str, blank: bool) -> str:
    if not blank:
        return chars
    return "".join(ch if ch in "\r\n" else " " for ch in chars)


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
