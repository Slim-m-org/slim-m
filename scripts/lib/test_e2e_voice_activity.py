# SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
import unittest

import e2e_voice_activity as va
import make_fake_voice


class LitWhileAudible(unittest.TestCase):
    def test_counts_only_samples_taken_while_the_voice_was_heard(self):
        levels = [(0.0, -30.0), (0.5, -80.0), (1.0, -30.0)]
        ring = [(0.1, True), (0.6, False), (1.1, False)]
        self.assertEqual(va.lit_while_audible(levels, ring), 0.5)

    def test_a_voice_never_heard_has_no_share(self):
        self.assertIsNone(va.lit_while_audible([(0.0, -90.0)], [(0.1, False)]))

    def test_a_short_syllable_gap_still_counts_as_audible(self):
        self.assertEqual(va.lit_while_audible([(1.0, -20.0)], [(1.2, True)]), 1.0)


class SoftButUnlit(unittest.TestCase):
    def test_flags_a_heard_voice_with_a_dark_ring(self):
        rounds = [{"heard_db": -35.0, "lit": 0.1}, {"heard_db": -35.0, "lit": 0.9}]
        self.assertEqual(va.soft_but_unlit(rounds), [rounds[0]])

    def test_a_voice_too_quiet_to_hear_is_not_held_against_the_ring(self):
        self.assertEqual(va.soft_but_unlit([{"heard_db": -70.0, "lit": None}]), [])


class LitShare(unittest.TestCase):
    def test_counts_every_sample(self):
        self.assertEqual(va.lit_share([(0.1, True), (0.2, False)]), 0.5)

    def test_no_samples_is_never_lit(self):
        self.assertEqual(va.lit_share([]), 0.0)


class FakeVoiceLevel(unittest.TestCase):
    def test_amplitude_scales_the_voice(self):
        def peak(amplitude):
            return max(abs(s) for s in make_fake_voice.samples(amplitude=amplitude))
        self.assertAlmostEqual(peak(0.1) / peak(0.5), 0.2, delta=0.01)


if __name__ == "__main__":
    unittest.main()
