# SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
"""Unit coverage for scripts/check-stuck-release-label.sh.

The script reads its PR list from PENDING_JSON and its clock from NOW_EPOCH,
so no GitHub call or real time is involved.
"""
import json
import os
import subprocess
import tempfile
import unittest
from pathlib import Path

SCRIPT = Path(__file__).resolve().parent.parent / "check-stuck-release-label.sh"
NOW = 1_800_000_000


class CheckStuckReleaseLabelTest(unittest.TestCase):
    def _run(self, prs, grace=None):
        tmp = tempfile.NamedTemporaryFile("w", suffix=".json", delete=False)
        self.addCleanup(Path(tmp.name).unlink)
        json.dump(prs, tmp)
        tmp.close()
        env = {**os.environ, "PENDING_JSON": tmp.name, "NOW_EPOCH": str(NOW)}
        if grace is not None:
            env["GRACE_SECONDS"] = str(grace)
        return subprocess.run(
            ["bash", str(SCRIPT)], capture_output=True, text=True, env=env)

    @staticmethod
    def _pr(number, age_seconds):
        merged = subprocess.run(
            ["date", "-u", "-d", f"@{NOW - age_seconds}", "+%Y-%m-%dT%H:%M:%SZ"],
            capture_output=True, text=True, check=True).stdout.strip()
        return {"number": number, "title": f"chore: release {number}", "mergedAt": merged}

    def test_no_pending_pr_passes(self):
        result = self._run([])
        self.assertEqual(result.returncode, 0)
        self.assertIn("no merged release PR is stuck", result.stdout)

    def test_a_pr_inside_the_grace_window_is_in_flight(self):
        result = self._run([self._pr(7, 60)])
        self.assertEqual(result.returncode, 0)
        self.assertIn("still inside the grace window", result.stdout)

    def test_a_pr_past_the_grace_window_is_stuck(self):
        result = self._run([self._pr(7, 7200)])
        self.assertEqual(result.returncode, 1)
        self.assertIn("#7", result.stdout)
        self.assertIn("autorelease: pending", result.stdout)

    def test_the_grace_window_is_configurable(self):
        self.assertEqual(self._run([self._pr(7, 600)], grace=300).returncode, 1)
        self.assertEqual(self._run([self._pr(7, 600)], grace=900).returncode, 0)

    def test_one_stuck_pr_among_fresh_ones_fails(self):
        result = self._run([self._pr(1, 30), self._pr(2, 9000)])
        self.assertEqual(result.returncode, 1)


if __name__ == "__main__":
    unittest.main()
