# SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
"""How the parallel e2e run deals scenarios across stacks."""
import sys
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))

import e2e_groups  # noqa: E402
import e2e_parallel  # noqa: E402
import e2e_run  # noqa: E402

NAMES = e2e_run.scenario_names()


class DealTest(unittest.TestCase):
    def test_every_scenario_runs_exactly_once(self):
        for shards in (1, 2, 4, 7):
            dealt = e2e_groups.deal(NAMES, shards)
            flat = [n for chunk in dealt for n in chunk]
            self.assertEqual(sorted(flat), sorted(NAMES), shards)

    def test_a_group_never_splits_across_stacks(self):
        dealt = e2e_groups.deal(NAMES, 4)
        homes = {}
        for index, chunk in enumerate(dealt):
            for name in chunk:
                homes.setdefault(e2e_groups.group_of(name), set()).add(index)
        for group, where in homes.items():
            self.assertEqual(len(where), 1, group)

    def test_a_stack_keeps_the_running_order(self):
        position = {n: i for i, n in enumerate(NAMES)}
        for chunk in e2e_groups.deal(NAMES, 3):
            self.assertEqual(chunk, sorted(chunk, key=position.get))

    def test_the_heaviest_group_sets_the_floor_not_the_count(self):
        names = ["a: one", "b: two", "c: three"]
        weights = {"a: one": 100, "b: two": 10, "c: three": 10}
        dealt = e2e_groups.deal(names, 2, weights)
        self.assertEqual(dealt[0], ["a: one"])

    def test_a_scenario_with_no_rule_is_its_own_group(self):
        self.assertEqual(e2e_groups.group_of("voice: something new"),
                         "voice: something new")

    def test_state_sharing_areas_stay_together(self):
        self.assertEqual(e2e_groups.group_of("canvas: closing it"), "canvas")
        self.assertEqual(
            e2e_groups.group_of("voice: leaving"),
            e2e_groups.group_of("voice: two clients in one call"))

    def test_the_run_order_inside_the_call_group_is_unchanged(self):
        call = [n for n in NAMES if e2e_groups.group_of(n) == "call"]
        self.assertEqual(call[0], "voice: two clients in one call")
        self.assertTrue(call[-1].startswith("voice: re-clicking"))


class ShardEnvTest(unittest.TestCase):
    def test_no_two_stacks_share_a_port_or_container(self):
        envs = [e2e_parallel.shard_env(i, "/tmp/x") for i in range(6)]
        for key in ("E2E_API_PORT", "E2E_WEB_PORT", "E2E_LK_PORT",
                    "E2E_RTC_TCP_PORT", "E2E_CDP_BASE", "E2E_LK_CONTAINER",
                    "E2E_WORK", "E2E_RTC_UDP_START"):
            values = [e[key] for e in envs]
            self.assertEqual(len(set(values)), len(values), key)

    def test_the_udp_ranges_do_not_overlap(self):
        envs = [e2e_parallel.shard_env(i, "/tmp/x") for i in range(6)]
        spans = sorted((int(e["E2E_RTC_UDP_START"]), int(e["E2E_RTC_UDP_END"]))
                       for e in envs)
        for (_, end), (start, _) in zip(spans, spans[1:]):
            self.assertLess(end, start)

    def test_the_default_serial_ports_stay_clear(self):
        owned = {"8095", "8356", "7880", "7881", "9801", "9802"}
        env = e2e_parallel.shard_env(0, "/tmp/x")
        self.assertFalse(owned & {env[k] for k in (
            "E2E_API_PORT", "E2E_WEB_PORT", "E2E_LK_PORT", "E2E_RTC_TCP_PORT")})
        self.assertNotEqual(env["E2E_LK_CONTAINER"], "slimm-e2e-lk")

    def test_a_missing_result_is_a_failure(self):
        env = {"E2E_RESULTS": "/nonexistent/results.json"}
        rows = e2e_parallel.merge([(env, ["x: one"])], ["x: one"], [1])
        self.assertEqual(rows, [("x: one", 0, False, 0.0)])


if __name__ == "__main__":
    unittest.main()
