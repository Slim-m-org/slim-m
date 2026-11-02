# SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
import math
import unittest

import e2e_voice_transients as tr

RATE = 48000


def _noise(speech=0.5, gap_peaks=None):
    """A scored row in the shape voice_noise.analyze returns, with the fields the scenario reads."""
    events = {}
    for kind, peak in (gap_peaks or {}).items():
        events[kind] = {"change_db": -5.0, "peak_change_db": peak, "over_speech_db": -20.0}
    return {"noise": {"speech_level_change_db": speech, "hum_floor": {"change_db": -20.0},
                      "onsets": {"clipped": 0, "count": 10}, **events}}


class LoudestWindow(unittest.TestCase):
    def test_it_picks_the_stretch_with_the_sound_in_it(self):
        quiet = [0.0] * (3 * RATE)
        loud = [0.3 * math.sin(i / 7) for i in range(RATE)]
        samples = quiet + loud + quiet
        got = tr.loudest_window(samples, 1.5)
        self.assertEqual(len(got), int(1.5 * RATE))
        self.assertGreater(sum(v * v for v in got), 0.9 * sum(v * v for v in loud))

    def test_a_short_clip_comes_back_whole(self):
        clip = [0.1] * RATE
        self.assertEqual(tr.loudest_window(clip, 1.5), clip)


class Judgement(unittest.TestCase):
    def test_a_quiet_run_passes(self):
        results = {"piper": {"strong-gate-on": {"clean": _noise(gap_peaks={"chew_gap": -3.0})}}}
        self.assertEqual(tr.problems(results), [])

    def test_a_gap_event_that_comes_out_louder_fails(self):
        results = {"piper": {"strong-agc-off": {"clean": _noise(gap_peaks={"chew_gap": 1.5})}}}
        self.assertEqual(len(tr.problems(results)), 1)
        self.assertIn("chew_gap", tr.problems(results)[0])

    def test_the_standard_arm_is_reported_and_not_judged_for_amplification(self):
        results = {"piper": {"standard-gate-on": {"clean": _noise(gap_peaks={"chew_gap": 7.5})}}}
        self.assertEqual(tr.problems(results), [])
        results = {"piper": {"strongest-gate-on": {"clean": _noise(gap_peaks={"chew_gap": 1.5})}}}
        self.assertEqual(len(tr.problems(results)), 1)

    def test_speech_that_drifts_fails(self):
        results = {"piper": {"standard-gate-on": {"clean": _noise(speech=-4.0)}}}
        self.assertTrue(any("speech moved" in p for p in tr.problems(results)))

    def test_events_over_speech_are_not_judged_for_amplification(self):
        results = {"piper": {"strong-agc-off": {"clean": _noise(gap_peaks={"chew_speech": 6.0})}}}
        self.assertEqual(tr.problems(results), [])

    def test_the_table_names_every_gap_event(self):
        results = {"piper": {"strong-gate-on": {"clean": _noise(gap_peaks={"chew_gap": -3.0, "smack_gap": -9.0}),
                                                "gate_log": {"readings": 1}}}}
        lines = tr.table(results)
        self.assertIn("chew_gap", lines)
        self.assertIn("smack_gap", lines)
        self.assertIn("speech +0.5 dB", lines)


if __name__ == "__main__":
    unittest.main()
