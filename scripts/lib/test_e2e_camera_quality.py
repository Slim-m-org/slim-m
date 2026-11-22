# SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
import unittest

import e2e_camera_quality as cq


def out(ssrc, rid, height, frames):
    return {"ssrc": ssrc, "rid": rid, "frameWidth": height * 16 // 9, "frameHeight": height,
            "framesEncoded": frames}


def inbound(ssrc, decoded, freezes=0):
    return {"ssrc": ssrc, "framesDecoded": decoded, "freezeCount": freezes}


def window(heights, fps=30, seconds=10, viewer=None, freezes=0):
    """Samples one second apart from layers that each encode `fps` frames a second."""
    rows = []
    for t in range(seconds + 1):
        layers = [out(i + 1, "qhf"[i], h, t * fps) for i, h in enumerate(heights)]
        rows.append({"t": float(t), "out": layers,
                     "in": [inbound(9, int(t * (viewer if viewer is not None else fps)), freezes * t)]})
    return rows


class LayersTest(unittest.TestCase):
    def test_every_encoding_layer_is_counted_smallest_first(self):
        self.assertEqual([h for _, _, h in cq.live_layers(window([360, 180, 720]))], [180, 360, 720])

    def test_a_layer_that_stopped_encoding_is_not_live(self):
        samples = window([180, 360, 720])
        for s in samples:
            s["out"].append(out(7, "f", 1080, 500))
        self.assertEqual([h for _, _, h in cq.live_layers(samples)], [180, 360, 720])


class RatesTest(unittest.TestCase):
    def test_the_top_layer_rate_is_frames_over_the_window(self):
        self.assertEqual(cq.top_layer_fps(window([180, 720], fps=30)), 30.0)

    def test_viewer_rate_and_freezes_are_deltas(self):
        samples = window([180, 360], viewer=24, freezes=1)
        self.assertEqual(cq.viewer_fps(samples), 24.0)
        self.assertEqual(cq.viewer_freezes(samples), 10)


class ProblemsTest(unittest.TestCase):
    def test_a_healthy_720p_camera_has_none(self):
        self.assertEqual(cq.problems("720p", window([180, 360, 720])), [])

    def test_a_healthy_360p_camera_has_two_layers(self):
        self.assertEqual(cq.problems("360p", window([180, 360], fps=20)), [])

    def test_360p_is_held_to_its_own_lower_frame_rate_floor(self):
        self.assertTrue(any("encoded" in p for p in cq.problems("360p", window([180, 360], fps=15))))

    def test_a_quality_that_never_applied_keeps_the_old_layers(self):
        found = cq.problems("360p", window([180, 360, 720]))
        self.assertEqual(len(found), 1)
        self.assertIn("layers [180, 360, 720], expected [180, 360]", found[0])

    def test_a_slow_sender_or_viewer_is_named(self):
        self.assertTrue(any("encoded" in p for p in cq.problems("720p", window([180, 360, 720], fps=20))))
        self.assertTrue(any("decoded" in p for p in cq.problems("720p", window([180, 360, 720], viewer=10))))

    def test_a_freeze_fails(self):
        self.assertTrue(any("froze" in p for p in cq.problems("720p", window([180, 360, 720], freezes=1))))


class RestartTest(unittest.TestCase):
    def stalled_stream(self):
        """Frames flow, stop for 3 s (the republish) and resume on a new ssrc with the new size."""
        rows = []
        for t in range(12):
            decoded = t * 30 if t < 4 else 4 * 30
            old = [inbound(9, decoded)]
            new = [inbound(10, (t - 7) * 30)] if t >= 8 else []
            top = out(2, "f", 720, 0) if t < 8 else out(5, "f", 360, (t - 8) * 30)
            rows.append({"t": float(t), "out": [top], "in": old + new})
        return rows

    def test_the_gap_is_the_longest_stretch_with_no_new_frame(self):
        self.assertEqual(cq.restart_gap(self.stalled_stream()), 4.0)

    def test_an_unbroken_stream_has_a_step_sized_gap(self):
        self.assertEqual(cq.restart_gap(window([180], seconds=5)), 1.0)

    def test_the_change_is_applied_once_only_the_new_layers_encode(self):
        rows = []
        for t in range(12):
            old = [out(1, "f", 720, min(t, 3) * 30), out(2, "h", 360, t * 30)]
            new = [out(3, "q", 180, (t - 7) * 30), out(4, "h", 360, (t - 7) * 30)]
            rows.append({"t": float(t), "out": old if t < 8 else old[:1] + new, "in": []})
        self.assertEqual(cq.applied_after(rows, [180, 360]), 11.0)

    def test_layers_that_never_match_are_none(self):
        self.assertIsNone(cq.applied_after(window([180, 360, 720]), [180, 360]))


if __name__ == "__main__":
    unittest.main()
