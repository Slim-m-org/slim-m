# SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
"""Command-line paths stay inside the directories a tool may touch."""
import os
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))

import safe_paths  # noqa: E402


class ConfinedTest(unittest.TestCase):
    def setUp(self):
        scratch = tempfile.TemporaryDirectory()
        self.addCleanup(scratch.cleanup)
        self.base = scratch.name

    def test_a_path_inside_the_base_resolves(self):
        inside = os.path.join(self.base, "shots")
        self.assertEqual(safe_paths.confined(inside, self.base), os.path.realpath(inside))

    def test_dot_dot_out_of_the_base_is_refused(self):
        with self.assertRaises(SystemExit):
            safe_paths.confined(os.path.join(self.base, "..", "elsewhere"), self.base)

    def test_a_sibling_sharing_the_prefix_is_refused(self):
        with self.assertRaises(SystemExit):
            safe_paths.confined(self.base + "-secret", self.base)

    def test_the_base_itself_is_refused(self):
        with self.assertRaises(SystemExit):
            safe_paths.confined(self.base, self.base)

    def test_a_symlink_out_of_the_base_is_refused(self):
        link = os.path.join(self.base, "out")
        os.symlink("/etc", link)
        with self.assertRaises(SystemExit):
            safe_paths.confined(os.path.join(link, "passwd"), self.base)


class CommandLineTest(unittest.TestCase):
    def run_cli(self, *args):
        return subprocess.run(
            [sys.executable, "-I", str(Path(safe_paths.__file__)), *args],
            capture_output=True, text=True)

    def test_a_confined_path_is_printed_resolved(self):
        with tempfile.TemporaryDirectory() as base:
            inside = os.path.join(base, "run", "..", "run")
            got = self.run_cli("confined", inside, base)
            self.assertEqual(got.returncode, 0, got.stderr)
            self.assertEqual(got.stdout, os.path.realpath(os.path.join(base, "run")) + "\n")

    def test_a_path_outside_every_base_exits_nonzero_with_the_reason(self):
        with tempfile.TemporaryDirectory() as base:
            got = self.run_cli("confined", "/etc", base)
        self.assertNotEqual(got.returncode, 0)
        self.assertIn("must be inside", got.stderr)
        self.assertEqual(got.stdout, "")

    def test_a_malformed_call_prints_usage(self):
        got = self.run_cli("confined", "/only/a/path")
        self.assertNotEqual(got.returncode, 0)
        self.assertIn("usage:", got.stderr)


if __name__ == "__main__":
    unittest.main()
