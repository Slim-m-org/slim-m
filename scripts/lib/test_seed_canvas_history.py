# SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
"""seed_canvas_history against a stand-in that enforces object ownership."""
import random
import sys
import unittest
import warnings
import urllib.error
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))

import seed_canvas_history as history  # noqa: E402
import seed_canvas_geometry as geom  # noqa: E402
import seed_canvas_ops as ops  # noqa: E402
import uuid7  # noqa: E402
from fake_canvas_server import FakeCanvasServer  # noqa: E402


# HTTPError wraps its body in a tempfile wrapper that warns when collected.
warnings.filterwarnings("ignore", category=ResourceWarning)


def stroke_placer(api, channel_id="c"):
    rng = random.Random(1)

    def place():
        points = geom.freehand_stroke(rng, (50, 50), steps=12)
        placement = geom.stroke_placements(
            points, 2.0, "annotation", uuid7.uuid7)[0]
        return ops.place_object(api, channel_id, placement)

    return place


class _AuthorOnlyApi:
    def __init__(self, name):
        self.name = name


class BatchRemoveTest(unittest.TestCase):
    def _run(self, candidates, limit=None):
        sent = []
        stats = {"forbidden": 0, "removed": 0, "restored": 0}
        apis = {i: _AuthorOnlyApi(i) for i in {c["author_index"] for c in candidates}}
        owner = {c["id"]: c["author_index"] for c in candidates}

        def fake_remove(api, channel_id, op_id, ids):
            sent.append((api.name, list(ids)))
            if any(owner[i] != api.name for i in ids):
                raise urllib.error.HTTPError("http://x", 403, "no", {}, None)
            return {"op": {"id": str(op_id), "affected": len(ids)}}

        def fake_restore(api, channel_id, op_id, target):
            return {"op": {"id": "r", "affected": 1}}

        orig = (ops.remove, ops.restore)
        ops.remove, ops.restore = fake_remove, fake_restore
        try:
            history._run_removes_and_restores(
                apis, None, "c", candidates, stats)
        finally:
            ops.remove, ops.restore = orig
        return stats, sent

    def test_a_batch_of_several_authors_is_sent_one_remove_per_author(self):
        candidates = [{"id": f"o{i}", "author_index": i % 2} for i in range(12)]
        stats, sent = self._run(candidates)
        self.assertEqual(stats["forbidden"], 0)
        self.assertTrue(any(len(ids) > 1 for _, ids in sent))

    def test_a_batch_over_the_server_limit_is_chunked(self):
        candidates = [{"id": f"o{i}", "author_index": 0} for i in range(300)]
        stats, sent = self._run(candidates)
        self.assertEqual(stats["forbidden"], 0)
        self.assertLessEqual(max(len(ids) for _, ids in sent), 64)


class ThrowawayBatchTest(unittest.TestCase):
    def test_a_full_batch_leaves_no_placeholder_art(self):
        server = FakeCanvasServer()
        admin = server.user("admin")

        got = history.run_throwaway_batch(admin, "c", 8, stroke_placer(admin))

        self.assertEqual(got["placed"], 8)
        kinds = {k: server.ops[got[k]["seq"] - 1]["kind"]
                 for k in ("clear", "restore", "remove")}
        self.assertEqual(kinds, {"clear": "clear", "restore": "restore",
                                 "remove": "remove"})
        self.assertEqual(server.live(), [])
        self.assertEqual(
            [o["kind"] for o in server.ops if o["kind"] != "place"],
            ["clear", "restore", "remove"])

    def test_a_refused_clear_removes_the_strokes_it_placed(self):
        server = FakeCanvasServer(can_clear=False)
        admin = server.user("admin")

        placer = stroke_placer(admin)
        with self.assertRaises(urllib.error.HTTPError) as caught:
            history.run_throwaway_batch(admin, "c", 8, placer)

        self.assertEqual(caught.exception.code, 403)
        self.assertEqual(server.live(), [])


if __name__ == "__main__":
    unittest.main()
