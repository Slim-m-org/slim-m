# SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
"""seed_canvas_history against a stand-in that enforces object ownership."""
import random
import sys
import unittest
import urllib.error
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))

import seed_canvas_history as history  # noqa: E402
import seed_canvas_geometry as geom  # noqa: E402
import seed_canvas_ops as ops  # noqa: E402
import uuid7  # noqa: E402
from fake_canvas_server import FakeCanvasServer  # noqa: E402


def stroke_placer(api, channel_id="c"):
    rng = random.Random(1)

    def place():
        points = geom.freehand_stroke(rng, (50, 50), steps=12)
        placement = geom.stroke_placements(
            points, 2.0, "annotation", uuid7.uuid7)[0]
        return ops.place_object(api, channel_id, placement)

    return place


class ThrowawayBatchTest(unittest.TestCase):
    def test_a_full_batch_leaves_no_placeholder_art(self):
        server = FakeCanvasServer()
        admin = server.user("admin")

        got = history.run_throwaway_batch(admin, "c", 8, stroke_placer(admin))

        self.assertEqual(got["placed"], 8)
        self.assertEqual(server.live(), [])
        self.assertEqual(
            [o["kind"] for o in server.ops if o["kind"] != "place"],
            ["clear", "restore", "remove"])

    def test_a_refused_clear_removes_the_strokes_it_placed(self):
        server = FakeCanvasServer(can_clear=False)
        admin = server.user("admin")

        with self.assertRaises(urllib.error.HTTPError) as caught:
            history.run_throwaway_batch(admin, "c", 8, stroke_placer(admin))

        self.assertEqual(caught.exception.code, 403)
        self.assertEqual(server.live(), [])


if __name__ == "__main__":
    unittest.main()
