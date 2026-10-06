# SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
"""The canvas seeder's readback, against a stand-in that pages like the server."""
import sys
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))

import seed_canvas_run as run  # noqa: E402
from fake_canvas_server import FakeCanvasServer  # noqa: E402


def stream(server, n, kind="place"):
    for _ in range(n):
        server._append(kind)


class OpsReadbackTest(unittest.TestCase):
    def read(self, server):
        api = server.user("a")
        return run._ops_readback(api, "c")

    def test_counts_every_op_when_the_stream_spans_several_pages(self):
        server = FakeCanvasServer()
        stream(server, 450)
        stream(server, 30, "move")
        got = self.read(server)
        self.assertEqual(got["count"], 480)
        self.assertEqual(got["by_kind"], {"place": 450, "move": 30})
        self.assertEqual(got["latest_seq"], 480)
        self.assertFalse(got["reset"])
        self.assertEqual(got["from_seq"], 0)

    def test_a_long_stream_is_read_from_the_oldest_retrievable_op(self):
        server = FakeCanvasServer()
        stream(server, 4000)
        stream(server, 5, "remove")
        got = self.read(server)
        self.assertFalse(got["reset"])
        self.assertEqual(got["from_seq"], 4005 - 2000)
        self.assertEqual(got["count"], 2000)
        self.assertEqual(got["by_kind"]["remove"], 5)

    def test_an_empty_stream_reads_as_zero_ops(self):
        got = self.read(FakeCanvasServer())
        self.assertEqual((got["count"], got["latest_seq"]), (0, 0))

    def test_a_reset_is_reported_not_counted_as_zero_ops(self):
        server = FakeCanvasServer()
        stream(server, 10)
        api = server.user("a")
        real = server.ops_page
        server.ops_page = lambda after, limit: {
            **real(after, limit), "ops": [], "reset": True}
        got = run._ops_readback(api, "c")
        self.assertTrue(got["reset"])


if __name__ == "__main__":
    unittest.main()
