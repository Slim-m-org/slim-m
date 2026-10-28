# SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
"""Unit coverage for scripts/check-test-patterns.py, the find.byType and pumpAndSettle ratchet."""
import importlib.util
import shutil
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

SCRIPTS = Path(__file__).resolve().parent.parent
spec = importlib.util.spec_from_file_location("check_test_patterns", SCRIPTS / "check-test-patterns.py")
gate = importlib.util.module_from_spec(spec)
spec.loader.exec_module(gate)


class CountingTest(unittest.TestCase):
    def test_counts_each_pattern(self):
        source = "find.byType(A); find.byType(B); await tester.pumpAndSettle();"
        self.assertEqual(gate.counts_in(source), (2, 1))

    def test_comments_do_not_count(self):
        source = "// find.byType(A) and pumpAndSettle\n/* pumpAndSettle */\nfind.byType(B);"
        self.assertEqual(gate.counts_in(source), (1, 0))

    def test_similar_names_do_not_count(self):
        self.assertEqual(gate.counts_in("find.byKey(k); tester.pump(); pumpAndSettleLater();"), (0, 0))


class CeilingTest(unittest.TestCase):
    def test_a_new_file_has_a_ceiling_of_zero(self):
        self.assertEqual(len(gate.over_ceiling({"a.dart": (1, 0)}, {})), 1)

    def test_a_file_may_keep_what_it_has_but_not_gain(self):
        allowed = {"a.dart": (2, 3)}
        self.assertEqual(gate.over_ceiling({"a.dart": (2, 3)}, allowed), [])
        self.assertEqual(gate.over_ceiling({"a.dart": (1, 0)}, allowed), [])
        self.assertEqual(len(gate.over_ceiling({"a.dart": (3, 3)}, allowed)), 1)
        self.assertEqual(len(gate.over_ceiling({"a.dart": (2, 4)}, allowed)), 1)

    def test_one_file_gaining_is_not_offset_by_another_losing(self):
        allowed = {"a.dart": (2, 0), "b.dart": (5, 0)}
        problems = gate.over_ceiling({"a.dart": (3, 0), "b.dart": (1, 0)}, allowed)
        self.assertEqual(problems, ["a.dart: 3 find.byType, ceiling 2"])

    def test_update_only_lowers_and_drops_empty_files(self):
        allowed = {"a.dart": (4, 4), "b.dart": (1, 0), "c.dart": (2, 2)}
        counts = {"a.dart": (1, 9), "b.dart": (0, 0), "c.dart": (2, 2), "new.dart": (3, 3)}
        self.assertEqual(gate.lowered(counts, allowed), {"a.dart": (1, 4), "c.dart": (2, 2)})


class EndToEndTest(unittest.TestCase):
    def setUp(self):
        tmp = tempfile.TemporaryDirectory()
        self.addCleanup(tmp.cleanup)
        self.repo = Path(tmp.name)
        subprocess.run(["git", "init", "-q"], cwd=self.repo, check=True)
        (self.repo / "scripts" / "lib").mkdir(parents=True)
        for rel in ("check-test-patterns.py", "lib/dart_source.py"):
            shutil.copy(SCRIPTS / rel, self.repo / "scripts" / rel)
        (self.repo / "scripts" / "test-pattern-allow.txt").write_text("")
        self.tests = self.repo / "client" / "packages" / "app" / "test"
        self.tests.mkdir(parents=True)

    def _run(self, *args):
        subprocess.run(["git", "add", "-A"], cwd=self.repo, check=True)
        return subprocess.run(
            [sys.executable, "scripts/check-test-patterns.py", *args],
            cwd=self.repo, capture_output=True, text=True)

    def test_a_clean_tree_passes_and_an_added_finder_fails(self):
        (self.tests / "a_test.dart").write_text("void main() { find.text('x'); }\n")
        self.assertEqual(self._run().returncode, 0)
        (self.tests / "a_test.dart").write_text("void main() { find.byType(A); }\n")
        result = self._run()
        self.assertEqual(result.returncode, 1)
        self.assertIn("a_test.dart", result.stdout)

    def test_update_never_raises_a_ceiling(self):
        (self.tests / "a_test.dart").write_text("void main() { await t.pumpAndSettle(); }\n")
        self.assertEqual(self._run().returncode, 1)
        self.assertEqual(self._run("--update").returncode, 1)
        allow = (self.repo / "scripts" / "test-pattern-allow.txt").read_text()
        self.assertNotIn("a_test.dart", allow)


if __name__ == "__main__":
    unittest.main()
