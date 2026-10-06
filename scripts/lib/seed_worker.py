# SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
"""One account's stream of actions.

Each worker owns one `WorkerContext` (one `Api`, one `random.Random`) and
runs on its own thread, so the only shared, lock-protected state is
`SeedState`. A failed action - after `seed_backoff` has already retried a
429 past its limit - is recorded and skipped rather than raised, so one
account hitting a real error never takes the rest of the run down with it.
"""
import collections
import dataclasses
import time
import urllib.parse

import seed_actions
import seed_backoff
import seed_content
import seed_links
import uuid7


@dataclasses.dataclass
class WorkerContext:
    api: object
    username: str
    channel_id: str
    state: object
    rng: object
    other_usernames: list
    is_privileged: bool
    fixtures: list
    corpus: object = None


def _pool(ctx, attr):
    """The named pool off `ctx.corpus`, or `None` for a plain canned run.

    `ctx.corpus` may itself be a `Corpus` with some pools empty (a partial
    generation failure), which an empty list already tells every
    `seed_content` generator to fall back on, so no extra check is needed
    here beyond "is there a corpus at all".
    """
    return getattr(ctx.corpus, attr) if ctx.corpus is not None else None


def _do_message(ctx, content, reply_to_id=None):
    msg = seed_backoff.call_with_backoff(
        lambda: ctx.api.send_message(ctx.channel_id, content, reply_to_id))
    ctx.state.add_top_message(msg["id"], ctx.channel_id, ctx.username)
    return msg


def handle_message_short(ctx):
    _do_message(ctx, seed_content.short_message(ctx.rng, pool=_pool(ctx, "short")))
    return "sent a short message"


def handle_message_long(ctx):
    _do_message(ctx, seed_content.long_message(ctx.rng, pool=_pool(ctx, "long")))
    return "sent a long message"


def handle_message_emoji(ctx):
    _do_message(ctx, seed_content.emoji_message(ctx.rng, pool=_pool(ctx, "short")))
    return "sent a message with emoji"


def handle_message_markdown(ctx):
    _do_message(ctx, seed_content.markdown_message(ctx.rng, pool=_pool(ctx, "short")))
    return "sent a markdown message"


def handle_message_code_block(ctx):
    _do_message(ctx, seed_content.code_block_message(ctx.rng, pool=_pool(ctx, "code")))
    return "sent a code block"


def handle_message_mention(ctx):
    if not ctx.other_usernames:
        return handle_message_short(ctx)
    _do_message(ctx, seed_content.mention_message(
        ctx.rng, ctx.other_usernames, pool=_pool(ctx, "short")))
    return "sent a message mentioning someone"


def handle_message_near_limit(ctx):
    _do_message(ctx, seed_content.near_limit_message(ctx.rng, pool=_pool(ctx, "short")))
    return "sent a message near the character limit"


def handle_message_link(ctx):
    _do_message(ctx, seed_links.link_message(ctx.rng))
    return "sent a message with a link"


def handle_burst(ctx):
    """A short run of consecutive messages, so the transcript groups them."""
    for _ in range(ctx.rng.randint(2, 4)):
        _do_message(ctx, seed_content.short_message(ctx.rng, pool=_pool(ctx, "short")))
        time.sleep(ctx.rng.uniform(0.2, 0.8))
    return "sent a consecutive burst"


def handle_reply(ctx):
    target = ctx.state.random_top_message(ctx.rng)
    if target is None:
        return handle_message_short(ctx)
    content = seed_content.short_message(ctx.rng, pool=_pool(ctx, "short"))
    if target["author"] != ctx.username:
        content = f"@{target['author']} {content}"
    _do_message(ctx, content, reply_to_id=target["id"])
    return f"replied to {target['author']}"


def handle_open_thread(ctx):
    target = ctx.state.random_top_message(ctx.rng)
    if target is None:
        return handle_message_short(ctx)
    thread = seed_backoff.call_with_backoff(
        lambda: ctx.api.open_thread(ctx.channel_id, target["id"]))
    ctx.state.add_thread(target["id"], thread["id"])
    opener = seed_content.short_message(ctx.rng, pool=_pool(ctx, "short"))
    seed_backoff.call_with_backoff(
        lambda: ctx.api.send_message(thread["id"], opener))
    return "opened a thread"


def handle_reply_in_thread(ctx):
    thread = ctx.state.random_thread(ctx.rng)
    if thread is None:
        return handle_open_thread(ctx)
    _, thread_channel_id = thread
    reply = seed_content.short_message(ctx.rng, pool=_pool(ctx, "short"))
    seed_backoff.call_with_backoff(
        lambda: ctx.api.send_message(thread_channel_id, reply))
    return "replied inside a thread"


def handle_react(ctx):
    target = ctx.state.random_top_message(ctx.rng)
    if target is None:
        return handle_message_short(ctx)
    emoji = ctx.rng.choice(seed_content.EMOJI)
    encoded = urllib.parse.quote(emoji, safe="")
    seed_backoff.call_with_backoff(
        lambda: ctx.api.call("PUT", f"/messages/{target['id']}/reactions/{encoded}"))
    return f"reacted {emoji}"


def handle_edit_message(ctx):
    own = ctx.state.random_own_message(ctx.rng, ctx.username)
    if own is None:
        return handle_message_short(ctx)
    content = f"{seed_content.short_message(ctx.rng, pool=_pool(ctx, 'short'))} (edit)"
    seed_backoff.call_with_backoff(
        lambda: ctx.api.edit_message(own["channel_id"], own["id"], content))
    return "edited a message"


def handle_delete_message(ctx):
    own = ctx.state.random_own_message(ctx.rng, ctx.username)
    if own is None:
        return handle_message_short(ctx)
    seed_backoff.call_with_backoff(
        lambda: ctx.api.delete_message(own["channel_id"], own["id"]))
    ctx.state.forget_own_message(ctx.username, own["id"])
    return "deleted a message"


def handle_pin_message(ctx):
    target = ctx.state.random_top_message(ctx.rng)
    if target is None:
        return handle_message_short(ctx)
    seed_backoff.call_with_backoff(
        lambda: ctx.api.call(
            "PUT", f"/channels/{target['channel_id']}/messages/{target['id']}/pin"))
    return "pinned a message"


def handle_send_poll(ctx):
    question, options = seed_content.poll(ctx.rng, pool=_pool(ctx, "polls"))
    body = {"id": uuid7.uuid7(), "question": question, "options": options}
    msg = seed_backoff.call_with_backoff(
        lambda: ctx.api.call(
            "POST", f"/channels/{ctx.channel_id}/messages/polls", body))
    ctx.state.add_top_message(msg["id"], ctx.channel_id, ctx.username)
    ctx.state.add_poll(msg["id"], ctx.channel_id, len(options))
    return "sent a poll"


def handle_vote_poll(ctx):
    poll = ctx.state.random_unvoted_poll(ctx.rng, ctx.username)
    if poll is None:
        return handle_message_short(ctx)
    option = ctx.rng.randrange(poll["options_count"])
    seed_backoff.call_with_backoff(
        lambda: ctx.api.call(
            "PUT", f"/messages/{poll['id']}/polls/vote", {"option": option}))
    ctx.state.record_poll_vote(poll["id"], ctx.username)
    return f"voted on a poll (option {option})"


def handle_send_attachment(ctx):
    data, content_type, filename = ctx.rng.choice(ctx.fixtures)
    quoted = urllib.parse.quote(filename)
    uploaded = seed_backoff.call_with_backoff(
        lambda: ctx.api.call("POST", f"/attachments?filename={quoted}",
                              raw=data, content_type=content_type))
    caption = seed_content.short_message(ctx.rng, pool=_pool(ctx, "short"))
    body = {"id": uuid7.uuid7(), "content": caption,
            "attachment_ids": [uploaded["id"]]}
    msg = seed_backoff.call_with_backoff(
        lambda: ctx.api.call("POST", f"/channels/{ctx.channel_id}/messages", body))
    ctx.state.add_top_message(msg["id"], ctx.channel_id, ctx.username)
    return "sent an attachment"


HANDLERS = {
    "message_short": handle_message_short,
    "message_long": handle_message_long,
    "message_emoji": handle_message_emoji,
    "message_markdown": handle_message_markdown,
    "message_code_block": handle_message_code_block,
    "message_mention": handle_message_mention,
    "message_near_limit": handle_message_near_limit,
    "message_link": handle_message_link,
    "burst": handle_burst,
    "reply": handle_reply,
    "open_thread": handle_open_thread,
    "reply_in_thread": handle_reply_in_thread,
    "react": handle_react,
    "edit_message": handle_edit_message,
    "delete_message": handle_delete_message,
    "pin_message": handle_pin_message,
    "send_poll": handle_send_poll,
    "vote_poll": handle_vote_poll,
    "send_attachment": handle_send_attachment,
}


def run_account(ctx, actions_count, pace_range, actions=None):
    """Performs `actions_count` actions for one account.

    `actions` overrides the weighted pool `seed_actions.choose_action` draws
    from - `seed_run.py` passes `seed_actions.UTILITY_ACTIONS` when a
    generated conversation is already covering the chat-shaped ones, and
    the full `seed_actions.ACTIONS` (the default) otherwise.

    Returns (stats, failures): a Counter of what actually ran, and a list of
    (username, action, reason) for whatever failed even after retrying.
    """
    actions = actions if actions is not None else seed_actions.ACTIONS
    stats = collections.Counter()
    failures = []
    for _ in range(actions_count):
        chosen = seed_actions.choose_action(ctx.rng, actions=actions)
        resolved = seed_actions.resolve_action(
            chosen,
            has_top_message=ctx.state.has_top_message(),
            has_own_message=ctx.state.has_own_message(ctx.username),
            has_thread=ctx.state.has_thread(),
            has_other_account=bool(ctx.other_usernames),
            is_privileged=ctx.is_privileged,
            has_unvoted_poll=ctx.state.has_unvoted_poll(ctx.username))
        try:
            HANDLERS[resolved](ctx)
            stats[resolved] += 1
        except Exception as exc:  # noqa: BLE001 - a dropped action is reported, never silent
            failures.append((ctx.username, resolved, seed_backoff.describe_error(exc)))
        time.sleep(ctx.rng.uniform(*pace_range))
    return stats, failures
