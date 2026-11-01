#!/usr/bin/env python3
# SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
"""Ratchet the `find.byType` and `pumpAndSettle` counts in the app tests.

A type finder pins the widget's name, so a rename breaks tests that assert
nothing about behaviour, and `pumpAndSettle` waits out an animation that never
settles instead of failing on it. Neither is banned: a file may keep what it
has, and none may gain more. The preferred helpers are `expectSettled`,
`waitUntil` (test/support/async_wait.dart) and the geometry helpers
(test/support/geometry.dart).

Each file's current counts are the ceiling listed in
`scripts/test-pattern-allow.txt` as `<path> <byType> <pumpAndSettle>`; a file
that is not listed has a ceiling of zero. `--update` rewrites the file with the
counts as they are now, which can only lower an entry: a count above its
ceiling is still an error and stays out of the rewrite. Comments are stripped
before counting, through `dart_source`.
"""
import re
import subprocess
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent / "lib"))

from dart_source import strip_block_comments  # noqa: E402

ALLOWLIST_PATH = Path(__file__).resolve().parent / "test-pattern-allow.txt"
TEST_GLOB = "client/packages/app/test/*.dart"
PATTERNS = {
    "find.byType": re.compile(r"\bfind\s*\.\s*byType\b"),
    "pumpAndSettle": re.compile(r"\bpumpAndSettle\b"),
}
HEADER = (
    "# SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0\n"
    "#\n"
    "# Ceilings for scripts/check-test-patterns.py: <path> <find.byType> <pumpAndSettle>.\n"
    "# Counts only go down; `python3 scripts/check-test-patterns.py --update` lowers them.\n"
)


def counts_in(source: str) -> tuple[int, int]:
    text = strip_block_comments(source)
    return tuple(len(p.findall(text)) for p in PATTERNS.values())


def load_allowlist(path: Path) -> dict[str, tuple[int, int]]:
    allowed: dict[str, tuple[int, int]] = {}
    for line in path.read_text().splitlines():
        entry = line.split("#", 1)[0].strip()
        if not entry:
            continue
        rel, by_type, settle = entry.split()
        allowed[rel] = (int(by_type), int(settle))
    return allowed


def over_ceiling(
    counts: dict[str, tuple[int, int]], allowed: dict[str, tuple[int, int]]
) -> list[str]:
    """One message per file whose count of either pattern is above its ceiling."""
    names = list(PATTERNS)
    problems = []
    for rel, found in sorted(counts.items()):
        ceiling = allowed.get(rel, (0, 0))
        for name, have, may in zip(names, found, ceiling):
            if have > may:
                problems.append(f"{rel}: {have} {name}, ceiling {may}")
    return problems


def lowered(
    counts: dict[str, tuple[int, int]], allowed: dict[str, tuple[int, int]]
) -> dict[str, tuple[int, int]]:
    """The allowlist with every entry cut to what the file holds now, and empty files dropped."""
    out = {}
    for rel, found in counts.items():
        ceiling = allowed.get(rel, (0, 0))
        entry = tuple(min(have, may) for have, may in zip(found, ceiling))
        if any(entry):
            out[rel] = entry
    return out


def render(allowed: dict[str, tuple[int, int]]) -> str:
    return HEADER + "".join(f"{rel} {a} {b}\n" for rel, (a, b) in sorted(allowed.items()))


def main(argv: list[str]) -> int:
    root = Path(
        subprocess.run(
            ["git", "rev-parse", "--show-toplevel"], capture_output=True, text=True, check=True
        ).stdout.strip()
    )
    files = subprocess.run(
        ["git", "ls-files", "--", TEST_GLOB], capture_output=True, text=True, check=True, cwd=root
    ).stdout.splitlines()
    if not files:
        print(f"::error::no files matched {TEST_GLOB}; the gate is not reading anything")
        return 1

    counts = {rel: counts_in((root / rel).read_text()) for rel in files}
    allowed = load_allowlist(ALLOWLIST_PATH)
    problems = over_ceiling(counts, allowed)
    for problem in problems:
        print(
            f"::error file={problem.split(':')[0]}::{problem.split(': ', 1)[1]}. "
            "Assert behaviour with expectSettled, waitUntil or the geometry helpers; "
            "see scripts/check-test-patterns.py"
        )

    if "--update" in argv:
        ALLOWLIST_PATH.write_text(render(lowered(counts, allowed)))
        print(f"rewrote {ALLOWLIST_PATH.name}")
    totals = [sum(found[i] for found in counts.values()) for i in range(2)]
    print(
        f"test patterns: {len(files)} file(s), {totals[0]} find.byType, "
        f"{totals[1]} pumpAndSettle, {len(problems)} over a ceiling"
    )
    return 1 if problems else 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
