# SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
import json
import os
import tempfile
import unittest

import voice_tripwire as tw

BANDS = {"provisional": False, "mos_band": 0.3, "delay_band_ms": 30,
         "profiles": {"clean": {"visqol": 4.4, "jitter_buffer_delay_ms": 40},
                      "loss5-jitter30": {"visqol": 4.38, "jitter_buffer_delay_ms": 60}}}


def side(visqol, delay):
    return {"mos": {"visqol": visqol}, "stats": {"jitterBufferDelayMs": delay}}


def run(clean, lossy):
    return {"clean": {"vqa": side(clean, 40), "vqb": side(clean, 40)},
            "loss5-jitter30": {"vqa": side(lossy, 60), "vqb": side(lossy, 60)}}


class Aggregate(unittest.TestCase):
    def test_the_median_ignores_one_outlying_run(self):
        got = tw.aggregate([run(4.4, 4.38), run(4.41, 4.37), run(2.0, 1.0)])
        self.assertEqual(got["clean"]["visqol"], 4.4)
        self.assertEqual(got["loss5-jitter30"]["visqol"], 4.37)

    def test_an_unscored_side_is_left_out_and_an_all_unscored_profile_is_none(self):
        got = tw.aggregate([{"clean": {"vqa": {"stats": {}}, "vqb": side(4.2, 30)}}])
        self.assertEqual(got["clean"], {"visqol": 4.2, "jitter_buffer_delay_ms": 30})
        self.assertIsNone(tw.aggregate([{"clean": {"vqa": {}}}])["clean"]["visqol"])


class Check(unittest.TestCase):
    def test_values_inside_the_bands_pass(self):
        self.assertEqual(tw.check(tw.aggregate([run(4.15, 4.2)]), BANDS), [])

    def test_a_mos_more_than_the_band_below_fails_and_exactly_at_it_does_not(self):
        self.assertEqual(tw.check(tw.aggregate([run(4.1, 4.38)]), BANDS), [])
        problems = tw.check(tw.aggregate([run(4.0, 4.38)]), BANDS)
        self.assertEqual(len(problems), 1)
        self.assertIn("clean: ViSQOL 4.0", problems[0])

    def test_a_better_than_baseline_run_never_fails(self):
        self.assertEqual(tw.check(tw.aggregate([run(4.9, 4.9)]), BANDS), [])

    def test_a_delay_over_the_band_fails(self):
        runs = run(4.4, 4.38)
        runs["clean"]["vqa"]["stats"]["jitterBufferDelayMs"] = 100
        runs["clean"]["vqb"]["stats"]["jitterBufferDelayMs"] = 100
        self.assertIn("jitter buffer delay 100", tw.check(tw.aggregate([runs]), BANDS)[0])

    def test_a_missing_profile_or_score_fails_loudly(self):
        self.assertEqual(tw.check({}, BANDS), ["clean: no recording was scored",
                                               "loss5-jitter30: no recording was scored"])
        measured = tw.aggregate([run(4.4, 4.38)])
        measured["clean"]["visqol"] = None
        self.assertEqual(tw.check(measured, BANDS), ["clean: no ViSQOL score"])

    def test_a_dtx_like_collapse_in_the_lossy_profile_is_caught(self):
        problems = tw.check(tw.aggregate([run(4.4, 3.2), run(4.4, 3.3), run(4.4, 3.1)]), BANDS)
        self.assertEqual(len(problems), 1)
        self.assertTrue(problems[0].startswith("loss5-jitter30"))


class Versions(unittest.TestCase):
    def test_chrome_and_livekit_versions_parse_from_their_banners(self):
        self.assertEqual(tw.parse_chrome_version("Google Chrome 158.0.8127.36 \n"), "158.0.8127.36")
        self.assertEqual(tw.parse_livekit_version("livekit-server version 1.13.11\n"), "1.13.11")
        self.assertIsNone(tw.parse_chrome_version("chromium"))
        self.assertIsNone(tw.parse_livekit_version(None))


class Main(unittest.TestCase):
    def _dirs(self, root, runs):
        dirs = []
        for i, results in enumerate(runs):
            path = os.path.join(root, f"baseline{i}")
            os.makedirs(path)
            with open(os.path.join(path, "results.json"), "w") as fh:
                json.dump(results, fh)
            dirs.append(path)
        return dirs

    def _bands(self, root, provisional):
        path = os.path.join(root, "bands.json")
        with open(path, "w") as fh:
            json.dump({**BANDS, "provisional": provisional}, fh)
        return path

    def test_exit_status_follows_the_bands_unless_they_are_provisional(self):
        with tempfile.TemporaryDirectory() as root:
            dirs = self._dirs(root, [run(3.0, 3.0)] * 3)
            out = os.path.join(root, "summary.md")
            args = ["check", *dirs, "--summary", out, "--chrome", "Google Chrome 158.0.1"]
            self.assertEqual(tw.main([*args, "--bands", self._bands(root, False)]), 1)
            self.assertEqual(tw.main([*args, "--bands", self._bands(root, True)]), 0)
            with open(out) as fh:
                self.assertIn("Chrome 158.0.1", fh.read())


if __name__ == "__main__":
    unittest.main()
