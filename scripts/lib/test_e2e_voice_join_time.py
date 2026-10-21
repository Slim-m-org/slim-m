# SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
"""The join-time scenario's own arithmetic."""
import sys
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))

import e2e_voice_join_time as jt  # noqa: E402


class PercentileTest(unittest.TestCase):
    def test_nearest_rank(self):
        values = list(range(1, 11))
        self.assertEqual(jt.percentile(values, 50), 5)
        self.assertEqual(jt.percentile(values, 95), 10)

    def test_empty_is_none(self):
        self.assertIsNone(jt.percentile([], 50))


class RelativeTest(unittest.TestCase):
    def test_measures_from_the_click(self):
        marks = {"click": 1000.0, "tokenEnd": 1100.0, "firstSamples": 2500.0,
                 "unknown": 5.0}
        self.assertEqual(jt.relative(marks),
                         {"tokenEnd": 100.0, "firstSamples": 1500.0})

    def test_without_a_click_nothing_is_reported(self):
        self.assertEqual(jt.relative({"tokenEnd": 5.0}), {})

    def test_a_mark_before_the_click_reads_negative(self):
        marks = {"click": 1000.0, "tokenEnd": 700.0}
        self.assertEqual(jt.relative(marks), {"tokenEnd": -300.0})


class SummaryTest(unittest.TestCase):
    def test_skips_stages_no_run_reached(self):
        summary = jt.summarize([{"ice": 400.0}, {"ice": 600.0}])
        self.assertEqual(summary, {"ice": (400.0, 600.0, 2)})
        self.assertIn("ice", jt.format_table(summary))


if __name__ == "__main__":
    unittest.main()
