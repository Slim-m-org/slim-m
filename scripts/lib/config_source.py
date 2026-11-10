# SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
"""Shared comment-stripping for tests that read workflow, compose and Dockerfile text.

A raw substring check passes on a line someone commented out, so these tests read
`strip_comments(text)` instead.
"""


def strip_comments(text: str) -> str:
    """Drops whole-line and trailing `#` comments, keeping a `#` inside quotes."""
    out = []
    for line in text.splitlines():
        quote = None
        for i, ch in enumerate(line):
            if quote:
                quote = None if ch == quote else quote
            elif ch in "'\"":
                quote = ch
            elif ch == "#" and (i == 0 or line[i - 1] in " \t"):
                line = line[:i].rstrip()
                break
        out.append(line)
    return "\n".join(out)
