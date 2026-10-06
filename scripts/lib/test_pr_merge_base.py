# SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
"""The PR breaking-change gate diffs against where the PR branched, not main's tip.

Against the tip, a path main gained after the branch point reads as removed by
the PR and the gate goes red for a change the author never made.
"""
import re
import subprocess
import tempfile
import unittest
from pathlib import Path

from test_windows_builds_do_not_run_under_bash import jobs

ROOT = Path(__file__).resolve().parents[2]
SCRIPT = ROOT / "scripts" / "pr-merge-base.sh"
SCHEMA = (ROOT / ".github" / "workflows" / "schema-ci.yml").read_text()

FAKE_GH = """#!/bin/sh
echo "$@" >> "$FAKE_GH_LOG"
[ "$FAKE_GH_FAIL" = 1 ] && exit 1
printf '%s' "$FAKE_GH_SHA"
"""


def run_script(tmp: Path, sha: str, fail: bool = False):
    fake = tmp / "bin" / "gh"
    fake.parent.mkdir(exist_ok=True)
    fake.write_text(FAKE_GH)
    fake.chmod(0o755)
    git = tmp / "bin" / "git"
    git.write_text('#!/bin/sh\necho "git $@" >> "$FAKE_GH_LOG"\n')
    git.chmod(0o755)
    env = {
        "PATH": f"{fake.parent}:/usr/bin:/bin",
        "GH_TOKEN": "x",
        "GITHUB_REPOSITORY": "o/r",
        "FAKE_GH_LOG": str(tmp / "log"),
        "FAKE_GH_SHA": sha,
        "FAKE_GH_FAIL": "1" if fail else "0",
    }
    result = subprocess.run([str(SCRIPT), "basesha", "headsha"], env=env, capture_output=True, text=True)
    log = (tmp / "log").read_text() if (tmp / "log").exists() else ""
    return result, log


class PrMergeBaseTest(unittest.TestCase):
    def test_it_prints_and_fetches_the_merge_base(self):
        with tempfile.TemporaryDirectory() as tmp:
            result, log = run_script(Path(tmp), "abc123")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(result.stdout.strip(), "abc123")
        self.assertIn("compare/basesha...headsha", log)
        self.assertIn("git fetch --quiet --depth=1 origin abc123", log)

    def test_an_unanswered_lookup_fails_closed(self):
        with tempfile.TemporaryDirectory() as tmp:
            result, _ = run_script(Path(tmp), "")
        self.assertEqual(result.returncode, 1)
        self.assertIn("merge base", result.stderr)

    def test_a_failed_api_call_fails_closed(self):
        with tempfile.TemporaryDirectory() as tmp:
            result, _ = run_script(Path(tmp), "abc", fail=True)
        self.assertEqual(result.returncode, 1)


class SchemaCiDiffsAgainstTheMergeBaseTest(unittest.TestCase):
    def setUp(self):
        self.gate = jobs(SCHEMA)["breaking-change-gate"]

    def test_the_base_is_the_merge_base_not_the_base_tip(self):
        base = re.search(r"^\s+base:\s*(.+)$", self.gate, re.M).group(1)
        self.assertNotIn("pull_request.base.sha", base)
        self.assertIn("steps.merge-base.outputs.sha", base)

    def test_the_gate_asks_the_script_for_it(self):
        self.assertIn("scripts/pr-merge-base.sh", self.gate)
        self.assertRegex(self.gate, r"id: merge-base")

    def test_the_base_tip_is_no_longer_fetched_for_the_diff(self):
        self.assertNotIn("git fetch --depth=1 origin ${{ github.event.pull_request.base.sha }}", self.gate)


if __name__ == "__main__":
    unittest.main()
