# SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
"""A stand-in for the canvas routes the seeder drives, for tests only.

Models what the server does that the seeder depends on: a per-channel op
stream with a monotonic seq, ops pages clamped to 200 with `has_more`, and a
`reset` with no ops when the cursor is more than 2000 behind (CANVAS_OP_GAP in
crates/slimm-server/src/store/canvas_ops.rs).
"""
import io
import urllib.error
import urllib.parse

PAGE_MAX = 200
OP_GAP = 2000


def _forbidden():
    return urllib.error.HTTPError("http://fake", 403, "forbidden", {}, io.BytesIO(b""))


class FakeCanvasServer:
    def __init__(self, can_clear=True):
        self.can_clear = can_clear
        self.ops = []
        self.objects = {}

    def user(self, name):
        return _User(self, name)

    def _append(self, kind, **fields):
        op = {"seq": len(self.ops) + 1, "id": f"op{len(self.ops) + 1}",
              "kind": kind, **fields}
        self.ops.append(op)
        return op

    def live(self):
        return [o for o in self.objects.values() if not o["deleted"]]

    def ops_page(self, after_seq, limit):
        latest = len(self.ops)
        limit = min(limit or PAGE_MAX, PAGE_MAX)
        if after_seq > latest or latest - after_seq > OP_GAP:
            return {"ops": [], "latest_seq": latest, "has_more": False,
                    "reset": True}
        rest = [o for o in self.ops if o["seq"] > after_seq]
        return {"ops": rest[:limit], "latest_seq": latest,
                "has_more": len(rest) > limit, "reset": False}


class _User:
    def __init__(self, server, name):
        self.server, self.name, self.token = server, name, name

    def call(self, method, path, body=None, raw=None, content_type=None):
        parsed = urllib.parse.urlparse(path)
        route = parsed.path.rsplit("/canvas/", 1)[1]
        server = self.server
        if method == "GET" and route == "ops":
            query = urllib.parse.parse_qs(parsed.query)
            return server.ops_page(int(query["after_seq"][0]),
                                   int(query.get("limit", [0])[0]))
        if method == "POST" and route == "objects":
            op = server._append("place", actor=self.name)
            server.objects[body["id"]] = {
                "id": body["id"], "author": self.name, "deleted": False,
                "seq": op["seq"]}
            return {"id": body["id"], "seq": op["seq"], "x": 0, "y": 0}
        if method == "POST" and route == "ops":
            return self._submit(body)
        raise AssertionError(f"unmodelled request {method} {path}")

    def _submit(self, body):
        server = self.server
        kind = body["kind"]
        if kind == "clear":
            if not server.can_clear:
                raise _forbidden()
            for obj in server.objects.values():
                obj["deleted"] = True
            op = server._append("clear", actor=self.name)
            return {"op": {**op, "affected": len(server.objects)}}
        if kind == "remove":
            for oid in body["object_ids"]:
                if server.objects[oid]["author"] != self.name:
                    raise _forbidden()
            for oid in body["object_ids"]:
                server.objects[oid]["deleted"] = True
            op = server._append("remove", actor=self.name)
            return {"op": {**op, "affected": len(body["object_ids"])}}
        if kind == "restore":
            for obj in server.objects.values():
                obj["deleted"] = False
            op = server._append("restore", actor=self.name)
            return {"op": {**op, "affected": len(server.objects)}}
        op = server._append(kind, actor=self.name)
        return {"op": {**op, "affected": 1}}
