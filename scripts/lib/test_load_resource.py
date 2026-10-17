# SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
"""Sampling this very process, and summarising rows with known answers."""
import os
import sys
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))

import load_resource  # noqa: E402


class ReadSampleTest(unittest.TestCase):
    def test_reads_this_process(self):
        row = load_resource.read_sample(os.getpid())
        self.assertGreater(row["rss_kb"], 1000)
        self.assertGreaterEqual(row["threads"], 1)
        self.assertGreater(row["fds"], 0)

    def test_a_missing_process_is_none(self):
        self.assertIsNone(load_resource.read_sample(2 ** 22 + 12345))


class SummarizeTest(unittest.TestCase):
    def test_average_and_peak(self):
        rows = [
            {"t": 0.0, "cpu_seconds": 0.0, "rss_kb": 10240, "threads": 4, "fds": 10},
            {"t": 1.0, "cpu_seconds": 1.0, "rss_kb": 20480, "threads": 6, "fds": 30},
            {"t": 2.0, "cpu_seconds": 4.0, "rss_kb": 15360, "threads": 5, "fds": 20},
        ]
        text = load_resource.summarize(rows)
        self.assertIn("cpu avg           2.00 cores", text)
        self.assertIn("cpu peak (1s)     3.00 cores", text)
        self.assertIn("rss start/peak    10 / 20 MiB", text)

    def test_too_few_rows(self):
        self.assertEqual(load_resource.summarize([]), "too few samples")


if __name__ == "__main__":
    unittest.main()
