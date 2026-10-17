# SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
"""Unit coverage for replaying a parsed conversation as real API calls.

No network: every account's `api` is a `Mock`, so every assertion is on
which channel and reply target a call carried, not on what a real server
did with it.
"""
import random
import sys
import unittest
from pathlib import Path
from unittest.mock import Mock

sys.path.insert(0, str(Path(__file__).resolve().parent))

import seed_conversation  # noqa: E402
import seed_replay  # noqa: E402
import seed_state  # noqa: E402


def _turn(speaker, text="hi", reply_to=-1, thread_root=False, in_thread=-1, reactions=()):
    return seed_conversation.Turn(
        speaker=speaker, text=text, reply_to=reply_to,
        thread_root=thread_root, in_thread=in_thread, reactions=list(reactions))


def _account(username):
    fake_api = Mock()
    counter = iter(range(1, 10_000))
    fake_api.send_message.side_effect = (
        lambda channel_id, text, reply_to_id=None:
            {"id": f"msg-{username}-{next(counter)}"})
    fake_api.open_thread.side_effect = (
        lambda channel_id, message_id: {"id": f"thread-{message_id}"})
    fake_api.call.return_value = {"id": "reaction-ack"}
    return {"username": username, "display_name": username.title(), "api": fake_api}


class ReplayTest(unittest.TestCase):
    def setUp(self):
        self.alan = _account("alan")
        self.grace = _account("grace")
        self.accounts = {"Alan": self.alan, "Grace": self.grace}
        self.state = seed_state.SeedState()
        self.rng = random.Random(1)

    def _replay(self, turns, topic="t"):
        conv = seed_conversation.Conversation(topic=topic, turns=turns)
        return seed_replay.replay(
            conv, self.accounts, "main-channel", self.state, self.rng,
            pace_range=(0, 0))

    def test_a_plain_turn_sends_to_the_main_channel_with_no_reply(self):
        stats, failures = self._replay([_turn("Alan")])
        self.assertEqual(failures, [])
        self.assertEqual(stats["conversation_message"], 1)
        call = self.alan["api"].send_message.call_args
        self.assertEqual(call.args[0], "main-channel")
        self.assertIsNone(call.args[2])

    def test_an_unresolvable_speaker_turn_is_skipped_not_failed(self):
        stats, failures = self._replay([_turn(None), _turn("Alan")])
        self.assertEqual(failures, [])
        self.assertEqual(stats["conversation_message"], 1)

    def test_a_speaker_not_in_this_conversations_accounts_is_skipped(self):
        stats, _failures = self._replay([_turn("Somebody Else"), _turn("Alan")])
        self.assertEqual(stats["conversation_message"], 1)
        self.assertEqual(stats["conversation_skipped_speaker"], 1)

    def test_a_valid_reply_to_carries_the_targets_message_id_and_mentions_them(self):
        stats, _failures = self._replay([
            _turn("Alan", text="opening"),
            _turn("Grace", text="reacting", reply_to=0),
        ])
        self.assertEqual(stats["conversation_message"], 2)
        reply_call = self.grace["api"].send_message.call_args
        self.assertEqual(reply_call.args[0], "main-channel")
        self.assertTrue(reply_call.args[1].startswith("@alan "))
        self.assertIsNotNone(reply_call.args[2])

    def test_replying_to_ones_own_earlier_turn_never_self_mentions(self):
        _stats, _failures = self._replay([
            _turn("Alan", text="first"),
            _turn("Alan", text="second", reply_to=0),
        ])
        second_call = self.alan["api"].send_message.call_args_list[1]
        self.assertFalse(second_call.args[1].startswith("@alan "))

    def test_an_out_of_range_reply_to_falls_back_to_the_most_recent_message(self):
        stats, failures = self._replay([
            _turn("Alan", text="first"),
            _turn("Grace", text="second", reply_to=999),
        ])
        self.assertEqual(failures, [])
        reply_call = self.grace["api"].send_message.call_args
        self.assertIsNotNone(reply_call.args[2])

    def test_a_thread_root_opens_a_real_thread(self):
        stats, failures = self._replay([_turn("Alan", thread_root=True)])
        self.assertEqual(failures, [])
        self.assertEqual(stats["conversation_open_thread"], 1)
        self.alan["api"].open_thread.assert_called_once()
        self.assertEqual(self.state.counts()["threads"], 1)

    def test_an_in_thread_turn_sends_into_the_threads_own_channel(self):
        stats, _failures = self._replay([
            _turn("Alan", text="root", thread_root=True),
            _turn("Grace", text="reply in thread", in_thread=0),
        ])
        self.assertEqual(stats["conversation_message"], 2)
        thread_call = self.grace["api"].send_message.call_args
        self.assertNotEqual(thread_call.args[0], "main-channel")
        self.assertTrue(thread_call.args[0].startswith("thread-"))

    def test_a_stray_in_thread_becomes_a_normal_top_level_message(self):
        """A model output naming a thread that was never actually opened
        (or never resolved) must not sweep unrelated content into whatever
        thread happens to be open - it lands in the main channel instead,
        which is the fix for real generated output that kept referencing
        a thread_root it never set, collapsing most of a conversation's
        own back-and-forth into one unrelated thread."""
        stats, _failures = self._replay([
            _turn("Alan", text="root", thread_root=True),
            _turn("Grace", text="reply", in_thread=999),
        ])
        thread_call = self.grace["api"].send_message.call_args
        self.assertEqual(thread_call.args[0], "main-channel")

    def test_a_thread_root_turn_that_actually_lives_in_a_thread_never_nests(self):
        """A turn resolved into a thread channel (by `in_thread`) never
        itself opens a second thread, matching the server's own refusal to
        nest one thread inside another."""
        stats, _failures = self._replay([
            _turn("Alan", text="root", thread_root=True),
            _turn("Grace", text="nested?", in_thread=0, thread_root=True),
        ])
        self.assertEqual(stats["conversation_open_thread"], 1)

    def test_reactions_are_applied_from_the_named_reactors(self):
        stats, failures = self._replay([
            _turn("Alan", reactions=[("🔥", ["Grace"])]),
        ])
        self.assertEqual(failures, [])
        self.assertEqual(stats["conversation_react"], 1)
        put_call = self.grace["api"].call.call_args
        self.assertEqual(put_call.args[0], "PUT")
        self.assertIn("reactions/", put_call.args[1])

    def test_a_reactor_absent_from_this_conversation_is_skipped(self):
        stats, failures = self._replay([
            _turn("Alan", reactions=[("🔥", ["Somebody Else"])]),
        ])
        self.assertEqual(failures, [])
        self.assertEqual(stats["conversation_react"], 0)

    def test_a_failing_send_is_recorded_not_raised(self):
        self.alan["api"].send_message.side_effect = RuntimeError("boom")
        stats, failures = self._replay([_turn("Alan"), _turn("Grace")])
        self.assertEqual(stats["conversation_message"], 1)
        self.assertEqual(len(failures), 1)
        username, action, reason = failures[0]
        self.assertEqual(username, "alan")
        self.assertEqual(action, "conversation_message")
        self.assertIn("boom", reason)


if __name__ == "__main__":
    unittest.main()
