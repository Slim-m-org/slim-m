# SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
import math
import random
import unittest

import make_speech_clip as clip
import voice_latency as lat

RATE = lat.RATE


def _bed(seconds, chirp_times, delay_s=0.0, noise=0.01, seed=3):
    """A noisy bed carrying the marker chirp at each time, shifted by `delay_s`."""
    rng = random.Random(seed)
    out = [rng.uniform(-noise, noise) for _ in range(int(seconds * RATE))]
    marker = clip.chirp(RATE)
    for t in chirp_times:
        at = int((t + delay_s) * RATE)
        for i, v in enumerate(marker):
            if at + i < len(out):
                out[at + i] += v
    return out


class FindChirps(unittest.TestCase):
    def test_finds_each_marker_to_a_millisecond(self):
        sent = [1.0, 3.1, 5.2, 7.3]
        got = lat.find_chirps(_bed(9.0, sent))
        self.assertEqual(len(got), 4)
        for want, have in zip(sent, got):
            self.assertAlmostEqual(have, want, delta=0.002)

    def test_a_steady_tone_is_not_a_chirp(self):
        tone = [0.5 * math.sin(2 * math.pi * 2000 * i / RATE) for i in range(RATE * 4)]
        self.assertEqual(lat.find_chirps(tone), [])

    def test_a_quiet_chirp_in_noise_still_counts(self):
        bed = _bed(5.0, [2.0], noise=0.05)
        self.assertEqual(len(lat.find_chirps([v * 0.2 for v in bed])), 1)


class Delays(unittest.TestCase):
    def test_delay_between_send_and_arrival(self):
        sent = [1000.0, 3100.0, 5200.0]
        heard = [1180.0, 3290.0, 5385.0]
        self.assertEqual(lat.delays_ms(sent, heard), [180.0, 190.0, 185.0])

    def test_a_lost_chirp_is_not_paired_with_the_one_before(self):
        sent = [1000.0, 3100.0, 5200.0]
        heard = [1180.0, 5400.0]
        self.assertEqual(lat.delays_ms(sent, heard), [180.0, 200.0])

    def test_recovers_a_known_delay_end_to_end(self):
        sent = [1.0, 3.1, 5.2]
        rx = lat.find_chirps(_bed(8.0, sent, delay_s=0.213))
        tx = lat.find_chirps(_bed(8.0, sent))
        got = lat.delays_ms([t * 1000 for t in tx], [t * 1000 for t in rx])
        self.assertEqual(len(got), 3)
        for value in got:
            self.assertAlmostEqual(value, 213.0, delta=3.0)


class Summary(unittest.TestCase):
    def test_median_and_tail(self):
        got = lat.summary([100.0, 120.0, 140.0, 400.0])
        self.assertEqual((got["n"], got["median"], got["max"]), (4, 130.0, 400.0))

    def test_empty(self):
        self.assertEqual(lat.summary([]), {"n": 0})

    def test_heard_fraction_counts_answered_sends(self):
        sent = [1000.0, 3000.0, 5000.0, 7000.0]
        heard = [1150.0, 7160.0]
        self.assertEqual(lat.heard_fraction(sent, heard, (0.0, 9000.0)), 0.5)


if __name__ == "__main__":
    unittest.main()
