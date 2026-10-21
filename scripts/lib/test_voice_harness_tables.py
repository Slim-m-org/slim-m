# SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
import json
import os
import tempfile
import unittest

import voice_harness_tables as tables


def _write(root, kind, data):
    os.makedirs(os.path.join(root, kind))
    with open(os.path.join(root, kind, f"{kind}.json"), "w") as fh:
        json.dump(data, fh)


class Tables(unittest.TestCase):
    def setUp(self):
        self.root = tempfile.mkdtemp(prefix="vq-tables-")

    def test_latency_row_subtracts_the_jitter_buffer(self):
        side = {"mouth_to_ear_ms": {"n": 9, "median": 180.0, "p95": 230.0, "max": 260.0},
                "answered": 1.0}
        _write(self.root, "latency", {"clean": {
            "vqa_to_vqb": side, "vqb_to_vqa": side,
            "stats": {"vqa": {"jitterBufferDelayMs": 40}, "vqb": {"jitterBufferDelayMs": 60}}}})
        out = tables.latency(self.root)
        self.assertIn("| clean | 180 | 230 | 260 | 50 | 130 | 100% |", out)

    def test_join_rows_mark_the_cold_one(self):
        _write(self.root, "experience", {"joins": [
            {"cold": True, "in_call_ms": 900, "first_packet_ms": 700, "first_energy_ms": None}]})
        self.assertIn("| 1 | cold | 900 | 700 | - |", tables.joins(self.root))

    def test_desktop_rows_skip_the_gate_log(self):
        noise = {"hum_floor": {"change_db": -20.0}, "typing_gap": {"change_db": -15.0},
                 "bark_gap": {"change_db": -12.0},
                 "typing_speech": {"excess_over_speech_db": 1.0},
                 "bark_speech": {"excess_over_speech_db": 2.0},
                 "speech_level_change_db": -1.5,
                 "onsets": {"clipped": 2, "mean_lost_ms": 35.0}}
        _write(self.root, "desktop", {"strong-gate-on": {
            "clean": {"noise": noise}, "gate_log": {"open": 0.5}}})
        out = tables.desktop(self.root)
        self.assertIn("| strong-gate-on | clean | -20.0 | -15.0 | -12.0 | 1.0 | 2.0 | -1.5 | 2 | 35 |", out)


if __name__ == "__main__":
    unittest.main()
