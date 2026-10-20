# SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
import random
import unittest

import e2e_voice_quality as scenario
import voice_quality_align as align
import voice_quality_dsp as dsp

RATE = dsp.ANALYSIS_RATE


def _words(seed, seconds):
    rng = random.Random(seed)
    out = []
    while len(out) < seconds * RATE:
        out += [0.0] * int(rng.uniform(0.15, 0.4) * RATE)
        out += [rng.uniform(-0.3, 0.3) for _ in range(int(rng.uniform(0.2, 0.6) * RATE))]
    return out[:int(seconds * RATE)]


class Alignment(unittest.TestCase):
    def setUp(self):
        self.ref = _words(7, 12)

    def _loop(self, offset_s, seconds=12):
        start = int(offset_s * RATE)
        return (self.ref * 3)[start:start + int(seconds * RATE)]

    def test_the_coarse_lag_finds_where_the_loop_starts_to_10_ms(self):
        lag = align.coarse_lag(self.ref, self._loop(4.37))
        self.assertAlmostEqual(lag / RATE, 4.37, delta=0.011)

    def test_tracking_a_clean_loop_holds_one_delay(self):
        starts, lags = align.track(self.ref, self._loop(2.0))
        self.assertEqual(len(starts), len(lags))
        self.assertLessEqual(max(lags) - min(lags), 2)

    def test_a_silent_recording_carries_the_delay_forward(self):
        rec = self._loop(2.0, 8)
        rec[2 * RATE:6 * RATE] = [0.0] * (4 * RATE)
        _, lags, locked = align.track_locked(self.ref, rec)
        self.assertTrue(all(locked))
        self.assertLessEqual(max(lags) - min(lags), 2)

    def test_the_expected_signal_is_the_reference_under_the_tracked_delay(self):
        rec = self._loop(3.0)
        starts, lags = align.track(self.ref, rec)
        expected = align.expected_signal(self.ref, len(rec), starts, lags)
        self.assertEqual(len(expected), len(rec))
        error = max(abs(a - b) for a, b in zip(expected[:RATE], rec[:RATE]))
        self.assertLess(error, 1e-9)

    def test_timing_reports_a_step_between_segments(self):
        starts = [0, 32000, 64000]
        lags = [100, 100, 100 + 1600]
        got = align.timing(starts, lags)
        self.assertEqual(got["max_step_ms"], 100.0)
        self.assertEqual(got["steps"], [{"t": 4.0, "step_ms": 100.0}])


class StatsSummary(unittest.TestCase):
    def test_counters_are_deltas_over_the_window(self):
        rows = [{"t": 0, "concealedSamples": 100, "jitterBufferDelay": 1.0,
                 "jitterBufferEmittedCount": 1000, "bytesReceived": 0, "jitter": 0.01},
                {"t": 10000, "concealedSamples": 340, "jitterBufferDelay": 5.0,
                 "jitterBufferEmittedCount": 3000, "bytesReceived": 40000, "jitter": 0.03}]
        got = scenario.stats_summary(rows)
        self.assertEqual(got["concealedSamples"], 240)
        self.assertEqual(got["jitterBufferDelayMs"], 2.0)
        self.assertEqual(got["bitrateKbps"], 32.0)
        self.assertEqual(got["jitterMs"], 30.0)

    def test_fewer_than_two_rows_is_empty(self):
        self.assertEqual(scenario.stats_summary([{"t": 0}]), {})


if __name__ == "__main__":
    unittest.main()
