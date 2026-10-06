# SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
"""`seed_run.run` wires accounts, workers, the conversation replay and the
settle pass together; these tests fake the network edges and check the wiring."""
import argparse
import collections
import sys
import unittest
from pathlib import Path
from unittest.mock import patch

sys.path.insert(0, str(Path(__file__).resolve().parent))

import seed_actions  # noqa: E402
import seed_conversation  # noqa: E402
import seed_run  # noqa: E402


def _args(**overrides):
    values = dict(
        base_url="http://local", confirm=False, i_know_this_is_production=False,
        accounts=2, actions_per_account=3, concurrency=None, invite_code=None,
        admin_username="admin", admin_password=None, password="pw",
        channel_name="chan", seed=7, username_tag="", ollama=False,
        ollama_model=None)
    values.update(overrides)
    return argparse.Namespace(**values)


def _accounts():
    return [{"username": f"user{i}", "display_name": f"Persona{i}", "api": object()}
            for i in range(2)]


class Harness:
    """Patches every network edge of `seed_run.run` and records the order."""

    def __init__(self, test, *, admin_api, conversations=None):
        self.events = []
        self.contexts = []
        self.accounts = _accounts()
        self.admin_api = admin_api

        def run_account(ctx, count, pace, actions=None):
            self.contexts.append(ctx)
            self.events.append(("worker", ctx.username, actions))
            return collections.Counter(), []

        def replay(conversation, by_display, channel_id, state, rng, **kwargs):
            kind = "replay" if "pace_range" in kwargs else "tail"
            self.events.append((kind, conversation.topic))
            return collections.Counter(), []

        def settle(contexts, state, rng):
            self.events.append(("settle",))
            return collections.Counter(), []

        patches = [
            patch("seed_guard.guard", return_value="http://local"),
            patch("seed_accounts.obtain_invite_code",
                  return_value=("code", admin_api)),
            patch("seed_accounts.register_accounts", return_value=self.accounts),
            patch("seed_accounts.create_seed_channel", return_value={"id": "chan-1"}),
            patch("seed_fixtures.build", return_value=[]),
            patch("seed_worker.run_account", side_effect=run_account),
            patch("seed_replay.replay", side_effect=replay),
            patch("seed_settle.run", side_effect=settle),
            patch("seed_run._conversation_pace_range", return_value=(0, 0)),
            patch("builtins.print"),
        ]
        if conversations is not None:
            patches += [
                patch("seed_ollama_pools.load_or_generate", return_value=None),
                patch("seed_conversation.build_conversations",
                      return_value=conversations),
            ]
        for p in patches:
            p.start()
            test.addCleanup(p.stop)


def _conversation(topic):
    return seed_conversation.Conversation(topic=topic, turns=[object()] * 2)


class RunTest(unittest.TestCase):
    def test_the_admin_is_its_own_worker_and_the_only_privileged_one(self):
        admin_api = object()
        harness = Harness(self, admin_api=admin_api)
        self.assertEqual(seed_run.run(_args()), 0)
        privileged = {c.username: c.is_privileged for c in harness.contexts}
        self.assertEqual(privileged, {"user0": False, "user1": False, "admin": True})
        admin = next(c for c in harness.contexts if c.username == "admin")
        self.assertIs(admin.api, admin_api)
        self.assertEqual(sorted(admin.other_usernames), ["user0", "user1"])

    def test_without_an_admin_the_first_account_is_privileged(self):
        harness = Harness(self, admin_api=None)
        seed_run.run(_args())
        privileged = {c.username: c.is_privileged for c in harness.contexts}
        self.assertEqual(privileged, {"user0": True, "user1": False})

    def test_settle_runs_last(self):
        harness = Harness(self, admin_api=None)
        seed_run.run(_args())
        self.assertEqual(harness.events[-1], ("settle",))
        self.assertEqual(len(harness.events), 3)

    def test_generated_conversations_replay_with_the_tail_after_the_pool(self):
        harness = Harness(self, admin_api=None,
                          conversations=[_conversation("first"), _conversation("last")])
        seed_run.run(_args(ollama=True))
        tail_at = harness.events.index(("tail", "last"))
        last_worker = max(i for i, e in enumerate(harness.events) if e[0] == "worker")
        self.assertGreater(tail_at, last_worker)
        self.assertEqual(harness.events[tail_at + 1:], [("settle",)])
        self.assertIn(("replay", "first"), harness.events)

    def test_conversations_trim_the_workers_to_the_utility_actions(self):
        harness = Harness(self, admin_api=None, conversations=[_conversation("c")])
        seed_run.run(_args(ollama=True))
        worker_actions = {e[2] for e in harness.events if e[0] == "worker"}
        self.assertEqual(worker_actions, {seed_actions.UTILITY_ACTIONS})

    def test_no_conversations_runs_the_full_action_set(self):
        harness = Harness(self, admin_api=None)
        seed_run.run(_args())
        worker_actions = {e[2] for e in harness.events if e[0] == "worker"}
        self.assertEqual(worker_actions, {seed_actions.ACTIONS})


class RefusalTest(unittest.TestCase):
    def test_a_guard_refusal_exits_before_any_account_is_registered(self):
        import seed_guard
        with patch("seed_guard.guard", side_effect=seed_guard.GuardError("no")), \
             patch("seed_accounts.register_accounts") as register:
            with self.assertRaises(SystemExit):
                seed_run.run(_args())
        register.assert_not_called()

    def test_zero_accounts_is_refused(self):
        with patch("seed_guard.guard", return_value="http://local"), \
             self.assertRaises(SystemExit):
            seed_run.run(_args(accounts=0))


if __name__ == "__main__":
    unittest.main()
