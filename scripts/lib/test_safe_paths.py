# SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
"""Command-line paths stay inside the directories a tool may touch."""
import os
import sys
import tempfile
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))

import safe_paths  # noqa: E402


class ConfinedTest(unittest.TestCase):
    def setUp(self):
        self.base = tempfile.mkdtemp(dir=os.path.expanduser("~/.cache"))
        self.addCleanup(os.rmdir, self.base)

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
        self.addCleanup(os.remove, link)
        with self.assertRaises(SystemExit):
            safe_paths.confined(os.path.join(link, "passwd"), self.base)


if __name__ == "__main__":
    unittest.main()
