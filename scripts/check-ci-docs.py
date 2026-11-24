#!/usr/bin/env python3
# SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
"""Every workflow appears in the table `docs/ci.md` opens with.

CLAUDE.md sends a reviewer to `docs/ci.md` as the authoritative list before
judging any workflow, and that instruction is only as good as the list. Six
of twenty-one workflows were missing from it when this was written, and one
of the six was the reason it mattered: `desktop-clients.yml` held
`contents: write` and uploaded release assets while declaring no
`environment`, unlike every asset-publishing job in `release.yml`. Nobody
reviewing the documented set could have noticed, because it was not in the
documented set.

So this checks the direction that actually rots. A workflow is added far more
often than the table is remembered, and an undocumented workflow is invisible
rather than wrong-looking, which is the kind of gap that survives review.

The reverse direction is checked too, since a row naming a workflow that no
longer exists sends a reader looking for a file that was deleted or renamed.

Only the glance table is required. A dedicated prose section is not: several
workflows are adequately described by their row, and demanding a section for
each would push toward padding rather than explanation.
"""

import pathlib
import re
import sys

ROOT = pathlib.Path(__file__).resolve().parent.parent
WORKFLOWS = ROOT / ".github" / "workflows"
DOC = ROOT / "docs" / "ci.md"

# A row opens with the workflow's file stem in backticks, as every row does.
ROW = re.compile(r"^\|\s*`([a-z0-9._-]+)`\s*\|", re.MULTILINE)


def main() -> int:
    if not DOC.exists():
        print(f"::error file=docs/ci.md::{DOC} is missing")
        return 1

    stray = sorted(p.name for p in WORKFLOWS.iterdir() if p.is_file() and p.suffix != ".yml")
    for name in stray:
        print(f"::error file=.github/workflows/{name}::workflows must end in .yml, the one suffix every gate globs")

    on_disk = {p.stem for p in sorted(WORKFLOWS.glob("*.yml"))}
    documented = set(ROW.findall(DOC.read_text(encoding="utf-8")))

    undocumented = sorted(on_disk - documented)
    stale = sorted(documented - on_disk)

    for stem in undocumented:
        print(
            f"::error file=.github/workflows/{stem}.yml::"
            f"not in the table in docs/ci.md; add a row saying what it runs on "
            f"and what it gates"
        )
    for stem in stale:
        print(
            f"::error file=docs/ci.md::the table lists `{stem}`, "
            f"which no longer exists in .github/workflows/"
        )

    print(
        f"ci docs: {len(on_disk)} workflows, {len(undocumented)} undocumented, "
        f"{len(stale)} stale row(s)"
    )
    return 1 if undocumented or stale or stray else 0


if __name__ == "__main__":
    sys.exit(main())
