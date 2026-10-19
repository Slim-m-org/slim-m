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
        self.assertIn("| 'in call' shown | 300 | 120 (p95 200, n 3) | 250 | 92 (p95 95, n 2) |", out)

    def test_a_missing_side_reads_n_a_not_a_gap(self):
        root = _tree([_join(100)], [])
        self.assertIn("n/a", ab.joins(root))
        self.assertIn("n/a", ab.cut(root))


if __name__ == "__main__":
    unittest.main()
