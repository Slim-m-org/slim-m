#!/usr/bin/env python3
# SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
"""Keep hand-written Dart from being split with `part` files.

CLAUDE.md: split a big Dart file by extracting real classes or widgets into
their own libraries, never with `part` files; `part` is for generated code only.
A part shares the private scope of the library it joins, so every member of a
split class can reach every other member's private state, and the mixins that
were split off declare abstract private getters that another part implements.
Nothing in the compiler marks where one concern ends, and any change needs a
whole-group read. `VoiceSession` grew that way (ten parts) and the pattern had
spread to the canvas packages and `events.dart` before anything looked for it.

This gate counts the `part '...';` directives of each tracked `client/**/*.dart`
file, skipping the ones that name a generated file (`.g.dart`, `.freezed.dart`,
`.mocks.dart`). Comments and string literals are stripped first, so a doc
comment or a fixture string that shows a directive is never counted.

`scripts/part-file-allow.txt` holds the hand-written parts that predate the
gate, one `<path> <count> # why` line per library. The count only goes down: a
file may not gain a part, and a file that lost some must lower its entry (or
drop it) so the list shrinks with the work instead of hiding new parts.
"""

import re
import subprocess
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent / "lib"))

from dart_source import strip_block_comments  # noqa: E402

ALLOWLIST_PATH = Path(__file__).resolve().parent / "part-file-allow.txt"
GENERATED_SUFFIXES = (".g.dart", ".freezed.dart", ".mocks.dart")
BLANKED_DIRECTIVE = re.compile(r"^\s*part\s+(['\"])\s*\1\s*;")
TARGET = re.compile(r"""^\s*part\s+(['"])(?P<target>.*?)\1\s*;""")


def load_allowlist(path: Path) -> dict[str, int]:
    """Each listed path mapped to how many hand-written parts it may hold."""
    allowed: dict[str, int] = {}
    for line in path.read_text().splitlines():
        entry = line.split("#", 1)[0].strip()
        if not entry:
            continue
        parts = entry.split()
        if len(parts) != 2 or not parts[1].isdigit():
            raise ValueError(f"'{line}' is not '<path> <count> # why'")
        allowed[parts[0]] = int(parts[1])
    return allowed


def hand_written_parts(source: str) -> list[int]:
    """Line numbers of the `part '...';` directives that name hand-written files.

    The directive is found in the string-blanked text, so one that only appears
    inside a comment or a string is not seen, and read back from the original
    line to learn which file it names.
    """
    blanked = strip_block_comments(source, blank_strings=True).splitlines()
    original = source.splitlines()
    found = []
    for index, line in enumerate(blanked):
        if not BLANKED_DIRECTIVE.match(line):
            continue
        named = TARGET.match(original[index])
        if named and not named["target"].endswith(GENERATED_SUFFIXES):
            found.append(index + 1)
    return found


def problems_in(sources: dict[str, str], allowed: dict[str, int]) -> list[str]:
    """What is wrong with the parts in [sources] against the ceilings in [allowed].

    Split out of [main] so it can be tested against files that do not exist.
    """
    problems: list[str] = []
    counts = {rel: hand_written_parts(text) for rel, text in sources.items()}
    for rel, lines in counts.items():
        ceiling = allowed.get(rel, 0)
        if len(lines) > ceiling:
            problems.append(
                f"{rel}:{lines[ceiling]}: a new `part` directive; extract a real class "
                "into its own library instead (part is for generated code only)"
            )
    for rel, ceiling in allowed.items():
        if rel not in sources:
            problems.append(f"{rel}: listed in {ALLOWLIST_PATH.name} but not a tracked Dart file; drop the entry")
        elif len(counts[rel]) < ceiling:
            problems.append(
                f"{rel}: holds {len(counts[rel])} part(s) but is listed at {ceiling}; "
                f"lower the entry in {ALLOWLIST_PATH.name} to {len(counts[rel])} (or drop it at 0)"
            )
    return problems


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
    problems = problems_in({rel: (root / rel).read_text() for rel in files}, allowed)

    for problem in problems:
        location, _, message = problem.partition(": ")
        print(f"::error file={location.split(':')[0]}::{message}")

    print(f"part files: {len(files)} file(s) checked, {len(allowed)} allowlisted, {len(problems)} problem(s)")
    return 1 if problems else 0


if __name__ == "__main__":
    sys.exit(main())
