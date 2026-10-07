# SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
"""Every name in a `required_checks` string must be some job's real name.

`verify-release-checks.sh` splits `REQUIRED_CHECKS` on `|` and compares each
entry to a check-run name by exact string. Nothing in the workflow graph
connects that string to the jobs it names, so renaming a job points the
release gate at a check that will never appear.

The verifier does notice - it fails with "either it never ran or
required_checks names it wrongly" - but only at release time, on `main`,
after the rename has merged. This asks the same question on the pull request.

Its sibling `test_release_required_checks_schema_gate.py` checks a different
property of the same string: that the entry it names can structurally *reach*
a release commit. A name can be a real job and still be unreachable, and a
name can be reachable-looking and match no job at all, so both are needed.

Parsed as text rather than through PyYAML for the reason that file gives: the
hygiene job runs this suite on a bare runner with no pip install step.
A job key sits at exactly two spaces and its `name:` at exactly four, which
is unambiguous because a step's own `name:` is indented six. If that layout
ever drifts the parser finds no names, every entry reads as missing and this
fails, which is the safe direction.
"""

import re
import unittest
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parent.parent.parent
WORKFLOWS = REPO_ROOT / ".github" / "workflows"
RELEASE_WORKFLOW = WORKFLOWS / "release.yml"

JOBS_LINE = re.compile(r"^jobs:\s*$")
JOB_KEY = re.compile(r"^  ([A-Za-z0-9_-]+):\s*$")
JOB_NAME = re.compile(r"^    name:\s*(.+?)\s*$")


def _job_names(text: str) -> list[str]:
    lines = text.splitlines()
    start = next((i for i, line in enumerate(lines) if JOBS_LINE.match(line)), None)
    if start is None:
        return []
    found: list[str] = []
    pending: str | None = None
    for line in lines[start + 1 :]:
        if line.strip() and not line.startswith(" "):
            break
        key = JOB_KEY.match(line)
        if key:
            if pending:
                found.append(pending)
            pending = key.group(1)
            continue
        name = JOB_NAME.match(line)
        if name and pending:
            found.append(name.group(1).strip("\"'"))
            pending = None
    if pending:
        found.append(pending)
    return found


class ReleaseRequiredChecksExistTest(unittest.TestCase):
    def setUp(self):
        self.all_names = []
        for path in sorted(WORKFLOWS.glob("*.yml")):
            self.all_names += _job_names(path.read_text())
        self.names = set(self.all_names)
        self.lists = re.findall(
            r'required_checks:\s*"([^"]*)"', RELEASE_WORKFLOW.read_text()
        )

    def test_the_parser_finds_jobs_at_all(self):
        self.assertGreater(
            len(self.names),
            20,
            "no job names were parsed out of .github/workflows/; the layout this "
            "reads has drifted and every check below would read as missing",
        )

    def test_every_required_check_names_a_real_job(self):
        self.assertTrue(self.lists, "no required_checks string found in release.yml")
        for entries in self.lists:
            for check in entries.split("|"):
                self.assertIn(
                    check,
                    self.names,
                    f"required_checks names {check!r}, which is no job's name in "
                    ".github/workflows/; the release gate would wait for a check "
                    "run that never appears",
                )

    def test_every_required_check_names_exactly_one_job(self):
        """Two jobs with one name let a green run of one stand in for the other."""
        for entries in self.lists:
            for check in entries.split("|"):
                self.assertEqual(
                    self.all_names.count(check),
                    1,
                    f"required_checks names {check!r}, which more than one job "
                    "in .github/workflows/ is called; give the others a distinct name:",
                )
