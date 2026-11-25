# SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
import unittest

import e2e_voice_latency as scenario
import voice_latency as lat


def _direction(sent, heard, n):
    return {"sent": sent, "heard": heard, "mouth_to_ear_ms": {"n": n}}


class Problems(unittest.TestCase):
    def test_a_dead_tap_is_a_problem_not_a_zero_share(self):
        row = {"vqa_to_vqb": _direction(0, 0, 0), "vqb_to_vqa": _direction(20, 20, 20)}
        self.assertEqual(len(scenario.problems("loss2", row)), 1)
        self.assertIsNone(lat.heard_fraction([], [], (0.0, 9000.0)))

    def test_chirps_sent_and_never_heard_is_a_problem(self):
        row = {"vqa_to_vqb": _direction(20, 0, 0), "vqb_to_vqa": _direction(20, 20, 20)}
        self.assertEqual(len(scenario.problems("burst", row)), 1)

    def test_a_clean_call_needs_enough_chirps_in_both_directions(self):
        row = {"vqa_to_vqb": _direction(20, 20, 20), "vqb_to_vqa": _direction(20, 20, 3)}
        self.assertEqual(len(scenario.problems("clean", row)), 1)
        self.assertEqual(scenario.problems("loss2", row), [])


class ExperienceProblems(unittest.TestCase):
    def test_a_run_that_measured_nothing_is_reported(self):
        import e2e_voice_experience as xp
        results = {"joins": [{"first_packet_ms": None}], "cut": {"time_to_packets_ms": None},
                   "speaking": {"clean": {"onsets": 5, "lit": 0, "missed": 5}}}
        self.assertEqual(len(xp.problems(results)), 3)
        good = {"joins": [{"first_packet_ms": 5}], "cut": {"time_to_packets_ms": 100},
                "speaking": {"clean": {"onsets": 5, "lit": 4, "missed": 1}}}
        self.assertEqual(xp.problems(good), [])

    def test_a_run_without_repeat_joins_or_a_short_cut_is_not_a_problem_by_itself(self):
        import e2e_voice_experience as xp
        results = {"joins": [], "speaking": {"clean": {"onsets": 5, "lit": 4, "missed": 1}}}
        self.assertEqual(xp.problems(results), [])

    def test_the_measured_baseline_passes_and_each_bound_fails_on_its_own(self):
        import e2e_voice_experience as xp
        cut = {"rejoined": False, "audio_tap_survived": True, "new_peer_connections": 0, "time_to_packets_ms": 456}
        base = {"joins": [{"cold": True, "in_call_ms": 631, "first_packet_ms": 908},
                          {"cold": False, "in_call_ms": 253, "first_packet_ms": 542}],
                "cuts": {"10s": [dict(cut)], "30s": [{"rejoined": True}]}, "cut": dict(cut),
                "speaking": {"clean": {"onsets": 4, "lit": 4, "delay_ms": {"p95": 178.8}}}}
        self.assertEqual(xp.problems(base), [])
        slow_cold = dict(base, joins=[{"cold": True, "first_packet_ms": 20000}])
        self.assertEqual(len(xp.problems(slow_cold)), 1)
        slow_warm = dict(base, joins=[{"cold": True, "first_packet_ms": 900}, {"cold": False, "first_packet_ms": 2500}])
        self.assertEqual(len(xp.problems(slow_warm)), 1)
        rebuilt = dict(base, cuts={"10s": [dict(cut, rejoined=True)]})
        self.assertEqual(len(xp.problems(rebuilt)), 1)
        new_pc = dict(base, cuts={"3s": [dict(cut, new_peer_connections=1)]})
        self.assertEqual(len(xp.problems(new_pc)), 1)
        late = dict(base, speaking={"burst": {"onsets": 4, "lit": 4, "delay_ms": {"p95": 3000}}})
        self.assertEqual(len(xp.problems(late)), 1)

    def test_a_cut_longer_than_the_ladder_may_rejoin_by_design(self):
        import e2e_voice_experience as xp
        results = {"joins": [], "cuts": {"60s": [{"rejoined": True, "new_peer_connections": 1}]}, "speaking": {}}
        self.assertEqual(xp.problems(results), [])

    def test_the_cut_row_is_the_longest_one_the_ladder_should_survive(self):
        import e2e_voice_experience as xp
        rows = {"3s": [{"n": 3}], "10s": [{"n": 10}, {"n": 11}], "60s": [{"n": 60}]}
        self.assertEqual(xp._representative_cut(rows), {"n": 10})
        self.assertIsNone(xp._representative_cut({"30s": [{"n": 30}]}))


if __name__ == "__main__":
    unittest.main()
