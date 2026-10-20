# SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
import math
import unittest

import make_noise_bed as nb

RATE = nb.RATE


def _rms_db(samples):
    return 10 * math.log10(sum(v * v for v in samples) / len(samples) + 1e-12)


class NoiseBed(unittest.TestCase):
    def setUp(self):
        self.spans = [(1.0, 2.0), (4.0, 5.0), (7.0, 8.0), (10.0, 11.0),
                      (13.0, 14.0), (16.0, 17.0), (19.0, 20.0)]
        self.silent = [0.0] * (22 * RATE)
        self.noisy, self.events = nb.mix(self.silent, self.spans)

    def test_the_fan_runs_everywhere_at_a_modest_level(self):
        floor = self.noisy[int(5.3 * RATE):int(6.7 * RATE)]
        self.assertAlmostEqual(_rms_db(floor), 20 * math.log10(nb.HUM_RMS), delta=2.5)

    def test_events_sit_where_the_plan_says(self):
        kinds = {e["kind"]: e for e in self.events}
        self.assertEqual(set(kinds), {"typing_gap", "typing_speech", "bark_gap", "bark_speech"})
        self.assertAlmostEqual(kinds["typing_gap"]["start"], 2.5, places=2)
        self.assertAlmostEqual(kinds["bark_speech"]["start"], 17.0, places=2)

    def test_a_bark_is_far_louder_than_the_hum(self):
        bark = next(e for e in self.events if e["kind"] == "bark_gap")
        window = self.noisy[int(bark["start"] * RATE):int((bark["start"] + 0.3) * RATE)]
        floor = self.noisy[int(5.3 * RATE):int(5.6 * RATE)]
        self.assertGreater(_rms_db(window) - _rms_db(floor), 10)

    def test_the_same_seed_gives_the_same_bed(self):
        again, _ = nb.mix(self.silent, self.spans)
        self.assertEqual(self.noisy[:5000], again[:5000])

    def test_it_never_clips(self):
        self.assertLessEqual(max(abs(v) for v in self.noisy), 1.0)


if __name__ == "__main__":
    unittest.main()


class PlanForShortClips(unittest.TestCase):
    SIX = [(0.0, 1.0), (2.0, 3.0), (4.0, 5.0), (6.0, 7.0), (8.0, 9.0), (10.0, 11.0)]

    def test_six_spans_keep_the_fixed_places(self):
        self.assertEqual(nb.plan(self.SIX),
                         [("typing_gap", 1.5), ("typing_speech", 4.6),
                          ("bark_gap", 7.7), ("bark_speech", 11.0)])

    def test_a_short_clip_still_gets_all_four_events(self):
        events = nb.plan(self.SIX[:4])
        self.assertEqual([kind for kind, _ in events],
                         ["typing_gap", "typing_speech", "bark_gap", "bark_speech"])
        self.assertEqual(events[3], ("bark_speech", 7.0))

    def test_a_single_span_does_not_crash(self):
        self.assertEqual(len(nb.plan(self.SIX[:1])), 4)
