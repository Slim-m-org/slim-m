#!/usr/bin/env python3
# SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
"""`data.dart` must never again re-export a drift row as `Message`.

TECHNICAL_DEBT CA1: most of `app` was transitively coupled to drift because
`data.dart` exported drift's generated `Message` `DataClass` under its own
column-for-column name rather than a plain boundary type, defeating
`CLAUDE.md`'s "storage layer allows a later Postgres swap" intent for every
caller that ever typed `Message`. The fix moved `Message` to a hand-written
DTO in `message_dto.dart`, mapped from the renamed drift row (`MessageRow`,
`database.dart`) in exactly one place (`MessageRowMapping.toDto`). This gate
pins that: it does not matter which file `data.dart` exports `Message` from
as long as that file's own `Message` is not drift-coupled, so a rename does
not need a matching edit here, but re-pointing the export back at a drift
`DataClass` - or reintroducing drift into whatever file it does come from -
fails it.

Reads `data.dart`'s own `export ... show ...;` declarations rather than
grepping the whole package for "Message": that would also match the
unrelated `api.Message` wire type, `MessageRow`, and every `Message*` widget
and provider name across `app`. Comments and string literals are stripped
first with the shared scrubber, per this project's own rule that a
source-reading gate must not be foolable by either - `strip_block_comments`
is exactly what `check-error-surface.py` already uses for the same reason,
so this reuses it rather than writing a second scanner.
"""

import re
import subprocess
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent / "lib"))

from dart_source import strip_block_comments  # noqa: E402

DATA_DART_REL = "client/packages/data/lib/data.dart"

EXPORT_RE = re.compile(r"export\s+'([^']+)'\s+show\s+([^;\s][^;]*);", re.DOTALL)

# Any one match means the exported `Message` is drift-coupled, not a plain DTO.
DRIFT_PATTERNS = (
    re.compile(r"drift/drift\.dart"),
    re.compile(r"\bextends\s+DataClass\b"),
    re.compile(r"\bimplements\s+Insertable\b"),
    re.compile(r"\bCompanion\b"),
    re.compile(r"(?<![A-Za-z0-9_])Value\s*[<(]"),
)


def _shown_names(clause: str) -> set[str]:
    return {n.strip() for n in clause.split(",") if n.strip()}


def main() -> int:
    root = Path(
        subprocess.run(
            ["git", "rev-parse", "--show-toplevel"],
            capture_output=True, text=True, check=True,
        ).stdout.strip()
    )
    data_dart = root / DATA_DART_REL
    if not data_dart.is_file():
        print(f"::error file={DATA_DART_REL}::expected file not found")
        return 1

    text = strip_block_comments(data_dart.read_text())
    exporters = [
        (match.group(1), _shown_names(match.group(2)))
        for match in EXPORT_RE.finditer(text)
    ]
    hits = [path for path, names in exporters if "Message" in names]

    if not hits:
        print(f"::error file={DATA_DART_REL}::"
              "no export shows a Message type at all")
        return 1
    if len(hits) > 1:
        print(f"::error file={DATA_DART_REL}::"
              f"Message is exported from more than one file: {hits}")
        return 1

    target = (data_dart.parent / hits[0]).resolve()
    if not target.is_file():
        print(f"::error file={hits[0]}::export target does not exist")
        return 1

    source = strip_block_comments(target.read_text())
    offenders = [p.pattern for p in DRIFT_PATTERNS if p.search(source)]
    if offenders:
        rel = target.relative_to(root)
        print(
            f"::error file={rel}::Message is exported from a drift-coupled "
            f"type ({', '.join(offenders)}); app must see a plain DTO, "
            "never a drift row - see TECHNICAL_DEBT CA1"
        )
        return 1

    print(f"message DTO boundary ok: Message exported from {hits[0]}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
