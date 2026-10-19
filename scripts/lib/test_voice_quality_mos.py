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


if __name__ == "__main__":
    unittest.main()
