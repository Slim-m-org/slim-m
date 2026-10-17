# SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
"""The owner helper against a throwaway local HTTP server, plus its refusals."""
import json
import sys
import tempfile
import threading
import unittest
from http.server import BaseHTTPRequestHandler, HTTPServer
from pathlib import Path
from unittest import mock

sys.path.insert(0, str(Path(__file__).resolve().parent))

import load_admin  # noqa: E402


class Handler(BaseHTTPRequestHandler):
    seen = []

    def log_message(self, *_args):
        pass

    def _reply(self, body):
        self.send_response(200)
        self.end_headers()
        self.wfile.write(body)

    def do_POST(self):
        length = int(self.headers.get("Content-Length", 0))
        Handler.seen.append((self.path, json.loads(self.rfile.read(length))))
        self._reply(json.dumps({"access_token": "tok"}).encode())

    def do_GET(self):
        Handler.seen.append((self.path, self.headers.get("Authorization")))
        self._reply(b"slimm_up 1\n")


class AdminTest(unittest.TestCase):
    def setUp(self):
        Handler.seen = []
        self.server = HTTPServer(("127.0.0.1", 0), Handler)
        threading.Thread(target=self.server.serve_forever, daemon=True).start()
        self.base = f"http://127.0.0.1:{self.server.server_port}"

    def tearDown(self):
        self.server.shutdown()
        self.server.server_close()

    def test_claim_registers_the_owner_and_returns_its_token(self):
        self.assertEqual(load_admin.claim(self.base, "pw"), "tok")
        path, body = Handler.seen[0]
        self.assertEqual((path, body["username"]), ("/auth/register", "loadadmin"))

    def test_metrics_signs_in_and_saves_the_body(self):
        with tempfile.TemporaryDirectory() as tmp:
            out = Path(tmp) / "m.txt"
            load_admin.metrics(self.base, "pw", out)
            self.assertEqual(out.read_text(), "slimm_up 1\n")
        self.assertEqual(Handler.seen[-1], ("/metrics", "Bearer tok"))


class RefusalTest(unittest.TestCase):
    def test_a_non_local_target_is_refused_before_any_request(self):
        with mock.patch.object(load_admin, "_call") as call:
            for url in ("https://slim.npc-server.top", "http://10.0.0.100:8095",
                        "http://192.168.1.9:8195"):
                code = load_admin.main(["x", "claim", url], {"LOAD_ADMIN_PASSWORD": "p"})
                self.assertEqual(code, 1, url)
            call.assert_not_called()


if __name__ == "__main__":
    unittest.main()
