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

class TransientBed(unittest.TestCase):
    SPANS = [(1.0, 3.0), (5.6, 7.5), (10.1, 12.0), (14.6, 16.4),
             (19.0, 21.0), (23.6, 25.5), (28.1, 30.0), (32.6, 34.5)]

    def setUp(self):
        self.silent = [0.0] * (37 * RATE)
        self.noisy, self.events = nb.mix(self.silent, self.SPANS, transients=True)

    def test_every_transient_lands_once_in_a_gap_and_once_over_speech(self):
        kinds = {e["kind"] for e in self.events}
        for kind in nb.TRANSIENTS:
            self.assertIn(f"{kind}_gap", kinds)
            self.assertIn(f"{kind}_speech", kinds)

    def test_no_two_events_overlap(self):
        ordered = sorted(self.events, key=lambda e: e["start"])
        for first, second in zip(ordered, ordered[1:]):
            self.assertLessEqual(first["end"], second["start"], (first, second))

    def test_gap_events_sit_between_sentences_and_speech_events_inside_one(self):
        for event in [e for e in self.events if e["kind"].split("_")[0] in nb.TRANSIENTS]:
            inside = any(a <= event["start"] and event["end"] <= b + 0.2 for a, b in self.SPANS)
            if event["kind"].endswith("_speech"):
                self.assertTrue(inside, event)
            else:
                self.assertFalse(any(a < event["end"] and event["start"] < b for a, b in self.SPANS), event)

    def test_the_fixed_events_do_not_move_when_transients_are_added(self):
        plain = {e["kind"]: e for _, e in [(None, x) for x in nb.mix(self.silent, self.SPANS)[1]]}
        with_transients = {e["kind"]: e for e in self.events}
        for kind in plain:
            self.assertEqual(plain[kind], with_transients[kind])

    def test_a_recorded_clip_is_laid_as_given(self):
        clip = [0.25] * (RATE // 10)
        noisy, events = nb.mix(self.silent, self.SPANS, transients={"chew": clip})
        plain, _ = nb.mix(self.silent, self.SPANS)
        start = next(e for e in events if e["kind"] == "chew_gap")["start"]
        at = int(start * RATE) + 100
        self.assertAlmostEqual(noisy[at] - plain[at], 0.25, places=6)
        self.assertEqual({e["kind"] for e in events} - set(k["kind"] for k in nb.mix(self.silent, self.SPANS)[1]),
                         {"chew_gap", "chew_speech"})

    def test_it_still_never_clips(self):
        self.assertLessEqual(max(abs(v) for v in self.noisy), 1.0)


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


if __name__ == "__main__":
    unittest.main()
