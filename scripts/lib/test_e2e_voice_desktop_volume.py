# SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
import array
import math
import unittest

import e2e_voice_desktop_volume as vol


def pcm(level_db, windows=20):
    """s16le mono bytes at a steady RMS of `level_db`, as a square wave."""
    peak = round(32768 * 10 ** (level_db / 20))
    return array.array("h", [peak, -peak] * (vol.WINDOW * windows // 2)).tobytes()


class Levels(unittest.TestCase):
    def test_a_steady_signal_reads_its_own_level(self):
        levels = vol.window_levels_db(pcm(-30))
        self.assertAlmostEqual(vol.heard_db(levels), -30, delta=0.1)

    def test_digital_silence_is_the_floor(self):
        self.assertEqual(vol.heard_db(vol.window_levels_db(bytes(2 * vol.WINDOW * 4))), -120.0)

    def test_expected_gain_follows_the_taper(self):
        self.assertAlmostEqual(vol.expected_db(0.5), -18.06, places=1)
        self.assertAlmostEqual(vol.expected_db(2.0), 6.02, places=1)
        self.assertEqual(vol.expected_db(0.0), -math.inf)


class Verdict(unittest.TestCase):
    ON_TARGET = {0.0: -120.0, 0.5: -40.5, 1.0: -22.5, 2.0: -16.5}

    def test_levels_on_the_slider_pass(self):
        self.assertEqual(vol.problems(self.ON_TARGET), [])

    def test_a_slider_that_barely_moves_the_sound_fails(self):
        flat = {**self.ON_TARGET, 0.5: -24.0}
        self.assertIn("0.5", " ".join(vol.problems(flat)))

    def test_zero_that_still_plays_fails(self):
        loud = {**self.ON_TARGET, 0.0: -40.0}
        self.assertIn("silent", " ".join(vol.problems(loud)))

    def test_nothing_playing_is_not_a_pass(self):
        silent = {key: -120.0 for key in self.ON_TARGET}
        self.assertIn("nothing was playing", " ".join(vol.problems(silent)))

    def test_an_event_that_resets_the_gain_fails(self):
        reset = {**self.ON_TARGET, "0.5 after a rejoin": -22.5}
        self.assertIn("after a rejoin", " ".join(vol.problems(reset)))


if __name__ == "__main__":
    unittest.main()
