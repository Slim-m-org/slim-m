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


if __name__ == "__main__":
    unittest.main()
