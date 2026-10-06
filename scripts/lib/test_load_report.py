# SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
"""The load report's arithmetic: percentiles, scrape parsing and deltas."""
import json
import sys
import tempfile
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))

import load_report as R  # noqa: E402


class PercentileTest(unittest.TestCase):
    def test_nearest_rank_over_a_sorted_copy(self):
        values = [50, 10, 40, 20, 30]
        self.assertEqual(R.percentile(values, 0.0), 10)
        self.assertEqual(R.percentile(values, 0.5), 30)
        self.assertEqual(R.percentile(values, 1.0), 50)
        self.assertEqual(values, [50, 10, 40, 20, 30])

    def test_p99_is_a_value_that_was_observed(self):
        values = list(range(1, 11))
        self.assertIn(R.percentile(values, 0.99), values)
        self.assertEqual(R.percentile(values, 0.99), 10)

    def test_nothing_has_no_percentile(self):
        self.assertIsNone(R.percentile([], 0.5))

    def test_summarise(self):
        got = R.summarise([1.0, 2.0, 3.0, 4.0, 5.0])
        self.assertEqual((got["count"], got["min"], got["p50"], got["max"]),
                         (5, 1.0, 3.0, 5.0))
        self.assertEqual(got["mean"], 3.0)
        self.assertEqual(R.summarise([]), {"count": 0, "unit": "ms"})


class ParsePrometheusTest(unittest.TestCase):
    TEXT = """# HELP slimm_requests_total requests
# TYPE slimm_requests_total counter
slimm_requests_total{class="write"} 12
slimm_requests_total{class="read"} 7.5

slimm_websocket_connections 3
slimm_bad_line notanumber
justaname
"""

    def test_keeps_labels_in_the_key_and_skips_comments_and_junk(self):
        self.assertEqual(R.parse_prometheus(self.TEXT), {
            'slimm_requests_total{class="write"}': 12.0,
            'slimm_requests_total{class="read"}': 7.5,
            "slimm_websocket_connections": 3.0,
        })

    def test_none_and_empty_parse_to_nothing(self):
        self.assertEqual(R.parse_prometheus(None), {})
        self.assertEqual(R.parse_prometheus(""), {})


class CounterDeltaTest(unittest.TestCase):
    def test_reports_only_what_changed(self):
        first = {"a": 1.0, "b": 5.0, "c": 2.0}
        last = {"a": 4.0, "b": 5.0, "c": 2.5, "d": 7.0}
        self.assertEqual(R.counter_delta(first, last),
                         {"a": 3.0, "c": 0.5, "d": 7.0})

    def test_a_missing_scrape_is_treated_as_empty(self):
        self.assertEqual(R.counter_delta(None, {"a": 2.0}), {"a": 2.0})
        self.assertEqual(R.counter_delta({"a": 2.0}, None), {})


class WriteTest(unittest.TestCase):
    def test_round_trips_through_json(self):
        report = R.build("s", {"users": 1}, [1.0], [2.0], {"x": 1}, {}, [])
        with tempfile.TemporaryDirectory() as tmp:
            path = Path(tmp) / "out.json"
            R.write(report, path)
            self.assertEqual(json.loads(path.read_text()), report)


if __name__ == "__main__":
    unittest.main()
