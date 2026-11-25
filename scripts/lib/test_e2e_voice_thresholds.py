# SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
import unittest

import e2e_voice_encode as enc
import e2e_voice_thresholds as t


def noise(change, speech=0.5):
    return {"hum_floor": {"change_db": change}, "speech_level_change_db": speech}


class TileTest(unittest.TestCase):
    def test_a_call_tile_matches_but_a_member_row_does_not(self):
        self.assertEqual(t.tile_line(["Alice, online", "Bob, microphone on"], "Bob"), "Bob, microphone on")
        self.assertIsNone(t.tile_line(["Bob, online\nBob"], "Bob"))

    def test_a_tile_inside_a_multi_line_node_is_found(self):
        self.assertEqual(t.tile_line(["Mute\nBob, muted"], "Bob"), "Bob, muted")


class NoiseTest(unittest.TestCase):
    def test_a_quieter_floor_with_intact_speech_passes(self):
        self.assertEqual(t.noise_problems("standard", "clean", noise(-18.3, 1.3)), [])

    def test_a_floor_that_barely_moved_fails(self):
        self.assertTrue(t.noise_problems("strong", "clean", noise(-2.0)))

    def test_a_missing_floor_fails(self):
        self.assertTrue(t.noise_problems("strong", "clean", noise(None)))

    def test_speech_eaten_fails(self):
        self.assertTrue(t.noise_problems("strong", "clean", noise(-60.0, -4.5)))

    def test_strong_has_to_beat_standard(self):
        self.assertEqual(t.strong_problems("clean", noise(-18.0), noise(-66.0)), [])
        self.assertTrue(t.strong_problems("clean", noise(-18.0), noise(-20.0)))

    def test_a_run_is_judged_per_arm_and_profile_and_skips_the_gate_log(self):
        rows = {"standard-gate-off": {"clean": {"noise": noise(-18.0)}, "gate_log": "x"},
                "strong-gate-off": {"clean": {"noise": noise(-3.0)}, "gate_log": "x"}}
        found = t.arm_problems(rows)
        self.assertEqual(len(found), 2, found)


def case(label):
    return enc.parse_case(label)


def result(label, top, fps="30.0", restarted=False):
    return {"case": label, "layers": [{"rid": "f", "width": str(top[0]), "height": str(top[1]), "fps": fps,
                                       "bps": "1", "limit": "none"}], "restarted": restarted}


class EncodeTest(unittest.TestCase):
    def test_expected_top_fits_the_source_into_the_tier(self):
        self.assertEqual(t.expected_top(case("share:1920x1080:1080p30")), (1920, 1080))
        self.assertEqual(t.expected_top(case("share:3840x2160:1080p30")), (1920, 1080))
        self.assertEqual(t.expected_top(case("share:3440x1440:1080p30")), (1920, 804))
        self.assertEqual(t.expected_top(case("share:2560x1600:1440p30")), (2304, 1440))
        self.assertEqual(t.expected_top(case("camera:balanced")), (1280, 720))

    def test_a_matching_encode_passes(self):
        c = case("share:3840x2160:1080p30")
        self.assertEqual(t.encode_problems(c, result(c["label"], (1920, 1080), "20.0")), [])

    def test_a_share_encoded_at_the_source_size_fails(self):
        c = case("share:3840x2160:1080p30")
        self.assertTrue(t.encode_problems(c, result(c["label"], (3840, 2160))))

    def test_a_share_at_540p_fails(self):
        c = case("share:1920x1080:1080p30")
        self.assertTrue(t.encode_problems(c, result(c["label"], (960, 540))))

    def test_a_slideshow_share_fails(self):
        c = case("share:1920x1080:1080p30")
        self.assertTrue(t.encode_problems(c, result(c["label"], (1920, 1080), "4.0")))

    def test_a_restart_that_never_came_back_fails(self):
        c = case("share:1920x1080:1080p30:restart")
        self.assertTrue(t.encode_problems(c, result(c["label"], (1920, 1080), restarted=False)))
        self.assertEqual(t.encode_problems(c, result(c["label"], (1920, 1080), restarted=True)), [])

    def test_a_case_without_stats_fails(self):
        c = case("camera:high")
        self.assertTrue(t.encode_problems(c, {"layers": [], "restarted": False}))

    def test_the_camera_top_layer_is_the_tallest(self):
        c = case("camera:high")
        layers = [{"rid": "q", "width": "320", "height": "180", "fps": "30", "bps": "1", "limit": "none"},
                  {"rid": "f", "width": "1920", "height": "1080", "fps": "30", "bps": "1", "limit": "none"}]
        self.assertEqual(t.encode_problems(c, {"layers": layers, "restarted": False}), [])


def report(similarity, lost=0.0):
    return {"similarity": similarity, "timing": {"lost_s": lost}}


class QualityTest(unittest.TestCase):
    def test_the_measured_baseline_passes(self):
        results = {"clean": {"vqa": report(0.993), "vqb": report(0.995)},
                   "burst": {"vqa": report(0.972), "vqb": report(0.982)},
                   "loss5-jitter30": {"vqa": report(0.995, 0.0), "vqb": report(0.994)}}
        self.assertEqual(t.quality_problems(results), [])

    def test_a_degraded_lossy_profile_fails_though_clean_is_fine(self):
        results = {"clean": {"vqa": report(0.99)}, "loss5-jitter30": {"vqa": report(0.7)}}
        self.assertEqual(len(t.quality_problems(results)), 1)

    def test_lost_seconds_over_the_ceiling_fail(self):
        self.assertEqual(len(t.quality_problems({"burst": {"vqb": report(0.98, 4.0)}})), 1)

    def test_an_unlisted_profile_gets_the_looser_floor(self):
        self.assertEqual(t.quality_problems({"wan70": {"vqa": report(0.85)}}), [])
        self.assertTrue(t.quality_problems({"wan70": {"vqa": report(0.5)}}))


class CorpusTest(unittest.TestCase):
    def test_a_scored_corpus_passes(self):
        scores = {"clean": {"vqa": {}, "vqb": {}}}
        self.assertEqual(t.corpus_problems(scores, ["clean"]), [])

    def test_an_empty_scorer_output_fails(self):
        self.assertTrue(t.corpus_problems({}, ["clean"]))

    def test_a_profile_scored_one_way_fails(self):
        self.assertTrue(t.corpus_problems({"clean": {"vqa": {}}}, ["clean"]))


class GrowingTest(unittest.TestCase):
    def test_only_streams_that_gained_frames_count(self):
        self.assertEqual(t.growing_streams({"a": 10, "b": 10}, {"a": 40, "b": 12}), ["a"])

    def test_an_empty_sample_grows_nothing(self):
        self.assertEqual(t.growing_streams({}, {}), [])


if __name__ == "__main__":
    unittest.main()
