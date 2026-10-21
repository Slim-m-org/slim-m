# SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
import json
import os
import tempfile
import unittest

import voice_ab_report as ab


def _tree(joins_before, joins_after):
    root = tempfile.mkdtemp(prefix="vq-ab-")
    for side, joins in (("before", joins_before), ("after", joins_after)):
        os.makedirs(os.path.join(root, side, "experience"))
        with open(os.path.join(root, side, "experience", "experience.json"), "w") as fh:
            json.dump({"joins": joins, "speaking": {}, "cut": None}, fh)
    return root


def _join(ms, cold=False):
    return {"cold": cold, "in_call_ms": ms, "first_packet_ms": ms + 100, "first_energy_ms": ms + 200}


class Report(unittest.TestCase):
    def test_joins_split_cold_from_warm_and_show_the_spread(self):
        root = _tree([_join(300, True), _join(100), _join(120), _join(200)],
                     [_join(250, True), _join(90), _join(95)])
        out = ab.joins(root)
        self.assertIn("| 'in call' shown | 300 | 120 (min 100, max 200, n 3) | 250 | 92 (min 90, max 95, n 2) |", out)

    def test_a_missing_side_reads_n_a_not_a_gap(self):
        root = _tree([_join(100)], [])
        self.assertIn("n/a", ab.joins(root))
        self.assertIn("n/a", ab.cut(root))


def _write(root, side, parts, data):
    folder = os.path.join(root, side, *parts[:-1])
    os.makedirs(folder, exist_ok=True)
    with open(os.path.join(folder, parts[-1]), "w") as fh:
        json.dump(data, fh)


class Spread(unittest.TestCase):
    def test_few_values_show_min_and_max_not_a_p95(self):
        self.assertEqual(ab._spread([1, 2, 3]), "2 (min 1, max 3, n 3)")

    def test_many_values_show_the_tail_and_scores_the_low_one(self):
        values = list(range(1, 41))
        self.assertIn("p95 39", ab._spread(values))
        self.assertIn("p5 3", ab._spread(values, scores=True))


class OneSidedAndFailedRows(unittest.TestCase):
    def setUp(self):
        self.root = tempfile.mkdtemp(prefix="vq-ab-")

    def test_a_side_with_no_recordings_is_not_zero_anomalies(self):
        run = {"clean": {"vqa": {"counts": {"dropout": 2}, "mos": {"visqol": 4.4, "ovrl": 3.4}}}}
        _write(self.root, "before", ["baseline", "results.json"], run)
        out = ab.quality(self.root)
        self.assertIn("n 1: dropout 2", out)
        self.assertEqual(out.splitlines()[-1].split("|")[-3].strip(), "n/a")

    def test_a_ring_that_never_lit_says_so(self):
        row = {"onsets": 6, "lit": 0, "missed": 6, "delay_ms": {"n": 0}}
        _write(self.root, "before", ["experience", "experience.json"],
               {"joins": [], "speaking": {"clean": row}, "cut": None})
        _write(self.root, "after", ["experience", "experience.json"],
               {"joins": [], "speaking": {}, "cut": None})
        out = ab.speaking(self.root)
        self.assertIn("ring never lit (onsets 6, missed 6)", out)

    def test_failed_joins_are_counted_not_dropped(self):
        bad = {"cold": False, "in_call_ms": None, "first_packet_ms": None, "first_energy_ms": None}
        _write(self.root, "before", ["experience", "experience.json"],
               {"joins": [bad, bad], "speaking": {}, "cut": None})
        self.assertIn("failed 2", ab.joins(self.root))

    def test_a_missing_jitter_buffer_reading_is_not_averaged_as_zero(self):
        side = {"mouth_to_ear_ms": {"n": 9, "median": 100.0, "p95": 120.0, "max": 130.0, "n_": 9}}
        stats = {"vqa": {"jitterBufferDelayMs": 40}, "vqb": {}}
        _write(self.root, "before", ["latency", "latency.json"],
               {"clean": {"vqa_to_vqb": side, "vqb_to_vqa": side, "stats": stats}})
        self.assertIn("| 40 |", ab.latency(self.root))


if __name__ == "__main__":
    unittest.main()
