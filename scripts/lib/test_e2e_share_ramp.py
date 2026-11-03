# SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
import unittest

import e2e_share_ramp as ramp


class FirstFullSecondTest(unittest.TestCase):
    def test_the_first_sample_at_full_height_wins(self):
        self.assertEqual(ramp.first_full_second([0, 540, 540, 1080, 1080]), 3)

    def test_a_viewer_that_never_gets_there_reports_none(self):
        self.assertIsNone(ramp.first_full_second([0, 540, 540]))

    def test_no_samples_report_none(self):
        self.assertIsNone(ramp.first_full_second([]))


class SummaryTest(unittest.TestCase):
    def test_target_bitrate_sums_the_layers_in_mbps(self):
        layers = [{"targetBitrate": 500_000}, {"targetBitrate": 2_500_000}, {}]
        self.assertEqual(ramp.summed_target_mbps(layers), 3.0)

    def test_the_viewer_height_is_the_tallest_frame_seen(self):
        self.assertEqual(ramp.viewer_height([{"frameHeight": 540}, {"frameHeight": 1080}]), 1080)
        self.assertEqual(ramp.viewer_height([]), 0)


if __name__ == "__main__":
    unittest.main()
