# SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
import unittest

import e2e_voice_encode as enc


class ParseCaseTest(unittest.TestCase):
    def test_a_share_names_its_screen_and_tier(self):
        case = enc.parse_case("share:3840x2160:1080p30")
        self.assertEqual(case["size"], (3840, 2160))
        self.assertEqual(case["flag"], "--voice-harness-share=1080p30")
        self.assertEqual(case["source"], "screenShare")

    def test_a_camera_names_its_quality(self):
        case = enc.parse_case("camera:high")
        self.assertEqual(case["flag"], "--voice-harness-camera=high")
        self.assertEqual(case["source"], "camera")


class LayersTest(unittest.TestCase):
    def test_the_last_reading_of_each_layer_wins_and_other_sources_are_ignored(self):
        lines = [
            "SLIMM_HARNESS encode source=screenShare rid=q w=960 h=540 fps=20.0 bps=1 target=2 limit=none",
            "SLIMM_HARNESS encode source=screenShare rid=q w=1920 h=1080 fps=24.0 bps=3 target=2 limit=cpu",
            "SLIMM_HARNESS encode source=camera rid=f w=1280 h=720 fps=30.0 bps=4 target=2 limit=none",
            "SLIMM_HARNESS call state=connected",
        ]
        got = enc.layers(lines, "screenShare")
        self.assertEqual([(g["rid"], g["width"], g["height"], g["limit"]) for g in got],
                         [("q", "1920", "1080", "cpu")])


if __name__ == "__main__":
    unittest.main()
