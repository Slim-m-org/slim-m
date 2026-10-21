# SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
import math
import unittest

import voice_burst_abs as babs

RATE = 16_000


def tone(seconds, amplitude, hz=300):
    return [amplitude * math.sin(2 * math.pi * hz * i / RATE)
            for i in range(int(seconds * RATE))]


class MeasureTest(unittest.TestCase):
    def test_identical_recording_has_no_overshoot(self):
        ref = tone(1, 0.3)
        got = babs.measure(ref, RATE, list(ref), RATE)
        self.assertEqual(got["loud_windows"], 0)
        self.assertAlmostEqual(got["peak_over_ref_db"], 0, places=1)

    def test_a_late_word_is_not_a_burst(self):
        ref = tone(1, 0.3) + [0.0] * RATE
        rec = [0.0] * (RATE // 10) + ref[:-(RATE // 10)]
        self.assertEqual(babs.measure(ref, RATE, rec, RATE)["loud_windows"], 0)

    def test_a_note_louder_than_the_loudest_word_is_counted(self):
        ref = tone(1, 0.1)
        rec = tone(0.5, 0.1) + tone(0.5, 0.5)
        got = babs.measure(ref, RATE, rec, RATE)
        self.assertGreater(got["loud_windows"], 0)
        self.assertGreater(got["peak_over_ref_db"], 10)


if __name__ == "__main__":
    unittest.main()
