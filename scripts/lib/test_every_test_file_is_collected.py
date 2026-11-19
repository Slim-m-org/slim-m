# SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
"""Every `test_*.py` here must hold a `unittest.TestCase`, or hygiene runs none of it.

`test_report_advisory_issue.py` was seven bare functions for months: discovery
collected nothing from it and reported no error.
"""
import re
import unittest
from pathlib import Path

HERE = Path(__file__).resolve().parent
TEST_CASE = re.compile(r"^class \w+\((?:unittest\.)?\w*TestCase\):", re.M)
BARE_TEST = re.compile(r"^def test_\w+\(", re.M)


def uncollected(source: str) -> bool:
    """True when a file's tests are functions no `TestCase` owns."""
    return bool(BARE_TEST.search(source)) or not TEST_CASE.search(source)


class EveryTestFileIsCollectedTest(unittest.TestCase):
    def test_every_test_file_is_collected(self):
        missed = sorted(
            path.name
            for path in HERE.glob("test_*.py")
            if uncollected(path.read_text())
        )
        self.assertEqual(missed, [])

    def test_bare_functions_are_seen_as_uncollected(self):
        self.assertTrue(uncollected("def test_it(tmp_path):\n    assert True\n"))

    def test_a_test_case_is_seen_as_collected(self):
        source = "class ATest(unittest.TestCase):\n    def test_it(self):\n        pass\n"
        self.assertFalse(uncollected(source))

    def test_a_case_built_on_a_shared_base_case_is_seen_as_collected(self):
        source = "class ATest(RestoreTestCase):\n    def test_it(self):\n        pass\n"
        self.assertFalse(uncollected(source))


if __name__ == "__main__":
    unittest.main()
