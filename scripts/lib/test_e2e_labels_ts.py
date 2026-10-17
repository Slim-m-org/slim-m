# SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
"""e2e/src/labels.ts must be exactly what e2e_labels_json.py generates.

The Playwright suite drives the app by the same accessible names as the Python
harness. A hand-edited or stale copy would let the two disagree about a label.
"""
import sys
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))

import e2e_labels_json  # noqa: E402

COMMITTED = Path(__file__).resolve().parents[2] / "e2e" / "src" / "labels.ts"


class LabelsTypescriptTest(unittest.TestCase):
    def test_committed_file_matches_the_generator(self):
        self.assertEqual(
            COMMITTED.read_text(encoding="utf-8"),
            e2e_labels_json.as_typescript(),
            "run `npm run labels` in e2e/ and commit the result")

    def test_tuples_become_arrays_and_strings_stay_strings(self):
        labels = e2e_labels_json.labels()
        self.assertEqual(labels["COMPOSER"], "Message composer")
        self.assertIsInstance(labels["QUICK_REACTIONS"], tuple)


if __name__ == "__main__":
    unittest.main()
