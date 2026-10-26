# SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
"""Validates that check_budget.py enforces canvas GPU raster time limits."""

import json
import os
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
CHECK_BUDGET = ROOT / "client" / "packages" / "voice_canvas" / "benchmark" / "profile" / "check_budget.py"


def _sample_results(rows):
    return json.dumps({
        "rows": [
            {
                "name": name,
                "raster": {
                    "median_us": median_us,
                    "p99_us": p99_us,
                },
            }
            for name, median_us, p99_us in rows
        ]
    })


class CanvasPerfBudgetTest(unittest.TestCase):
    def test_raster_budget_held_returns_zero(self):
        with tempfile.TemporaryDirectory() as tmp:
            results_path = Path(tmp) / "profile_held.json"
            results_path.write_text(_sample_results([("pan_gesture", 4000, 12000)]))
            proc = subprocess.run(
                [sys.executable, str(CHECK_BUDGET), str(results_path)],
                capture_output=True,
                text=True,
                check=False,
            )
            self.assertEqual(proc.returncode, 0)
            self.assertIn("raster budget held", proc.stdout)

    def test_raster_budget_exceeded_median_returns_one(self):
        with tempfile.TemporaryDirectory() as tmp:
            results_path = Path(tmp) / "profile_median_fail.json"
            results_path.write_text(_sample_results([("busy_board_pan", 9500, 14000)]))
            proc = subprocess.run(
                [sys.executable, str(CHECK_BUDGET), str(results_path)],
                capture_output=True,
                text=True,
                check=False,
            )
            self.assertEqual(proc.returncode, 1)
            self.assertIn("raster budget (8.0 ms median, 16.7 ms p99) exceeded:", proc.stdout)
            self.assertIn("busy_board_pan: raster median 9.50 ms, p99 14.00 ms", proc.stdout)

    def test_raster_budget_exceeded_p99_returns_one(self):
        with tempfile.TemporaryDirectory() as tmp:
            results_path = Path(tmp) / "profile_p99_fail.json"
            results_path.write_text(_sample_results([("complex_zoom", 6000, 19500)]))
            proc = subprocess.run(
                [sys.executable, str(CHECK_BUDGET), str(results_path)],
                capture_output=True,
                text=True,
                check=False,
            )
            self.assertEqual(proc.returncode, 1)
            self.assertIn("complex_zoom: raster median 6.00 ms, p99 19.50 ms", proc.stdout)

    def test_invalid_path_returns_two(self):
        with tempfile.TemporaryDirectory() as tmp:
            invalid_path = Path(tmp) / "not_json.txt"
            invalid_path.write_text("hello")
            proc = subprocess.run(
                [sys.executable, str(CHECK_BUDGET), str(invalid_path)],
                capture_output=True,
                text=True,
                check=False,
            )
            self.assertEqual(proc.returncode, 2)
            self.assertIn("not a results file", proc.stdout)

    def test_custom_env_thresholds_override_defaults(self):
        with tempfile.TemporaryDirectory() as tmp:
            results_path = Path(tmp) / "profile_custom_env.json"
            results_path.write_text(_sample_results([("tight_spec", 5000, 10000)]))
            env = dict(os.environ, PROFILE_RASTER_MEDIAN_MS="4.0")
            proc = subprocess.run(
                [sys.executable, str(CHECK_BUDGET), str(results_path)],
                env=env,
                capture_output=True,
                text=True,
                check=False,
            )
            self.assertEqual(proc.returncode, 1)
            self.assertIn("raster budget (4.0 ms median, 16.7 ms p99) exceeded:", proc.stdout)


if __name__ == "__main__":
    unittest.main()
