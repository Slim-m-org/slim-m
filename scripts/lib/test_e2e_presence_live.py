# SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
"""A presence scenario that fails midway must hand alice's network back."""
import unittest
from unittest import mock

import e2e_presence_live as live


class _Alice:
    def __init__(self):
        self.network = "online"

    def go_offline(self):
        self.network = "offline"

    def go_online(self):
        self.network = "online"

    def ev(self, expr):
        return None

    def enable_semantics(self):
        pass


class _Watch:
    def __init__(self):
        self.a = _Alice()

    def until(self, *args):
        pass


class _Carol:
    def enable_semantics(self):
        pass

    def ev(self, expr):
        return "home"

    def wait_for(self, *args, **kwargs):
        raise AssertionError("never saw the rejoin prompt")


class AliceComesBack(unittest.TestCase):
    def test_a_missing_rejoin_prompt_does_not_strand_alice_offline(self):
        w = _Watch()
        with mock.patch.object(live.time, "sleep"), self.assertRaises(AssertionError):
            live._while_alice_was_away(w, _Carol())
        self.assertEqual(w.a.network, "online")

    def test_a_failure_while_alice_restarts_clears_the_slow_network(self):
        w = _Watch()
        def slow(client, latency):
            client.network = "slow"

        with mock.patch.object(live, "_slow_network", slow), \
                mock.patch.object(live.time, "sleep"), \
                mock.patch.object(live, "_close", return_value="home"), \
                mock.patch.object(live, "_reopen", side_effect=AssertionError("boom")), \
                self.assertRaises(AssertionError):
            live._while_alice_was_starting(w, _Carol())
        self.assertEqual(w.a.network, "online")


if __name__ == "__main__":
    unittest.main()
