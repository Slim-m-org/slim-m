#!/usr/bin/env python3
# SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
"""Guard against `MediaQuery.of(context)` drifting back into the client.

`MediaQuery.of` subscribes a widget to every field of `MediaQueryData`, so one
that only needs the keyboard inset rebuilds on a text-scale or brightness
change. The scoped accessors (`sizeOf`, `viewInsetsOf`, `textScalerOf`, ...)
are the convention. `scripts/media-query-of-allow.txt` lists the rare call
site that needs the whole value, with a ceiling count per file.

Reads each tracked `client/**/*.dart` file's own text, comments and strings
stripped first. The history and the allowlist format are in docs/ci-details.md,
"The MediaQuery scope gate".
"""

import re
import subprocess
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent / "lib"))

from dart_source import strip_block_comments  # noqa: E402

ALLOWLIST_PATH = Path(__file__).resolve().parent / "media-query-of-allow.txt"
MEDIA_QUERY_OF = re.compile(r"MediaQuery\s*\.\s*(?:of|maybeOf)\s*\(")


def load_allowlist(path: Path) -> dict[str, int]:
    """Each listed path mapped to how many unscoped calls it may hold.

    A ceiling, not a blanket pass, and a count rather than a line number so an
    edit above a call does not move it. `N` after the path sets it; omitted, it is one.
    """
    allowed: dict[str, int] = {}
    for line in path.read_text().splitlines():
        stripped = line.strip()
        if not stripped or stripped.startswith("#"):
            continue
        entry = stripped.split("#", 1)[0].strip()
        if not entry:
            continue
        parts = entry.split()
        allowed[parts[0]] = int(parts[1]) if len(parts) > 1 else 1
    return allowed


def offenders_in(sources: dict[str, str], allowed: dict[str, int]) -> list[str]:
    """Which calls are over their file's ceiling, as `path:line`.

    Split out of [main] so it can be tested against files that do not exist.
    The end-to-end run reads the real repository, where no allowlisted file
    currently holds more than its ceiling - so the case this gate exists for is
    the one the real tree cannot exercise, and only a fixture can.

    The ceiling is per file, not per path: a listed file's own calls stay quiet
    up to its recorded count, and the next one is reported. An earlier version
    exempted the whole file, which is how a second, unrelated call was added to
    an allowlisted file with nothing failing.
    """
    offenders: list[str] = []
    for rel, source in sources.items():
        text = strip_block_comments(source, blank_strings=True)
        hits = [
            lineno
            for lineno, line in enumerate(text.splitlines(), start=1)
            if MEDIA_QUERY_OF.search(line)
        ]
        offenders.extend(f"{rel}:{lineno}" for lineno in hits[allowed.get(rel, 0):])
    return offenders


def main() -> int:
    root = Path(
        subprocess.run(
            ["git", "rev-parse", "--show-toplevel"],
            capture_output=True, text=True, check=True,
        ).stdout.strip()
    )
    files = subprocess.run(
        ["git", "ls-files", "--", "client/*.dart", "client/**/*.dart"],
        capture_output=True, text=True, check=True, cwd=root,
    ).stdout.splitlines()
    if not files:
        print("::error::no files matched client/**/*.dart; the gate is not reading anything")
        return 1

    allowed = load_allowlist(ALLOWLIST_PATH)

    offenders = offenders_in(
        {rel: (root / rel).read_text() for rel in files}, allowed
    )

    for offender in offenders:
        path, _, lineno = offender.partition(":")
        print(
            f"::error file={path},line={lineno}::MediaQuery.of(context) subscribes to every "
            "MediaQueryData field; use the scoped accessor this call site actually needs "
            "(MediaQuery.sizeOf, MediaQuery.viewInsetsOf, MediaQuery.textScalerOf, ...), or "
            f"if the whole MediaQueryData is genuinely needed, add '{path} # why' to "
            "scripts/media-query-of-allow.txt (or raise that entry's count, "
            "which is 1 when unwritten)"
        )

    print(f"MediaQuery.of: {len(files)} file(s) checked, {len(allowed)} allowlisted, {len(offenders)} offender(s)")
    return 1 if offenders else 0


if __name__ == "__main__":
    sys.exit(main())
