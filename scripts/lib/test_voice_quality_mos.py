# SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
import importlib.util
import random
import unittest

import voice_quality_dsp as dsp
import voice_quality_mos as mos

RATE = dsp.ANALYSIS_RATE


def _talk(spans, total_s):
    out = [0.0] * int(total_s * RATE)
    for a, b in spans:
        for i in range(int(a * RATE), int(b * RATE)):
            out[i] = 0.3
    return out


class SpeechMask(unittest.TestCase):
    def test_marks_the_talking_and_bridges_short_pauses(self):
        ref = _talk([(1.0, 2.0), (2.2, 3.0), (6.0, 7.0)], 9.0)
        mask = mos.speech_mask(ref)
        self.assertEqual(mask[int(1.5 * RATE)], 1.0)
        self.assertEqual(mask[int(2.1 * RATE)], 1.0)
        self.assertEqual(mask[int(4.5 * RATE)], 0.0)
        self.assertEqual(len(mask), len(ref))

    def test_runs_drop_the_short_ones(self):
        mask = [1.0 if v else 0.0 for v in _talk([(0.5, 1.0), (2.0, 6.0)], 8.0)]
        spans = mos.runs(mask, int(3.0 * RATE))
        self.assertEqual(len(spans), 1)
        self.assertAlmostEqual(spans[0][0] / RATE, 2.0, places=1)


@unittest.skipUnless(importlib.util.find_spec("speechmos"), "needs the mos venv")
class Scores(unittest.TestCase):
    def test_noise_scores_below_a_cleaner_copy(self):
        import numpy as np
        from speechmos import dnsmos
        t = np.arange(RATE * 10) / RATE
        voice = 0.3 * sum(np.sin(2 * np.pi * f * t) / k
                          for k, f in enumerate((150, 300, 450, 600), 1))
        noisy = np.clip(voice + np.random.default_rng(1).normal(0, 0.15, len(t)), -1, 1)
        clean = dnsmos.run(voice.astype("float32"), RATE)["ovrl_mos"]
        dirty = dnsmos.run(noisy.astype("float32"), RATE)["ovrl_mos"]
        self.assertGreater(clean, dirty)


class VisqolCsv(unittest.TestCase):
    def test_rows_are_matched_by_file_name_not_position(self):
        text = ("reference,degraded,moslqo,vnsim\n"
                "/work/ref1.wav,/work/deg1.wav,3.9,0.8\n"
                "/work/ref0.wav,/work/deg0.wav,4.5,0.9\n")
        self.assertEqual(mos.parse_visqol_csv(text, 3), [4.5, 3.9, None])


class Failures(unittest.TestCase):
    def test_an_empty_recording_is_an_error_not_a_crash_of_the_batch(self):
        with self.assertRaises(ValueError):
            mos.score([0.1] * RATE, RATE, [], RATE)

    def test_the_aligner_returns_nothing_for_an_empty_recording(self):
        import voice_quality_align as align
        self.assertEqual(align.track_locked([0.1] * RATE, []), ([], [], []))


if __name__ == "__main__":
    unittest.main()
