# SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
"""Drives `scripts/report-advisory-issue.sh` against a fake `gh`.

A fake on PATH rather than a dry-run flag, deliberately: a dry run would only
prove that a status string reaches the right branch, where the thing actually
worth guarding is which `gh` subcommand each branch invokes - that an already
open issue is left alone rather than duplicated every day, and that a clean
scan closes one rather than silently leaving it open forever.

The fake records its own argv, so an assertion reads what the script really
did instead of what it printed about itself.
"""

from __future__ import annotations

import os
import subprocess
import tempfile
import textwrap
import unittest
from pathlib import Path

SCRIPT = Path(__file__).resolve().parents[1] / "report-advisory-issue.sh"

FAKE_GH = """#!/usr/bin/env bash
echo "$@" >> "$GH_CALLS"
# `issue list` is the only call the script reads a value back from.
if [ "$1" = "issue" ] && [ "$2" = "list" ]; then
  printf '%s' "${FAKE_EXISTING_ISSUE:-}"
fi
exit 0
"""


def run(
    tmp_path: Path, status: str, existing: str = "", extra: dict[str, str] | None = None
) -> list[str]:
    """Runs the script with a fake `gh`, returning that fake's recorded calls."""
    bin_dir = tmp_path / "bin"
    bin_dir.mkdir(exist_ok=True)
    gh = bin_dir / "gh"
    gh.write_text(FAKE_GH)
    gh.chmod(0o755)
    calls = tmp_path / "calls.txt"
    calls.write_text("")

    env = dict(os.environ)
    env.update(
        PATH=f"{bin_dir}:{env['PATH']}",
        GH_CALLS=str(calls),
        FAKE_EXISTING_ISSUE=existing,
        GITHUB_REPOSITORY="owner/repo",
        ADVISORY_STATUS=status,
        RUN_URL="https://example.invalid/run/1",
    )
    env.update(extra or {})
    subprocess.run(["bash", str(SCRIPT)], env=env, check=True, capture_output=True)
    return [line for line in calls.read_text().splitlines() if line]


class ReportAdvisoryIssueTest(unittest.TestCase):
    """Was seven bare functions, which `unittest discover` never collected."""

    def setUp(self) -> None:
        scratch = tempfile.TemporaryDirectory()
        self.addCleanup(scratch.cleanup)
        self.tmp_path = Path(scratch.name)

    def test_a_found_advisory_opens_an_issue(self) -> None:
        calls = run(self.tmp_path, "found")
        self.assertTrue(any(c.startswith("issue create") for c in calls), calls)


    def test_the_issue_names_which_lockfile_was_flagged(self) -> None:
        calls = run(
            self.tmp_path,
            "found",
            extra={"ADVISORY_LOCKFILES": "crates/slimm-listener/Cargo.lock"},
        )
        self.assertIn("dependency in: crates/slimm-listener/Cargo.lock", "\n".join(calls))


    def test_the_issue_falls_back_to_the_root_lockfile_when_none_is_named(self) -> None:
        calls = run(self.tmp_path, "found")
        self.assertIn("dependency in: Cargo.lock", "\n".join(calls))


    def test_a_found_advisory_does_not_open_a_second_issue(self) -> None:
        """The check runs daily; without this it would file one issue per day."""
        calls = run(self.tmp_path, "found", existing="42")
        self.assertFalse(any(c.startswith("issue create") for c in calls), calls)


    def test_another_watchdog_can_supply_its_own_label_and_body(self) -> None:
        calls = run(
            self.tmp_path,
            "found",
            extra={
                "WATCHDOG_LABEL": "release-incomplete",
                "WATCHDOG_TITLE": "a release is missing assets",
                "WATCHDOG_BODY": "INCOMPLETE client-v9.9.9",
            },
        )
        created = next(c for c in calls if c.startswith("issue create"))
        self.assertIn("--label release-incomplete", created)
        self.assertIn("INCOMPLETE client-v9.9.9", created)
        self.assertNotIn("cargo deny", created)


    def test_a_clean_scan_closes_an_open_issue(self) -> None:
        calls = run(self.tmp_path, "clean", existing="42")
        self.assertTrue(any(c.startswith("issue close 42") for c in calls), calls)


    def test_a_clean_scan_with_nothing_open_does_nothing(self) -> None:
        calls = run(self.tmp_path, "clean")
        self.assertFalse(any(c.startswith("issue close") for c in calls), calls)
        self.assertFalse(any(c.startswith("issue create") for c in calls), calls)


    def test_an_unrecognised_status_refuses_rather_than_guessing(self) -> None:
        """A typo in the workflow's own expression must not read as 'clean'.

        `ADVISORY_STATUS` is built from a GitHub Actions ternary, so a future edit
        to that expression could produce something neither branch expects; the
        dangerous reading is the silent one, where an advisory scan quietly closes
        the very issue it should have opened.
        """
        env = dict(os.environ)
        env.update(
            GITHUB_REPOSITORY="owner/repo",
            ADVISORY_STATUS="",
            GH_CALLS=str(self.tmp_path / "unused.txt"),
        )
        done = subprocess.run(
            ["bash", str(SCRIPT)], env=env, capture_output=True, text=True
        )
        self.assertNotEqual(done.returncode, 0, done.stdout)


    def test_the_script_is_the_one_the_workflow_runs(self) -> None:
        """A test against a script no workflow calls proves nothing."""
        workflow = (
            SCRIPT.parents[1] / ".github/workflows/advisory-watchdog.yml"
        ).read_text()
        self.assertIn("scripts/report-advisory-issue.sh", workflow)
        self.assertGreaterEqual(textwrap.dedent(workflow).count("check advisories"), 1)


if __name__ == "__main__":
    unittest.main()
