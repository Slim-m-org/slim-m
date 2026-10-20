# SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
"""The voice quality analysis, on a reference clip with artefacts injected at known times."""
import random
import sys
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))

import make_quality_clip as clip  # noqa: E402
import voice_quality as vq  # noqa: E402
import voice_quality_dsp as dsp  # noqa: E402

RATE = dsp.ANALYSIS_RATE
SECONDS = 14


def _reference():
    full = clip.build("A")
    return dsp.decimate(full[:SECONDS * clip.RATE], clip.RATE)


def _received(ref, offset_s=1.37, gain=0.8):
    """The clip looped from `offset_s` in, as a call delivers it, twice as long as needed."""
    loop = ref * 2
    start = int(offset_s * RATE)
    return [v * gain for v in loop[start:start + len(ref)]]


def _span(kind, events, near, tolerance=0.3):
    return [e for e in events
            if e["class"] == kind and abs(e["t"] - near) <= tolerance]


class InjectedArtefactTest(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.ref = _reference()
        cls.clean = vq.analyze(cls.ref, RATE, _received(cls.ref), RATE)

    def test_a_clean_copy_has_no_anomalies_and_scores_high(self):
        self.assertEqual(self.clean["counts"], {}, self.clean["events"])
        self.assertGreater(self.clean["similarity"], 0.95)

    def test_alignment_survives_the_clip_looping_and_a_gain_change(self):
        self.assertAlmostEqual(self.clean["gain_db"], -1.94, delta=0.5)
        self.assertLess(abs(self.clean["timing"]["drift_ms"]), 2.0)

    def _inject(self, mutate):
        rec = _received(self.ref)
        mutate(rec)
        return vq.analyze(self.ref, RATE, rec, RATE)

    def test_a_gap_inside_speech_is_a_dropout(self):
        def gap(rec):
            for i in range(int(3.5 * RATE), int(3.65 * RATE)):
                rec[i] = 0.0
        report = self._inject(gap)
        self.assertTrue(_span("dropout", report["events"], 3.5), report["events"])

    def test_a_single_sample_step_is_a_click(self):
        def click(rec):
            rec[int(5.0 * RATE)] += 0.4
        report = self._inject(click)
        self.assertTrue(_span("click", report["events"], 5.0), report["events"])

    def test_noise_in_a_silence_gap_is_static(self):
        rng = random.Random(3)

        def burst(rec):
            # The clip is digitally silent from 1.96 s to 2.23 s, which lands at 0.59 s in the recording.
            at = int(0.62 * RATE)
            for i in range(at, at + int(0.2 * RATE)):
                rec[i] += rng.uniform(-0.05, 0.05)
        report = self._inject(burst)
        self.assertTrue(_span("static", report["events"], 0.62, tolerance=0.3),
                        report["events"])

    def test_a_steady_tone_not_in_the_reference_is_found_with_its_pitch(self):
        import math

        def tone(rec):
            for i in range(int(6.0 * RATE), int(6.6 * RATE)):
                rec[i] += 0.05 * math.sin(2 * math.pi * 1500 * i / RATE)
        report = self._inject(tone)
        found = _span("tone", report["events"], 6.0, tolerance=0.4)
        self.assertTrue(found, report["events"])
        self.assertIn("15", found[0]["detail"])

    def test_a_loud_stretch_over_the_reference_is_a_level_burst(self):
        def boost(rec):
            for i in range(int(3.4 * RATE), int(3.8 * RATE)):
                rec[i] *= 2.5
        report = self._inject(boost)
        self.assertTrue(_span("level_burst", report["events"], 3.4), report["events"])

    def test_samples_pinned_at_full_scale_are_clipping(self):
        def clip_it(rec):
            for i in range(int(7.0 * RATE), int(7.0 * RATE) + 20):
                rec[i] = 1.0
        report = self._inject(clip_it)
        self.assertTrue(_span("clipping", report["events"], 7.0, 0.1))

    def test_a_delay_step_shows_in_the_timing(self):
        rec = _received(self.ref)
        shifted = rec[:int(8 * RATE)] + rec[int(8 * RATE) - 480:-480]
        report = vq.analyze(self.ref, RATE, shifted, RATE)
        self.assertGreaterEqual(report["timing"]["max_step_ms"], 20.0)

    def test_a_large_delay_step_is_followed_not_clamped(self):
        rec = _received(self.ref)
        cut = int(6 * RATE)
        step = int(0.1 * RATE)
        shifted = rec[:cut] + rec[cut - step:-step]
        report = vq.analyze(self.ref, RATE, shifted, RATE)
        self.assertAlmostEqual(report["timing"]["max_step_ms"], 100.0, delta=10.0)
        self.assertEqual(report["timing"]["lost_s"], 0.0)
        self.assertEqual(report["counts"].get("dropout", 0), 0, report["events"])
        self.assertEqual(report["counts"].get("level_burst", 0), 0, report["events"])

    def test_a_stretch_that_matches_nothing_is_reported_lost_not_counted(self):
        rng = random.Random(5)
        rec = _received(self.ref)
        for i in range(int(6 * RATE), int(10 * RATE)):
            rec[i] = rng.uniform(-0.3, 0.3)
        report = vq.analyze(self.ref, RATE, rec, RATE)
        self.assertGreaterEqual(report["timing"]["lost_s"], 2.0)
        lost_from, lost_to = 6.0, 10.0
        inside = [e for e in report["events"]
                  if e["class"] != "clipping" and lost_from <= e["t"] < lost_to]
        self.assertEqual(inside, [])


class DetectorHelpersTest(unittest.TestCase):
    def test_runs_bridge_one_missed_frame_and_drop_short_spans(self):
        flags = [False, True, True, False, True, True, False, False, False, True]
        self.assertEqual(vq._runs(flags, 3), [(1, 5)])

    def test_flatness_separates_noise_from_a_tone(self):
        rng = random.Random(1)
        noise = [rng.uniform(-1, 1) for _ in range(dsp.FRAME)]
        import math
        tone = [math.sin(2 * math.pi * 1000 * i / RATE) for i in range(dsp.FRAME)]
        flat_noise = vq._flatness(dsp.power_spectrogram(noise)[0])
        flat_tone = vq._flatness(dsp.power_spectrogram(tone)[0])
        self.assertGreater(flat_noise, 0.3)
        self.assertLess(flat_tone, 0.05)


if __name__ == "__main__":
    unittest.main()


class TrailingClip(unittest.TestCase):
    def test_a_run_pinned_at_full_scale_to_the_end_is_counted(self):
        raw = [0.1] * 100 + [1.0] * 10
        self.assertEqual(len(vq.find_clipping(raw, 48000)), 1)
