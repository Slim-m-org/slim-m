# SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
import math
import random
import unittest

import voice_noise as vn

RATE = 16000
SPANS = [(1.0, 3.0), (6.0, 8.0), (11.0, 13.0)]
EVENTS = [{"kind": "typing_gap", "start": 4.0, "end": 5.0},
          {"kind": "bark_speech", "start": 6.5, "end": 7.0}]


def _speech(spans=SPANS):
    out = [0.0] * (15 * RATE)
    for a, b in spans:
        for i in range(int(a * RATE), int(b * RATE)):
            t = i / RATE
            burst = 0.5 + 0.5 * math.sin(2 * math.pi * 3 * t)
            out[i] = 0.25 * burst * sum(math.sin(2 * math.pi * f * t) / k
                                        for k, f in enumerate((140, 280, 420, 560), 1))
    return out


def _noise(events=EVENTS):
    rng = random.Random(1)
    bed = [0.01 * math.sin(2 * math.pi * 100 * i / RATE) for i in range(15 * RATE)]
    for e in events:
        for i in range(int(e["start"] * RATE), int(e["end"] * RATE)):
            bed[i] += rng.uniform(-0.2, 0.2)
    return bed


def _sum(a, b):
    return [x + y for x, y in zip(a, b)]


class Noise(unittest.TestCase):
    def setUp(self):
        self.clean = (_speech(), RATE)
        self.mix = (_sum(self.clean[0], _noise()), RATE)

    def run_with(self, rec):
        return vn.analyze(self.clean, self.mix, (rec, RATE), SPANS, EVENTS)

    def test_an_untouched_mix_changes_nothing(self):
        got = self.run_with(self.mix[0])
        self.assertAlmostEqual(got["hum_floor"]["change_db"], 0.0, delta=0.5)
        self.assertAlmostEqual(got["typing_gap"]["change_db"], 0.0, delta=0.5)
        self.assertEqual(got["onsets"]["clipped"], 0)

    def test_a_perfect_gate_removes_the_floor_and_the_gap_noise(self):
        rec = [v if any(a <= i / RATE < b for a, b in SPANS) else 0.0
               for i, v in enumerate(self.mix[0])]
        got = self.run_with(rec)
        self.assertLess(got["hum_floor"]["change_db"], -40)
        self.assertLess(got["typing_gap"]["change_db"], -40)
        self.assertGreater(got["bark_speech"]["change_db"], -3)
        self.assertEqual(got["onsets"]["clipped"], 0)

    def test_a_late_gate_clips_each_word_start(self):
        rec = list(self.mix[0])
        for a, b in SPANS:
            for i in range(int(a * RATE), int((a + 0.1) * RATE)):
                rec[i] = 0.0
        got = self.run_with(rec)
        self.assertEqual(got["onsets"]["clipped"], 3)
        self.assertGreaterEqual(got["onsets"]["mean_lost_ms"], 70)

    def test_a_suppressed_soft_lead_in_is_not_a_clipped_word_start(self):
        lead = [0.0] * len(self.clean[0])
        for a, _ in SPANS:
            for i in range(int((a - 0.12) * RATE), int(a * RATE)):
                lead[i] = 0.02 * math.sin(2 * math.pi * 300 * i / RATE)
        clean = (_sum(self.clean[0], lead), RATE)
        mix = (_sum(clean[0], _noise()), RATE)
        rec = [0.0 if v else m for v, m in zip(lead, _sum(self.clean[0], _noise()))]
        spans = [(a - 0.12, b) for a, b in SPANS]
        got = vn.analyze(clean, mix, (rec, RATE), spans, EVENTS)
        self.assertEqual(got["onsets"]["clipped"], 3)
        self.assertEqual(got["onsets"]["loud"]["clipped"], 0)

    def test_a_late_gate_clips_loud_word_starts_too(self):
        rec = list(self.mix[0])
        for a, _ in SPANS:
            for i in range(int(a * RATE), int((a + 0.1) * RATE)):
                rec[i] = 0.0
        got = self.run_with(rec)
        self.assertEqual(got["onsets"]["loud"]["clipped"], 3)

    def test_a_quieter_call_reads_as_a_speech_level_change(self):
        rec = [v * 0.5 for v in self.mix[0]]
        got = self.run_with(rec)
        self.assertAlmostEqual(got["speech_level_change_db"], -6.0, delta=1.0)
        self.assertEqual(got["onsets"]["clipped"], 0)

    def test_noise_left_over_speech_shows_as_excess(self):
        got = self.run_with(self.mix[0])
        self.assertGreater(got["bark_speech"]["excess_over_speech_db"], 2.0)


class LoopedRecording(unittest.TestCase):
    # Aperiodic on purpose: a clip that repeats within the loop has several equally good alignments.
    spans = [(1.0, 3.0), (5.5, 8.5), (11.7, 13.0)]
    events = [{"kind": "typing_gap", "start": 4.0, "end": 5.0},
              {"kind": "bark_speech", "start": 12.0, "end": 12.6}]

    def _looped(self, offset_s):
        clean = (_speech(self.spans), RATE)
        mix = (_sum(clean[0], _noise(self.events)), RATE)
        start = int(offset_s * RATE)
        looped = (mix[0] * 2)[start:start + len(mix[0])]
        return vn.analyze(clean, mix, (looped, RATE), self.spans, self.events)

    def test_a_recording_that_starts_mid_clip_scores_like_one_that_starts_at_zero(self):
        got = self._looped(5.2)
        self.assertEqual(got["onsets"]["clipped"], 0)
        self.assertAlmostEqual(got["hum_floor"]["change_db"], 0.0, delta=0.5)
        self.assertAlmostEqual(got["typing_gap"]["change_db"], 0.0, delta=0.5)

    def test_an_event_straddling_the_loop_seam_is_still_scored(self):
        got = self._looped(12.3)
        self.assertAlmostEqual(got["bark_speech"]["change_db"], 0.0, delta=1.0)
        self.assertEqual(got["onsets"]["clipped"], 0)


if __name__ == "__main__":
    unittest.main()
