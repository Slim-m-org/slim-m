# SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
"""Folded stacks from the same hand-built profile test_load_profile uses."""
import sys
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))

import load_folded  # noqa: E402
import load_profile  # noqa: E402
from test_load_profile import PROFILE, SIDECAR  # noqa: E402


class FoldTest(unittest.TestCase):
    def test_stacks_are_rooted_at_the_thread_and_counted(self):
        folded = load_folded.fold(PROFILE, load_profile.Symbols(SIDECAR))
        self.assertEqual(folded["worker;core::fmt::write"], 1)
        self.assertEqual(folded["worker;core::fmt::write;plain_c"], 2)
        self.assertEqual(folded["sqlx;core::fmt::write;plain_c"], 1)

    def test_samples_before_the_cutoff_are_left_out(self):
        folded = load_folded.fold(PROFILE, load_profile.Symbols(SIDECAR), since_epoch_ms=1015.0)
        self.assertEqual(sum(folded.values()), 1)


if __name__ == "__main__":
    unittest.main()
