# SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
"""The canvas engine and the voice session must stay inside the file-size gate."""

import subprocess
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
CANVAS_FILES = (
    "client/packages/app/lib/src/features/canvas/screens/canvas_engine.dart",
    "client/packages/rtc/lib/src/voice_session.dart",
)


class CanvasFileBudgetTest(unittest.TestCase):
    def test_gate_reports_no_error_for_canvas_files(self):
        run = subprocess.run(
            ["bash", "scripts/check-file-budget.sh"],
            cwd=ROOT,
            capture_output=True,
            text=True,
            check=False,
        )
        errors = [
            line
            for line in (run.stdout + run.stderr).splitlines()
            if line.startswith("::error") and any(f in line for f in CANVAS_FILES)
        ]
        self.assertEqual(errors, [])


if __name__ == "__main__":
    unittest.main()
