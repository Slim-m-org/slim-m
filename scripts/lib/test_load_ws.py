# SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
"""The loadtest subscriber's handshake and what it leaves open."""
import asyncio
import json
import sys
import types
import unittest
from pathlib import Path
from unittest import mock

sys.path.insert(0, str(Path(__file__).resolve().parent))

try:
    import websockets  # noqa: F401
except ImportError:
    sys.modules["websockets"] = types.ModuleType("websockets")

import load_ws  # noqa: E402


class FakeApi:
    def call(self, method, path, body=None):
        return {"ticket": "tkt"}


class FakeSocket:
    def __init__(self, replies):
        self.replies = list(replies)
        self.sent = []
        self.closed = False

    async def send(self, raw):
        self.sent.append(json.loads(raw))

    async def recv(self):
        reply = self.replies.pop(0)
        if isinstance(reply, BaseException):
            raise reply
        return json.dumps(reply)

    async def close(self):
        self.closed = True


def opened(sock, name="u"):
    sub = load_ws.Subscriber(name, FakeApi(), "ws://x")

    async def connect(*args, **kwargs):
        return sock

    with mock.patch.object(load_ws.websockets, "connect", connect,
                           create=True):
        ok = asyncio.run(sub.open())
    return sub, ok


class OpenTest(unittest.TestCase):
    def test_a_good_hello_connects_and_close_closes(self):
        sock = FakeSocket([{"type": "hello"}])
        sub, ok = opened(sock)
        self.assertTrue(ok)
        self.assertEqual(sock.sent[0]["ticket"], "tkt")
        asyncio.run(sub.close())
        self.assertTrue(sock.closed)

    def test_a_wrong_reply_is_recorded_and_the_socket_is_closed(self):
        sock = FakeSocket([{"type": "error"}])
        sub, ok = opened(sock)
        self.assertFalse(ok)
        self.assertIn("expected hello", sub.failure)
        asyncio.run(sub.close())
        self.assertTrue(sock.closed)

    def test_a_failed_hello_read_closes_the_socket(self):
        sock = FakeSocket([ConnectionError("reset")])
        sub, ok = opened(sock)
        self.assertFalse(ok)
        asyncio.run(sub.close())
        self.assertTrue(sock.closed)

    def test_close_before_any_connect_is_harmless(self):
        sub = load_ws.Subscriber("u", FakeApi(), "ws://x")
        asyncio.run(sub.close())


class ListenTest(unittest.TestCase):
    def test_records_each_created_message_and_stops_on_resync(self):
        sock = FakeSocket([
            {"type": "hello"},
            {"type": "message.created", "message": {"id": "m1"}},
            {"type": "typing"},
            {"type": "resync"},
        ])
        sub, _ = opened(sock)
        seen = {}
        asyncio.run(sub.listen(seen, asyncio.Event()))
        self.assertEqual(list(seen), ["m1"])
        self.assertEqual(sub.resync, 1)


if __name__ == "__main__":
    unittest.main()
