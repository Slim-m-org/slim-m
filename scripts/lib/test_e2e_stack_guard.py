# SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
"""The Playwright suite must refuse a stack that is not local and throwaway."""
import sys
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))

import e2e_stack_guard  # noqa: E402
import seed_guard  # noqa: E402


def stack(api="http://localhost:8095", web="http://localhost:8356",
          lk="http://localhost:7880"):
    return {"api": api, "web": web, "livekit": {"http": lk}}


class StackGuardTest(unittest.TestCase):
    def test_a_local_stack_passes(self):
        e2e_stack_guard.check_stack(stack())

    def test_production_hosts_are_refused(self):
        for bad in ("https://slim.npc-server.top", "http://10.0.0.100:8095"):
            with self.assertRaises(seed_guard.GuardError, msg=bad):
                e2e_stack_guard.check_stack(stack(api=bad))

    def test_any_other_remote_host_is_refused(self):
        with self.assertRaises(seed_guard.GuardError):
            e2e_stack_guard.check_stack(stack(web="http://example.com"))

    def test_the_sfu_url_is_checked_too(self):
        with self.assertRaises(seed_guard.GuardError):
            e2e_stack_guard.check_stack(stack(lk="https://lk.npc-server.top"))


if __name__ == "__main__":
    unittest.main()
