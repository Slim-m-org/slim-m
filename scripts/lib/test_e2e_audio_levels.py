# SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
"""The maths the voice scenarios judge audio by, and the noisy fixture's shape."""
import math
import os
import sys
import tempfile
import unittest
import wave
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))

import e2e_audio_levels as lv  # noqa: E402
import make_noisy_voice  # noqa: E402


class LevelTest(unittest.TestCase):
    def test_full_scale_is_zero_db_and_half_is_minus_six(self):
        self.assertAlmostEqual(lv.rms_to_db(1.0), 0.0)
        self.assertAlmostEqual(lv.rms_to_db(0.5), -6.0206, places=3)

    def test_silence_has_a_finite_level(self):
        self.assertAlmostEqual(lv.rms_to_db(0.0), -120.0)

    def test_percentile_interpolates(self):
        self.assertEqual(lv.percentile([1, 2, 3, 4, 5], 50), 3)
        self.assertAlmostEqual(lv.percentile([0, 10], 25), 2.5)
        self.assertEqual(lv.percentile([7], 95), 7)

    def test_percentile_of_nothing_is_an_error(self):
        with self.assertRaises(ValueError):
            lv.percentile([], 50)

    def test_floor_and_speech_split_a_gap_from_a_syllable(self):
        levels = [-60.0] * 8 + [-20.0] * 8
        floor, speech = lv.floor_and_speech(levels)
        self.assertEqual(floor, -60.0)
        self.assertEqual(speech, -20.0)

    def test_noise_reduction_and_speech_loss_have_opposite_signs_of_trouble(self):
        self.assertEqual(lv.noise_reduction_db(-40.0, -55.0), 15.0)
        self.assertEqual(lv.speech_loss_db(-20.0, -23.0), 3.0)
        self.assertLess(lv.speech_loss_db(-20.0, -18.0), 0)


class VolumeTest(unittest.TestCase):
    def test_half_volume_is_about_minus_six_db(self):
        self.assertAlmostEqual(lv.volume_to_db(0.5), -6.0206, places=3)

    def test_double_volume_is_about_plus_six_db(self):
        self.assertAlmostEqual(lv.volume_to_db(2.0), 6.0206, places=3)

    def test_the_slider_follows_the_cube_below_normal_and_is_linear_above(self):
        self.assertAlmostEqual(lv.slider_to_gain(0.5), 0.125)
        self.assertEqual(lv.slider_to_gain(1.0), 1.0)
        self.assertEqual(lv.slider_to_gain(1.5), 1.5)
        self.assertEqual(lv.slider_to_gain(2.0), 2.0)

    def test_zero_is_silence(self):
        self.assertEqual(lv.volume_to_db(0.0), lv.SILENCE_DB)

    def test_two_silences_are_no_change(self):
        self.assertEqual(lv.level_change_db(-120.0, -100.0), 0.0)

    def test_a_drop_to_silence_is_measured_against_the_silence_floor(self):
        self.assertEqual(lv.level_change_db(-20.0, -120.0), lv.SILENCE_DB + 20.0)


class AppliedGainTest(unittest.TestCase):
    def test_unity_reads_zero_whatever_the_source_level(self):
        loud = [(0.1 * i, -20.0, -20.0) for i in range(10)]
        quiet = [(0.1 * i, -40.0, -40.0) for i in range(10)]
        self.assertAlmostEqual(lv.applied_gain_db(loud), 0.0)
        self.assertAlmostEqual(lv.applied_gain_db(quiet), 0.0)

    def test_half_volume_reads_minus_six_even_as_the_source_drifts(self):
        samples = [(0.1 * i, -20.0 - i + lv.volume_to_db(0.5), -20.0 - i)
                   for i in range(10)]
        self.assertAlmostEqual(lv.applied_gain_db(samples), -6.0206, places=3)

    def test_silenced_output_is_clamped_to_the_silence_floor(self):
        samples = [(0.1 * i, -120.0, -20.0) for i in range(5)]
        self.assertEqual(lv.applied_gain_db(samples), lv.SILENCE_DB + 20.0)

    def test_windows_with_an_inaudible_source_are_ignored(self):
        samples = [(0.0, -120.0, -90.0), (0.1, -26.0, -20.0), (0.2, -26.0, -20.0)]
        self.assertAlmostEqual(lv.applied_gain_db(samples), -6.0)

    def test_a_source_that_never_speaks_has_no_gain_to_report(self):
        self.assertIsNone(lv.applied_gain_db([(0.0, -120.0, -90.0)]))


class LeakTest(unittest.TestCase):
    def test_a_silenced_stream_has_no_leak(self):
        samples = [(0.1 * i, -120.0, -20.0) for i in range(5)]
        self.assertEqual(lv.loudest_heard_db(samples), -120.0)

    def test_one_loud_window_is_a_leak(self):
        samples = [(0.0, -120.0, -20.0), (0.1, -25.0, -20.0)]
        self.assertEqual(lv.loudest_heard_db(samples), -25.0)

    def test_an_inaudible_source_proves_nothing(self):
        self.assertIsNone(lv.loudest_heard_db([(0.0, -120.0, -90.0)]))


class GapTest(unittest.TestCase):
    def test_the_longest_run_between_loud_windows(self):
        samples = [(0.0, -20), (0.1, -90), (0.2, -90), (0.3, -20),
                   (0.4, -90), (0.5, -20)]
        self.assertAlmostEqual(lv.longest_gap_seconds(samples, -60), 0.3)

    def test_quiet_at_the_edges_is_not_a_gap(self):
        samples = [(0.0, -90), (0.1, -20), (0.2, -20), (0.3, -90)]
        self.assertAlmostEqual(lv.longest_gap_seconds(samples, -60), 0.1)

    def test_all_quiet_has_no_gap_to_report(self):
        self.assertEqual(lv.longest_gap_seconds([(0, -90), (1, -90)], -60), 0.0)


class TrailingGapTest(unittest.TestCase):
    def test_silence_after_the_last_loud_window_counts_up_to_the_read(self):
        samples = [(0.0, -20), (0.1, -20), (0.2, -90), (0.3, -90)]
        self.assertAlmostEqual(
            lv.longest_gap_seconds(samples, -60, until=6.0), 5.9)

    def test_a_series_that_never_gets_loud_is_one_gap(self):
        samples = [(1.0, -90), (1.1, -90)]
        self.assertAlmostEqual(
            lv.longest_gap_seconds(samples, -60, until=4.0), 3.0)

    def test_audio_up_to_the_read_leaves_the_gap_alone(self):
        samples = [(0.0, -20), (0.5, -90), (1.0, -20)]
        self.assertAlmostEqual(
            lv.longest_gap_seconds(samples, -60, until=1.0), 1.0)


class FixturePausesTest(unittest.TestCase):
    """The fake voice's own pauses must stay clear of the mic-switch bound."""

    def test_its_natural_gaps_are_far_below_a_dropout(self):
        import make_fake_voice
        window = make_fake_voice.RATE // 20
        pcm = list(make_fake_voice.samples())
        levels = []
        for i in range(0, len(pcm) - window, window):
            chunk = pcm[i:i + window]
            rms = math.sqrt(sum(v * v for v in chunk) / window) / 32768
            levels.append(((i / make_fake_voice.RATE), lv.rms_to_db(rms)))
        speech = lv.percentile([db for _, db in levels], 95)
        gap = lv.longest_gap_seconds(levels, speech - 25.0)
        # Measured 2026-10-18 at 50 ms windows: 0.15 s between syllables; the scenario allows 1.5 s.
        self.assertLess(gap, 0.3)


class UnplayedTest(unittest.TestCase):
    def test_stalled_windows_make_a_measurement_unusable(self):
        rows = [[i * 50, 0.0, 0.1, "stalled"] for i in range(10)]
        with self.assertRaises(AssertionError):
            lv.refuse_unplayed(rows, "alice", "s1")

    def test_a_few_flagged_windows_are_tolerated(self):
        rows = [[i * 50, 0.1, 0.1, ""] for i in range(20)]
        rows[0][3] = "stalled"
        lv.refuse_unplayed(rows, "alice", "s1")

    def test_a_suspended_context_is_named(self):
        rows = [[0, 0.0, 0.1, "suspended"]]
        with self.assertRaisesRegex(AssertionError, "suspended"):
            lv.refuse_unplayed(rows, "alice", "s1")


class NoisyFixtureTest(unittest.TestCase):
    def _rms_db(self, values):
        power = sum(v * v for v in values) / len(values)
        return 20 * math.log10(math.sqrt(power) / 32768)

    def test_it_is_deterministic(self):
        with tempfile.TemporaryDirectory() as tmp:
            one, two = os.path.join(tmp, "1.wav"), os.path.join(tmp, "2.wav")
            make_noisy_voice.write(one)
            make_noisy_voice.write(two)
            with open(one, "rb") as f1, open(two, "rb") as f2:
                self.assertEqual(f1.read(), f2.read())

    def test_speech_is_well_above_the_noise_it_sits_on(self):
        values = list(make_noisy_voice.samples())
        rate = make_noisy_voice.voice.RATE
        speech = values[:int(rate * make_noisy_voice.SPEECH_SECONDS)]
        gap = values[int(rate * (make_noisy_voice.SPEECH_SECONDS + 0.5)):]
        self.assertGreater(self._rms_db(speech) - self._rms_db(gap), 8)

    def test_the_gap_holds_steady_noise_not_silence(self):
        values = list(make_noisy_voice.samples())
        rate = make_noisy_voice.voice.RATE
        gap = values[int(rate * (make_noisy_voice.SPEECH_SECONDS + 0.5)):]
        self.assertGreater(self._rms_db(gap), -45)

    def test_it_is_mono_48k_16_bit(self):
        with tempfile.TemporaryDirectory() as tmp:
            path = os.path.join(tmp, "n.wav")
            make_noisy_voice.write(path)
            with wave.open(path) as w:
                self.assertEqual((w.getnchannels(), w.getsampwidth(),
                                  w.getframerate()), (1, 2, 48000))


class BoostIsLimitedTests(unittest.TestCase):
    def test_under_full_scale_is_fine(self):
        self.assertTrue(lv.boost_is_limited(0.97))

    def test_output_past_full_scale_is_a_clip(self):
        self.assertFalse(lv.boost_is_limited(1.3))


if __name__ == "__main__":
    unittest.main()
