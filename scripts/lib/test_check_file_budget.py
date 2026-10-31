# SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
"""Unit coverage for scripts/check-file-budget.sh.

The script resolves its root with `git rev-parse --show-toplevel`, so each test
builds a throwaway git repo holding a copy of the script.
"""
import shutil
import subprocess
import tempfile
import unittest
from pathlib import Path

SCRIPT = Path(__file__).resolve().parent.parent / "check-file-budget.sh"


class CheckFileBudgetTest(unittest.TestCase):
    def setUp(self):
        tmp = tempfile.TemporaryDirectory()
        self.addCleanup(tmp.cleanup)
        self.repo = Path(tmp.name)
        self._git("init", "-q")
        (self.repo / "scripts").mkdir()
        shutil.copy(SCRIPT, self.repo / "scripts")
        self.allow = ""

    def _git(self, *args):
        subprocess.run(["git", *args], cwd=self.repo, check=True, capture_output=True)

    def _file(self, rel, lines):
        path = self.repo / rel
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text("x\n" * lines)

    def _run(self, *files):
        (self.repo / "scripts" / "file-budget-allow.txt").write_text(self.allow)
        self._git("add", "-A")
        return subprocess.run(
            ["bash", "scripts/check-file-budget.sh", *files],
            cwd=self.repo, capture_output=True, text=True)

    def test_a_small_file_is_clean(self):
        self._file("a.rs", 100)
        result = self._run()
        self.assertEqual(result.returncode, 0)
        self.assertNotIn("::warning", result.stdout)

    def test_past_300_only_warns(self):
        self._file("a.rs", 301)
        result = self._run()
        self.assertEqual(result.returncode, 0)
        self.assertIn("over the 300-line review budget", result.stdout)

    def test_past_500_warns_within_the_slack(self):
        self._file("a.rs", 501)
        self._file("b.rs", 560)
        result = self._run()
        self.assertEqual(result.returncode, 0)
        self.assertEqual(result.stdout.count("over the 500-line limit"), 2)

    def test_more_than_60_past_500_fails(self):
        self._file("a.rs", 561)
        result = self._run()
        self.assertEqual(result.returncode, 1)
        self.assertIn("more than 60 over", result.stderr)

    def test_an_allowlisted_file_gets_the_slack_over_its_own_ceiling(self):
        self.allow = "big.rs 700 # why\n"
        self._file("big.rs", 760)
        self.assertEqual(self._run().returncode, 0)
        self._file("big.rs", 761)
        self.assertEqual(self._run().returncode, 1)

    def test_an_entry_for_a_file_back_under_500_is_stale(self):
        self.allow = "big.rs 700 # why\n"
        self._file("big.rs", 400)
        result = self._run()
        self.assertEqual(result.returncode, 1)
        self.assertIn("no longer needs an entry", result.stderr)

    def test_an_entry_for_a_missing_file_is_stale(self):
        self.allow = "gone.rs 700 # why\n"
        self._file("a.rs", 10)
        result = self._run()
        self.assertEqual(result.returncode, 1)
        self.assertIn("is not a checked source file any more", result.stderr)

    def test_an_entry_without_a_ceiling_is_refused(self):
        self.allow = "big.rs # no number\n"
        self._file("a.rs", 10)
        self.assertEqual(self._run().returncode, 1)

    def test_exempt_files_are_skipped(self):
        self._file("schema/openapi.yaml", 5000)
        self._file("client/packages/data/lib/database.g.dart", 5000)
        self._file(".sqlx/q.rs", 5000)
        self.assertEqual(self._run().returncode, 0)

    def test_file_arguments_narrow_the_scan_and_skip_the_stale_entry_check(self):
        self.allow = "gone.rs 700 # why\n"
        self._file("a.rs", 561)
        self._file("b.rs", 10)
        self.assertEqual(self._run("b.rs").returncode, 0)
        self.assertEqual(self._run("a.rs").returncode, 1)


if __name__ == "__main__":
    unittest.main()
