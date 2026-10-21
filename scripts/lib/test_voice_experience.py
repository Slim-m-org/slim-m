# SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
import math
import unittest

import voice_experience as ex

RATE = ex.RATE


def _tone(seconds, level=0.3):
    return [level * math.sin(2 * math.pi * 300 * i / RATE) for i in range(int(seconds * RATE))]


def _quiet(seconds):
    return [0.0] * int(seconds * RATE)


class JoinRow(unittest.TestCase):
    def test_states_are_measured_from_the_click(self):
        events = [{"n": "click", "t": 1000.0},
                  {"n": "first-packet", "t": 1400.0},
                  {"n": "label", "t": 1250.0, "text": "in call", "on": True},
                  {"n": "first-energy", "t": 1900.0}]
        got = ex.join_row(events, cold=True)
        self.assertEqual((got["in_call_ms"], got["first_packet_ms"], got["first_energy_ms"]),
                         (250, 400, 900))
        self.assertTrue(got["cold"])

    def test_a_state_that_never_came_is_none(self):
        got = ex.join_row([{"n": "click", "t": 10.0}], cold=False)
        self.assertIsNone(got["first_packet_ms"])


class CutRow(unittest.TestCase):
    def test_audio_that_returns_after_the_link_does(self):
        # Heard for 2 s, silent for the 4 s outage and 1 s after, heard again.
        samples = _tone(2) + _quiet(5) + _tone(2)
        start = 0.0
        t_cut, t_back = 2000.0, 6000.0
        series = [{"t": 1000.0, "packets": 50}, {"t": 5900.0, "packets": 90},
                  {"t": 6300.0, "packets": 100}]
        events = [{"n": "ice", "t": 2500.0, "v": "disconnected"},
                  {"n": "ice", "t": 6100.0, "v": "connected"}]
        got = ex.cut_row(samples, start, events, series, t_cut, t_back)
        self.assertEqual(got["outage_ms"], 4000)
        self.assertAlmostEqual(got["time_to_audio_ms"], 1000, delta=20)
        self.assertEqual(got["time_to_packets_ms"], 300)
        self.assertFalse(got["rejoined"])
        self.assertEqual(got["transport"]["ice_disconnected_ms"], 500)

    def test_a_new_peer_connection_after_the_cut_is_a_rejoin(self):
        events = [{"n": "pc-new", "t": 9000.0, "pc": 2}]
        got = ex.cut_row(_quiet(1), 0.0, events, [], 2000.0, 6000.0)
        self.assertTrue(got["rejoined"])


class SpeakingRow(unittest.TestCase):
    def test_delay_is_ring_minus_onset(self):
        samples = _quiet(3) + _tone(1) + _quiet(3) + _tone(1)
        events = [{"n": "label", "t": 3300.0, "on": True},
                  {"n": "label", "t": 4600.0, "on": False},
                  {"n": "label", "t": 7500.0, "on": True}]
        got = ex.speaking_row(samples, 0.0, events)
        self.assertEqual((got["onsets"], got["lit"], got["missed"]), (2, 2, 0))
        self.assertAlmostEqual(got["delay_ms"]["min"], 300, delta=15)
        self.assertAlmostEqual(got["delay_ms"]["max"], 500, delta=15)

    def test_a_ring_that_never_lights_is_a_miss(self):
        got = ex.speaking_row(_quiet(3) + _tone(1), 0.0, [])
        self.assertEqual((got["lit"], got["missed"]), (0, 1))

    def test_an_onset_with_the_ring_already_lit_is_skipped(self):
        events = [{"n": "label", "t": 100.0, "on": True}]
        got = ex.speaking_row(_quiet(3) + _tone(1), 0.0, events)
        self.assertEqual((got["lit"], got["missed"]), (0, 0))

class ResumedAfter(unittest.TestCase):
    def test_the_same_connection_resumes_past_its_own_count(self):
        series = [{"t": 0, "pc": 0, "packets": 1000}, {"t": 2000, "pc": 0, "packets": 1000},
                  {"t": 2600, "pc": 0, "packets": 1010}]
        self.assertEqual(ex.resumed_after(series, 2000), [2600])

    def test_a_rejoins_new_connection_resumes_on_its_first_packets(self):
        series = [{"t": 0, "pc": 0, "packets": 1000}, {"t": 2000, "pc": 0, "packets": 1000},
                  {"t": 3500, "pc": 1, "packets": 40}]
        self.assertEqual(ex.resumed_after(series, 2000), [3500])


class CutRowAfterARejoin(unittest.TestCase):
    def test_a_rejoin_makes_the_audio_time_unmeasurable_not_never(self):
        events = [{"n": "pc-new", "t": 5000.0}]
        samples = _quiet(3) + _tone(1)
        got = ex.cut_row(samples, 0.0, events, [], 1000.0, 2000.0)
        self.assertTrue(got["rejoined"])
        self.assertIsNone(got["time_to_audio_ms"])
        self.assertFalse(got["audio_tap_survived"])

    def test_without_a_rejoin_the_audio_time_is_reported(self):
        got = ex.cut_row(_quiet(3) + _tone(1), 0.0, [], [], 1000.0, 2000.0)
        self.assertTrue(got["audio_tap_survived"])
        self.assertIsNotNone(got["time_to_audio_ms"])


if __name__ == "__main__":
    unittest.main()
