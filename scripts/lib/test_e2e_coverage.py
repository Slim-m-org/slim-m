# SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
"""The "N/M documented API paths touched" number has to keep meaning that."""
import contextlib
import io
import sys
import tempfile
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))

import e2e_coverage as C  # noqa: E402

OPENAPI = Path(__file__).resolve().parents[2] / "schema" / "openapi.yaml"
UUID = "0190c1a2-7b3c-7d4e-8f50-123456789abc"

SCHEMA = """openapi: 3.0.0
paths:
  /healthz:
    get: {}
  /channels/{channel_id}/messages:
    get: {}
  /invites/{code}/redeem:
    post: {}
components:
  schemas:
    /not-a-path:
      type: object
"""


class CanonTest(unittest.TestCase):
    def test_table(self):
        cases = {
            f"/channels/{UUID}/messages": "/channels/{}/messages",
            "/channels/{channel_id}/messages": "/channels/{}/messages",
            "/blobs/" + "ab" * 16: "/blobs/{}",
            "/blobs/" + "ab" * 32: "/blobs/{}",
            "/invites/AbC12345/redeem": "/invites/{}/redeem",
            "/invites/{code}/redeem": "/invites/{}/redeem",
            f"/channels/{UUID}/messages?limit=5": "/channels/{}/messages",
            f"/channels/{UUID}/messages/": "/channels/{}/messages",
            "/": "/",
        }
        for raw, want in cases.items():
            with self.subTest(raw=raw):
                self.assertEqual(C.canon(raw), want)


class DocumentedTest(unittest.TestCase):
    def test_reads_only_the_paths_block(self):
        with tempfile.NamedTemporaryFile("w", suffix=".yaml") as fh:
            fh.write(SCHEMA)
            fh.flush()
            self.assertEqual(C.documented(fh.name), [
                "/healthz", "/channels/{channel_id}/messages",
                "/invites/{code}/redeem"])

    def test_every_real_path_canonicalises_uniquely(self):
        canon = [C.canon(p) for p in C.documented(OPENAPI)]
        self.assertGreater(len(canon), 50)
        self.assertEqual(len(canon), len(set(canon)))


class ReportTest(unittest.TestCase):
    def test_a_real_invite_request_covers_the_template(self):
        with tempfile.NamedTemporaryFile("w", suffix=".yaml") as fh:
            fh.write(SCHEMA)
            fh.flush()
            with contextlib.redirect_stdout(io.StringIO()):
                covered, missing = C.report(
                    {"/invites/AbC12345/redeem", f"/channels/{UUID}/messages"},
                    fh.name)
        self.assertEqual(covered, ["/channels/{channel_id}/messages",
                                   "/invites/{code}/redeem"])
        self.assertEqual(missing, ["/healthz"])


if __name__ == "__main__":
    unittest.main()
