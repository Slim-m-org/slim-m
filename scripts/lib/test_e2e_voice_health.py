# SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
import unittest
from unittest import mock

import e2e_voice_health as vh

MINUTE = ("[voice-health] last 60s | Bob: conceal={c}% events=0 jitter=1ms buffer=37ms "
          "loss=0.0% level=-8dB rtt=1ms discarded=3014 accel=1892ms | you: sent=68kbps")


class Client:
    name = "alice"


class MinuteLineIn(unittest.TestCase):
    def test_it_finds_the_line_inside_a_copied_report(self):
        report = "Call diagnostics\nAudio\n" + MINUTE.format(c="0.0") + "\n\nVideo\nNo video was sampled."
        self.assertEqual(vh._minute_line_in(report), MINUTE.format(c="0.0"))

    def test_a_report_before_the_first_minute_has_none(self):
        self.assertIsNone(vh._minute_line_in("Audio\nNo once-a-minute audio line yet.\nVideo"))


class QuietMinute(unittest.TestCase):
    def test_a_clean_minute_is_taken_as_it_is(self):
        line = MINUTE.format(c="0.0")
        self.assertEqual(vh._quiet_minute(Client(), line), line)

    def test_one_stalled_minute_is_measured_again(self):
        stalled, clean = MINUTE.format(c="2.7"), MINUTE.format(c="0.1")
        with mock.patch.object(vh, "_wait_for_minute_line", return_value=clean) as wait:
            self.assertEqual(vh._quiet_minute(Client(), stalled), clean)
        self.assertEqual(wait.call_args.kwargs["after"], stalled)

    def test_concealment_every_minute_still_fails(self):
        with mock.patch.object(vh, "_wait_for_minute_line", return_value=MINUTE.format(c="4.0")):
            with self.assertRaises(AssertionError):
                vh._quiet_minute(Client(), MINUTE.format(c="2.7"))


if __name__ == "__main__":
    unittest.main()
