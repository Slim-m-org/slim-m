# SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
"""seed_canvas_probes records what the server answered, ok or UNEXPECTED."""
import io
import json
import sys
import unittest
import warnings
import urllib.error
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))

import seed_canvas_probes as probes  # noqa: E402


# HTTPError wraps its body in a tempfile wrapper that warns when collected.
warnings.filterwarnings("ignore", category=ResourceWarning)


def fail(code):
    return urllib.error.HTTPError("http://fake", code, "x", {},
                                  io.BytesIO(b"detail"))


class Server:
    """Answers the way the canvas routes document, member or admin."""

    def __init__(self, member=False, lenient_body=False):
        self.member = member
        self.lenient_body = lenient_body
        self.placed = {"id": "s1", "kind": "stroke", "x": 0, "y": 0, "w": 5,
                       "h": 5, "props": {"points": [0, 0, 1, 1]}, "seq": 1}

    def call(self, method, path, body=None, **_):
        if path.endswith("/canvas/objects") and method == "POST":
            return self._place(body)
        if path.endswith("/canvas/ops") and method == "POST":
            return self._op(body)
        if "/canvas/ops?" in path:
            return {"ops": [{"seq": 1, "id": "p1", "kind": "place"}],
                    "latest_seq": 1, "has_more": False}
        raise AssertionError(path)

    def _place(self, body):
        if body["id"] == self.placed["id"]:
            return self.placed
        if len(json.dumps(body)) > 8192 and not self.lenient_body:
            raise fail(413)
        if len(json.dumps(body["props"])) > 4096 or body["w"] > 10000:
            raise fail(400)
        return {**body, "seq": 2}

    def _op(self, body):
        kind = body["kind"]
        if kind == "clear" and self.member:
            raise fail(403)
        if kind == "move":
            raise fail(404)
        if kind == "remove" and not body["object_ids"]:
            raise fail(400)
        if kind == "restore":
            raise fail(404)
        return {"op": {"id": "o", "affected": 1}}


class RunTest(unittest.TestCase):
    def test_a_server_behaving_as_documented_gives_all_ok(self):
        findings = probes.run(Server(), Server(member=True), "c",
                              Server().placed)
        self.assertEqual(len(findings), 8)
        bad = [f for f in findings if not f["ok"]]
        self.assertEqual(bad, [])

    def test_an_unexpected_answer_is_a_finding_not_an_exception(self):
        findings = probes.run(Server(lenient_body=True), None, "c",
                              Server().placed)
        by_name = {f["name"]: f for f in findings}
        body = by_name["place with a request body over MAX_BODY_BYTES"]
        self.assertFalse(body["ok"])
        self.assertEqual((body["expected"], body["actual"]), (413, 400))
        self.assertEqual(len(findings), 7)

    def test_a_member_who_can_clear_is_flagged(self):
        findings = probes.run(Server(), Server(), "c", Server().placed)
        clear = [f for f in findings if f["name"] == "clear without MANAGE_CANVAS"]
        self.assertEqual([f["ok"] for f in clear], [False])

    def test_a_replay_that_returns_a_new_seq_is_flagged(self):
        placed = {**Server().placed, "seq": 99}
        replay = probes._replay_shows_no_fresh_flag(Server(), "c", placed)
        self.assertFalse(replay["ok"])


class StatusTest(unittest.TestCase):
    def test_success_has_no_status_and_returns_the_body(self):
        self.assertEqual(probes._status(lambda: {"a": 1}), (None, {"a": 1}))

    def test_an_http_error_gives_its_code_and_a_body_excerpt(self):
        def boom():
            raise fail(418)
        self.assertEqual(probes._status(boom), (418, "detail"))


if __name__ == "__main__":
    unittest.main()
