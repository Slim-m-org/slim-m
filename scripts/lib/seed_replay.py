# SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
"""Sends a parsed `seed_conversation.Conversation` as real API calls.

Split out of `seed_conversation.py` to keep that file under the review
budget: that module is about turning a model's raw JSON into something
trustworthy, this one is about turning a trusted `Conversation` into
messages, threads and reactions on the real server, in order, from the real
seed accounts.
"""
import collections
import time
import urllib.parse

import seed_backoff
import seed_content


def _try(failures, ctx, action_name, action):
    """Runs `action`, recording rather than raising on failure - the same
    best-effort contract every other seeding pass gives an individual step.
    """
    try:
        return True, action()
    # a dropped action is reported, never silent
    except Exception as exc:  # noqa: BLE001
        failures.append((ctx["username"], action_name, seed_backoff.describe_error(exc)))
        return False, None


def _send(ctx, channel_id, text, reply_to_id):
    return seed_backoff.call_with_backoff(
        lambda: ctx["api"].send_message(channel_id, text, reply_to_id))


def _open_thread(ctx, channel_id, message_id):
    return seed_backoff.call_with_backoff(
        lambda: ctx["api"].open_thread(channel_id, message_id))


def _react(ctx, message_id, emoji):
    encoded = urllib.parse.quote(emoji, safe="")
    return seed_backoff.call_with_backoff(
        lambda: ctx["api"].call("PUT", f"/messages/{message_id}/reactions/{encoded}"))


def replay(conversation, accounts_by_display, main_channel_id, state, rng,
           pace_range=(0.25, 0.8)):
    """Sends `conversation` as real messages, threads and reactions, from
    the real accounts in `accounts_by_display` (keyed by display name, the
    shape `seed_accounts.register_accounts` returns).

    Returns `(stats, failures)`, the same shape every other seeding pass
    reports in. A turn's `in_thread` only sends it into a thread when it
    names one this replay actually opened; anything else - a stray index,
    or a model that never opened the thread it kept referencing - is a
    normal top-level message rather than being swept into an unrelated
    thread. That is a deliberate choice, not a shortcut: an earlier version
    fell back to "the most recently opened thread" for any unresolved
    index, and against real model output that collapsed most of a
    conversation's own back-and-forth into one thread the model never
    meant to be that deep, starving the main channel of exactly the
    content this replay exists to put there. `reply_to`'s own fallback (to
    the most recent message in the same channel scope) is unaffected,
    since it only changes which prior message a top-level reply points at,
    never which channel the reply itself lands in.
    """
    run = _Replay(accounts_by_display, main_channel_id, state)
    for idx, turn in enumerate(conversation.turns):
        run.play(idx, turn, rng, pace_range)
    return run.stats, run.failures


class _Replay:
    def __init__(self, accounts_by_display, main_channel_id, state):
        self.accounts_by_display = accounts_by_display
        self.main_channel_id = main_channel_id
        self.state = state
        self.stats = collections.Counter()
        self.failures = []
        self.message_ids = {}
        self.channel_ids = {}
        self.authors = {}
        self.thread_channel_for = {}
        self.most_recent_in_channel = {}

    def play(self, idx, turn, rng, pace_range):
        if turn.speaker is None:
            return
        ctx = self.accounts_by_display.get(turn.speaker)
        if ctx is None:
            self.stats["conversation_skipped_speaker"] += 1
            return

        target_channel = self.main_channel_id
        if turn.in_thread >= 0:
            target_channel = self.thread_channel_for.get(
                turn.in_thread, self.main_channel_id)
        reply_to_id, reply_to_author = self._reply_target(turn, target_channel)

        text = turn.text
        if reply_to_id is not None and reply_to_author and reply_to_author != ctx["username"]:
            text = f"@{reply_to_author} {text}"[:seed_content.MAX_MESSAGE_CHARS]

        ok, msg = _try(self.failures, ctx, "conversation_message",
                        lambda ctx=ctx, target_channel=target_channel, text=text,
                        reply_to_id=reply_to_id: _send(ctx, target_channel, text, reply_to_id))
        time.sleep(rng.uniform(*pace_range))
        if not ok:
            return
        self.stats["conversation_message"] += 1
        self.message_ids[idx] = msg["id"]
        self.channel_ids[idx] = target_channel
        self.authors[idx] = ctx["username"]
        self.most_recent_in_channel[target_channel] = (msg["id"], ctx["username"])

        if target_channel == self.main_channel_id:
            self.state.add_top_message(msg["id"], self.main_channel_id, ctx["username"])
            if turn.thread_root:
                self._open_thread(idx, ctx, msg["id"])
        self._react_all(turn, msg["id"])

    def _reply_target(self, turn, target_channel):
        if turn.reply_to < 0:
            return None, None
        if self.channel_ids.get(turn.reply_to) == target_channel:
            return (self.message_ids.get(turn.reply_to),
                    self.authors.get(turn.reply_to))
        if target_channel in self.most_recent_in_channel:
            return self.most_recent_in_channel[target_channel]
        return None, None

    def _open_thread(self, idx, ctx, message_id):
        ok, thread = _try(
            self.failures, ctx, "conversation_open_thread",
            lambda: _open_thread(ctx, self.main_channel_id, message_id))
        if ok:
            self.stats["conversation_open_thread"] += 1
            self.thread_channel_for[idx] = thread["id"]
            self.state.add_thread(message_id, thread["id"])

    def _react_all(self, turn, message_id):
        for emoji, reactor_names in turn.reactions:
            for name in reactor_names:
                reactor = self.accounts_by_display.get(name)
                if reactor is None:
                    continue
                ok, _result = _try(
                    self.failures, reactor, "conversation_react",
                    lambda reactor=reactor, emoji=emoji: _react(reactor, message_id, emoji))
                if ok:
                    self.stats["conversation_react"] += 1
