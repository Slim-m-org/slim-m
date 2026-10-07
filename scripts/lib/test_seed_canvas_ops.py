# SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
"""The canvas verbs send the request shapes the server documents."""
import sys
import unittest
from pathlib import Path
from urllib.parse import parse_qs, urlparse

sys.path.insert(0, str(Path(__file__).resolve().parent))

import seed_canvas_ops as ops  # noqa: E402


class Recorder:
    def __init__(self):
        self.calls = []

    def call(self, method, path, body=None, raw=None, content_type=None):
        self.calls.append((method, path, body, raw, content_type))
        return {"ok": True}


class VerbTest(unittest.TestCase):
    def setUp(self):
        self.api = Recorder()

    def sent(self):
        return self.api.calls[-1]

    def test_op_verbs_post_to_the_ops_route(self):
        cases = [
            (lambda: ops.remove(self.api, "c", "i", ["a", "b"]),
             {"id": "i", "kind": "remove", "object_ids": ["a", "b"]}),
            (lambda: ops.clear(self.api, "c", "i", 9),
             {"id": "i", "kind": "clear", "before_seq": 9}),
            (lambda: ops.restore(self.api, "c", "i", "t"),
             {"id": "i", "kind": "restore", "target_op": "t"}),
            (lambda: ops.move(self.api, "c", "i", "o", 1, 2, 3, 4),
             {"id": "i", "kind": "move", "object_id": "o",
              "x": 1, "y": 2, "w": 3, "h": 4}),
            (lambda: ops.reorder(self.api, "c", "i", "o", -5),
             {"id": "i", "kind": "reorder", "object_id": "o", "z_index": -5}),
        ]
        for send, want in cases:
            with self.subTest(kind=want["kind"]):
                send()
                method, path, body, _, _ = self.sent()
                self.assertEqual((method, path), ("POST", "/channels/c/canvas/ops"))
                self.assertEqual(body, want)

    def test_place_object_posts_the_placement_as_is(self):
        ops.place_object(self.api, "c", {"id": "p"})
        self.assertEqual(self.sent()[:3],
                         ("POST", "/channels/c/canvas/objects", {"id": "p"}))

    def test_viewport_sends_the_rect_and_an_optional_limit(self):
        ops.viewport(self.api, "c", (-1, -2, 3, 4), limit=2000)
        url = urlparse(self.sent()[1])
        self.assertEqual(url.path, "/channels/c/canvas/objects")
        self.assertEqual(
            {k: v[0] for k, v in parse_qs(url.query).items()},
            {"min_x": "-1", "min_y": "-2", "max_x": "3", "max_y": "4",
             "limit": "2000"})
        ops.viewport(self.api, "c", (0, 0, 1, 1))
        self.assertNotIn("limit", self.sent()[1])

    def test_ops_page_sends_the_cursor(self):
        ops.ops_page(self.api, "c", after_seq=7, limit=200)
        url = urlparse(self.sent()[1])
        self.assertEqual(url.path, "/channels/c/canvas/ops")
        self.assertEqual(parse_qs(url.query),
                         {"after_seq": ["7"], "limit": ["200"]})

    def test_upload_quotes_the_filename_and_sends_raw_bytes(self):
        ops.upload_attachment(self.api, "a b&c.png", b"\x89PNG", "image/png")
        method, path, body, raw, ctype = self.sent()
        self.assertEqual((method, path), ("POST", "/attachments?filename=a%20b%26c.png"))
        self.assertEqual((raw, ctype, body), (b"\x89PNG", "image/png", None))


if __name__ == "__main__":
    unittest.main()
