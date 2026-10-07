# SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
"""The listener pool must report a dead worker instead of waiting it out."""
import queue
import sys
import time
import types
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))

try:
    import websockets  # noqa: F401
    HAVE_WEBSOCKETS = True
except ImportError:
    HAVE_WEBSOCKETS = False
    sys.modules["websockets"] = types.ModuleType("websockets")

import load_pool  # noqa: E402


class FakeApi:
    token = "t"


@unittest.skipUnless(HAVE_WEBSOCKETS, "spawned workers import the real websockets")
class DeadWorkerTest(unittest.TestCase):
    def pool(self):
        # A base_url of None makes Api() raise inside the worker before ready.
        return load_pool.ListenerPool(
            [{"username": "u", "api": FakeApi()}], None, "ws://x", 1)

    def test_start_returns_promptly_when_a_worker_dies_before_ready(self):
        pool = self.pool()
        self.addCleanup(pool.abort)
        began = time.monotonic()
        connected, attempted = pool.start(timeout=20)
        self.assertLess(time.monotonic() - began, 15)
        self.assertEqual((connected, attempted), (0, 1))
        got = pool.finish()
        self.assertTrue(any("worker died" in f for f in got["failures"]),
                        got["failures"])

    def test_workers_do_not_outlive_the_parent(self):
        pool = self.pool()
        self.addCleanup(pool.abort)
        pool.start(timeout=20)
        self.assertTrue(all(p.daemon for p in pool._procs))


class FakeProc:
    def __init__(self, pid, alive, code=None):
        self.pid, self._alive, self.exitcode = pid, alive, code

    def is_alive(self):
        return self._alive


class DrainTest(unittest.TestCase):
    def test_a_worker_gone_without_reporting_is_named_not_waited_for(self):
        q = queue.Queue()
        q.put({"pid": 1})
        procs = [FakeProc(1, True), FakeProc(2, False, -9)]
        began = time.monotonic()
        got, lost = load_pool._drain(q, procs, lambda m: m["pid"],
                                     timeout=60, poll=0.05)
        self.assertLess(time.monotonic() - began, 5)
        self.assertEqual(got, [{"pid": 1}])
        self.assertEqual([p.pid for p in lost], [2])

    def test_every_reporting_worker_is_collected(self):
        q = queue.Queue()
        for pid in (1, 2):
            q.put({"pid": pid})
        got, lost = load_pool._drain(
            q, [FakeProc(1, True), FakeProc(2, True)], lambda m: m["pid"],
            timeout=5, poll=0.05)
        self.assertEqual(len(got), 2)
        self.assertEqual(lost, [])


if __name__ == "__main__":
    unittest.main()
