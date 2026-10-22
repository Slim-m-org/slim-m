# SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
"""The measurement helpers the voice scenarios stand on, against a fake page."""
import json
import sys
import unittest
from pathlib import Path
import unittest.mock
from unittest.mock import patch

sys.path.insert(0, str(Path(__file__).resolve().parent))

import e2e_audio  # noqa: E402
import e2e_browsers  # noqa: E402
import e2e_run  # noqa: E402
import e2e_voice_ui as ui  # noqa: E402
import e2e_voice_multishare as multishare  # noqa: E402


class FakePage:
    """Answers `ev` calls with canned values keyed by a fragment of the script."""

    def __init__(self, answers, name="alice"):
        self.name = name
        self.answers = answers
        self.calls = []

    def ev(self, script):
        self.calls.append(script)
        for fragment, value in self.answers.items():
            if fragment in script:
                return value() if callable(value) else value
        return None

    def shot(self, tag):
        pass


class SeriesTest(unittest.TestCase):
    def test_converts_rms_to_db_and_milliseconds_to_seconds(self):
        raw = json.dumps([[1000, 0.5, 1.0, ""], [1050, 0.0, 0.1, ""]])
        page = FakePage({"since(": raw})
        series = e2e_audio.AudioProbe(page).series("s1", 900)
        self.assertEqual(len(series), 2)
        self.assertAlmostEqual(series[0][0], 1.0)
        self.assertAlmostEqual(series[0][1], -6.0206, places=3)
        self.assertAlmostEqual(series[0][2], 0.0)
        self.assertAlmostEqual(series[1][1], -120.0)

    def test_the_stream_of_a_track_is_found_by_its_element_id(self):
        listening = json.dumps([
            {"stream": "g1", "element": "livekit_audio_TR_AAA"},
            {"stream": "g2", "element": "livekit_audio_TR_BBB"}])
        probe = e2e_audio.AudioProbe(FakePage({"listen()": listening}))
        self.assertEqual(probe.stream_of_track("TR_BBB"), "g2")
        self.assertIsNone(probe.stream_of_track("TR_ZZZ"))

    def test_an_empty_series_is_an_error_not_a_zero(self):
        with self.assertRaises(AssertionError):
            e2e_audio.level_of([])


class SliderTest(unittest.TestCase):
    """set_slider aims, reads the readout back and corrects."""

    class Slider:
        def __init__(self):
            self.percent = 100
            self.name = "alice"
            self.rect = [100.0, 50.0, 168.0, 32.0]
            self.clicks = []

        def ev(self, script):
            return json.dumps(self.rect)

        def nodes(self):
            return [{"t": f"{self.percent}%", "x": 270, "y": 66, "field": False}]

        def gestures(self, on):
            pass

        def mouse_click(self, x, y):
            self.clicks.append(x)
            x0, _, w, _ = self.rect
            track = w - 2 * ui.SLIDER_INSET
            frac = min(max((x - x0 - ui.SLIDER_INSET) / track, 0), 1)
            self.percent = round(frac * 200 + 3)

        def shot(self, tag):
            pass

    def test_reaches_the_target_by_reading_the_readout_back(self):
        page = self.Slider()
        with patch.object(ui.time, "sleep"):
            shown = ui.set_slider(page, "Volume for you", 50)
        self.assertLessEqual(abs(shown - 50), 4)
        self.assertGreaterEqual(len(page.clicks), 1)

    def test_a_slider_already_there_is_not_touched(self):
        page = self.Slider()
        page.percent = 50
        with patch.object(ui.time, "sleep"):
            ui.set_slider(page, "Volume for you", 50)
        self.assertEqual(page.clicks, [])

    def test_gives_up_loudly_when_the_slider_will_not_move(self):
        page = self.Slider()
        page.mouse_click = lambda x, y: None
        with patch.object(ui.time, "sleep"):
            with self.assertRaises(AssertionError):
                ui.set_slider(page, "Volume for you", 50, tries=2)

    def test_a_missing_slider_is_named_in_the_failure(self):
        page = self.Slider()
        page.ev = lambda script: "null"
        with self.assertRaisesRegex(AssertionError, "no slider named"):
            ui.slider_rect(page, "Volume for you")


class BrowserArgsTest(unittest.TestCase):
    def test_the_extra_browsers_avoid_the_two_the_script_owns(self):
        self.assertFalse({9801, 9802} & set(map(e2e_browsers.extra_port, e2e_browsers.EXTRA_OFFSETS)))
        self.assertEqual(len(set(map(e2e_browsers.extra_port, e2e_browsers.EXTRA_OFFSETS))),
                         len(e2e_browsers.EXTRA_OFFSETS))

    def test_each_browser_captures_the_wav_it_was_given(self):
        args = e2e_browsers.chrome_args("/p", 9811, "/w/noisy.wav")
        self.assertIn("--use-file-for-fake-audio-capture=/w/noisy.wav", args)
        self.assertIn("--remote-debugging-port=9811", args)
        self.assertIn("--user-data-dir=/p", args)


class RegisterTest(unittest.TestCase):
    class Admin:
        def call(self, method, path, body=None):
            return {"code": "invite-1"}

    def _error(self, code):
        import urllib.error
        return urllib.error.HTTPError("u", code, "x", {}, None)

    def test_a_name_already_taken_is_reused(self):
        with patch.object(e2e_browsers, "Api") as api:
            api.return_value.call.side_effect = [self._error(409)]
            self.assertEqual(
                e2e_browsers.register("http://x", self.Admin(), "carol", "pw"),
                "carol")

    def test_any_other_refusal_is_an_error(self):
        with patch.object(e2e_browsers, "Api") as api:
            api.return_value.call.side_effect = [self._error(403)]
            with self.assertRaises(Exception):
                e2e_browsers.register("http://x", self.Admin(), "carol", "pw")

    def test_registering_sends_the_invite_the_admin_issued(self):
        with patch.object(e2e_browsers, "Api") as api:
            e2e_browsers.register("http://x", self.Admin(), "carol", "pw")
        body = api.return_value.call.call_args[0][2]
        self.assertEqual(body["invite_code"], "invite-1")
        self.assertEqual(body["username"], "carol")


class LiveVideoTest(unittest.TestCase):
    SID = "TR_share1"

    def _frames(self, sequence, **extra):
        base = {"index": 0, "width": 640, "height": 360, "mean": 90.0, "spread": 18.0,
                "stream": "u1", "sfu": "PA_x|" + self.SID, "display": False}
        base.update(extra)
        return [dict(base, frames=n) for n in sequence]

    def _live(self, samples):
        """live_videos over successive probe reads, one list per read."""
        reads = iter(json.dumps(v) for v in samples)
        page = FakePage({"videos()": lambda: next(reads)})
        with patch.object(multishare.time, "sleep"):
            return multishare.live_videos(e2e_audio.AudioProbe(page), [self.SID])

    def test_a_video_that_keeps_decoding_is_live(self):
        live = self._live([self._frames([10]), self._frames([40])])
        self.assertEqual(len(live), 1)

    def test_a_frozen_frame_is_not_live(self):
        self.assertEqual(self._live([self._frames([10]), self._frames([10])]), [])

    def test_black_or_undecoded_video_does_not_count(self):
        self.assertEqual(self._live(
            [self._frames([10], mean=0.5), self._frames([40], mean=0.5)]), [])
        self.assertEqual(self._live(
            [self._frames([0], width=0), self._frames([0], width=0)]), [])

    def test_a_flat_bright_fill_is_not_a_picture(self):
        self.assertEqual(self._live(
            [self._frames([10], spread=0.0), self._frames([40], spread=0.0)]), [])

    def test_unrelated_videos_are_ignored(self):
        other = self._frames([10], stream="u2", sfu="PA_y|TR_camera", index=1)
        later = self._frames([40], stream="u2", sfu="PA_y|TR_camera", index=1)
        live = self._live([self._frames([10]) + other,
                           self._frames([40]) + later])
        self.assertEqual([v["stream"] for v in live], ["u1"])

    def test_a_local_capture_counts_as_a_share_tile(self):
        mine = self._frames([5], stream="local", display=True)
        later = self._frames([30], stream="local", display=True)
        self.assertEqual(len(self._live([mine, later])), 1)

    def test_one_stream_rendered_twice_is_refused(self):
        twice = (self._frames([10]) + self._frames([10], index=1))
        later = (self._frames([40]) + self._frames([40], index=1))
        reads = iter([json.dumps(twice), json.dumps(later)] * 4)
        page = FakePage({"videos()": lambda: next(reads)}, name="carol")
        with patch.object(multishare.time, "sleep"):
            with self.assertRaisesRegex(AssertionError, "rendered more than once"):
                multishare.wait_for_videos(
                    e2e_audio.AudioProbe(page), [self.SID], 2, timeout=5)


class BrowserCleanupTest(unittest.TestCase):
    def test_a_browser_that_ignores_sigterm_is_killed(self):
        import signal
        import subprocess
        proc = unittest.mock.MagicMock(pid=123)
        proc.wait.side_effect = [subprocess.TimeoutExpired("chrome", 1), 0]
        with patch.object(e2e_browsers.os, "killpg") as killpg:
            e2e_browsers._stop(proc)
        self.assertEqual([c.args[1] for c in killpg.call_args_list],
                         [signal.SIGTERM, signal.SIGKILL])


class RegistryTest(unittest.TestCase):
    def test_the_voice_measurement_scenarios_are_registered_in_order(self):
        names = [n for n, _ in e2e_run.scenarios(
            None, None, None, None, "room", "http://localhost:0", "secret")]
        text = " | ".join(names)
        for fragment in (
            "noise suppression quiets the noise floor",
            "volume slider scales the sound",
            "picking a microphone mid-call",
            "deafening silences what you hear",
            "muting hands the capture back",
            "share's own volume moves apart",
            "two shares at once reach a third person",
        ):
            self.assertIn(fragment, text)
        dm = next(i for i, n in enumerate(names) if "calling in a dm" in n)
        for fragment in ("noise suppression", "volume slider", "microphone mid-call",
                         "deafening", "share's own volume", "two shares at once"):
            at = next(i for i, n in enumerate(names) if fragment in n)
            self.assertLess(at, dm, f"{fragment!r} must run before the dm call")


if __name__ == "__main__":
    unittest.main()
