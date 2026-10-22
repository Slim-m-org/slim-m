# SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
"""A final pass of activity on the newest slice of the channel.

The main loop's recency bias (`seed_state.RECENCY_BIAS`) already favours
recent targets over old ones, but that alone cannot fix a run's very last
messages: by the time they exist, there is almost no run left in which
anything could react to or reply on them. No weighting closes a shortage of
remaining actions. This runs once, after every worker has finished, against
a fixed snapshot of the newest messages and threads - never the whole
channel, or it would just move the same problem rather than fix the tail.

Two shapes this pass guarantees rather than leaves to chance, both real
defects reported against an earlier version of this script: a message can
carry several *different* emoji, and an emoji can be reacted to by several
*different* people (a count above 1) - see `_reaction_plan`. And a thread
can be freshly opened here, not just kept alive if one already exists near
the tail - see `SETTLE_NEW_THREADS` - with enough replies (3 to 8) to read
as an actual side conversation rather than a single, lonely reply.

A third shape: the newest polls also get a guaranteed round of votes, for
the same reason as the two above - a poll sent near the tail has almost no
run left in which `vote_poll`'s organic draws could reach it. See
`_poll_vote_plan` for why the spread is a weighted draw rather than one
vote per option: a poll where every option ties reads as generated, not as
something people actually answered.
"""
import collections
import urllib.parse

import seed_backoff
import seed_content
import seed_worker

# How many of the newest top-level messages the pass targets.
SETTLE_TARGET_MESSAGES = 100
# Share of targets that end up with at least one reaction.
SETTLE_REACT_COVERAGE = 0.9
# Share of targets that also get a top-level reply.
SETTLE_REPLY_COVERAGE = 0.15
# How many of the most recently opened threads get a light 1-3-reply top-up.
SETTLE_THREAD_TARGETS = 10
SETTLE_THREAD_REPLIES = (1, 3)
# How many of the newest targets get a brand new, deeply-replied thread.
SETTLE_NEW_THREADS = 6
SETTLE_NEW_THREAD_REPLIES = (3, 8)
# How many of the newest polls get a guaranteed round of voting.
SETTLE_POLL_TARGETS = 10
# Share of those polls that get any votes at all; see the module doc.
SETTLE_POLL_VOTE_COVERAGE = 0.85

# Weighted so one emoji/one reactor is still common, but not the only shape.
_DISTINCT_EMOJI_WEIGHTS = ((1, 45), (2, 35), (3, 20))
_REACTOR_COUNT_WEIGHTS = ((1, 40), (2, 35), (3, 15), (4, 10))
# A vote is a heavier commitment than a reaction, so this skews lower.
_POLL_VOTER_COUNT_WEIGHTS = ((2, 25), (3, 30), (4, 25), (5, 15), (6, 5))


def _actor(contexts, rng, exclude_username=None):
    """A random worker context, preferring one that is not the target's own author."""
    pool = [c for c in contexts if c.username != exclude_username] or contexts
    return rng.choice(pool)


def _weighted_choice(rng, weights):
    return rng.choices([n for n, _w in weights], weights=[w for _n, w in weights])[0]


def _reaction_plan(rng, actor_pool_size):
    """A list of `(emoji, reactor_count)` pairs for one target - see the
    module doc comment for why this is a plan rather than one draw."""
    distinct = min(_weighted_choice(rng, _DISTINCT_EMOJI_WEIGHTS), len(seed_content.EMOJI))
    emojis = rng.sample(seed_content.EMOJI, k=distinct)
    return [(emoji, min(_weighted_choice(rng, _REACTOR_COUNT_WEIGHTS), actor_pool_size))
            for emoji in emojis]


def _react(ctx, target, emoji):
    encoded = urllib.parse.quote(emoji, safe="")
    return seed_backoff.call_with_backoff(
        lambda: ctx.api.call("PUT", f"/messages/{target['id']}/reactions/{encoded}"))


def _reply(ctx, rng, target):
    content = seed_content.short_message(rng, pool=seed_worker._pool(ctx, "short"))
    if target["author"] != ctx.username:
        content = f"@{target['author']} {content}"
    return seed_backoff.call_with_backoff(
        lambda: ctx.api.send_message(
            target["channel_id"], content, reply_to_id=target["id"]))


def _reply_in_thread(ctx, rng, thread_channel_id):
    content = seed_content.short_message(rng, pool=seed_worker._pool(ctx, "short"))
    return seed_backoff.call_with_backoff(
        lambda: ctx.api.send_message(thread_channel_id, content))


def _open_thread(ctx, target):
    return seed_backoff.call_with_backoff(
        lambda: ctx.api.open_thread(target["channel_id"], target["id"]))


def _poll_vote_plan(rng, options_count, voter_count):
    """Which option each of `voter_count` voters picks.

    Weights drawn from `rng.expovariate(1.0)` (Dirichlet(1,...,1) shares
    once normalised, the maximally uninformative split over `options_count`
    categories) rather than one vote per option: a Dirichlet(1) draw is
    sometimes close to even and often has a clear leader, which is exactly
    "an uneven spread, often a clear leader, sometimes a near-tie" without
    hand-tuning a shape for it.
    """
    weights = [rng.expovariate(1.0) for _ in range(options_count)]
    return rng.choices(range(options_count), weights=weights, k=voter_count)


def _vote(ctx, poll, option):
    return seed_backoff.call_with_backoff(
        lambda: ctx.api.call(
            "PUT", f"/messages/{poll['id']}/polls/vote", {"option": option}))


def _vote_on_poll(contexts, rng, stats, failures, state, poll):
    """A full vote round on one poll: not every poll gets one at all (see
    SETTLE_POLL_VOTE_COVERAGE), and the poll's own author may be among the
    voters - unlike reacting to one's own message, voting on one's own poll
    is ordinary behaviour and is not excluded here."""
    if rng.random() >= SETTLE_POLL_VOTE_COVERAGE:
        return
    already_voted = state.poll_voters(poll["id"])
    pool = [c for c in contexts if c.username not in already_voted]
    if not pool:
        return
    voter_count = min(_weighted_choice(rng, _POLL_VOTER_COUNT_WEIGHTS), len(pool))
    voters = rng.sample(pool, k=voter_count)
    plan = _poll_vote_plan(rng, poll["options_count"], voter_count)
    for ctx, option in zip(voters, plan):
        ok, _result = _try(failures, ctx, "settle_vote_poll",
                            lambda ctx=ctx, option=option: _vote(ctx, poll, option))
        if ok:
            stats["settle_vote_poll"] += 1
            state.record_poll_vote(poll["id"], ctx.username)


def _try(failures, ctx, action_name, action):
    """Runs `action`, recording rather than raising on failure - the same
    best-effort contract `seed_worker.run_account` gives every other action.

    Returns `(True, result)` on success and `(False, None)` on failure, so a
    caller that needs the created row (a reply's own id, to react to it in
    turn) can get it without a second `try`/`except` of its own.
    """
    try:
        return True, action()
    # a dropped action is reported, never silent
    except Exception as exc:  # noqa: BLE001
        failures.append((ctx.username, action_name, seed_backoff.describe_error(exc)))
        return False, None


def _react_to(contexts, rng, stats, failures, reacted_ids, target):
    """A whole reaction plan against `target` - several emoji, several
    reactors each - folded into `stats`/`reacted_ids` on success.

    Called a second time for each reply the pass itself just created:
    that reply is now part of the newest slice too, starts exactly as bare
    as the problem this pass exists to fix, and would quietly undo the
    coverage just built if it got no chance at a reaction of its own.
    """
    if rng.random() >= SETTLE_REACT_COVERAGE:
        return
    pool = [c for c in contexts if c.username != target["author"]] or contexts
    for emoji, reactor_count in _reaction_plan(rng, len(pool)):
        for ctx in rng.sample(pool, k=reactor_count):
            ok, _result = _try(failures, ctx, "settle_react",
                                lambda ctx=ctx, emoji=emoji: _react(ctx, target, emoji))
            if ok:
                stats["settle_react"] += 1
                reacted_ids.add(target["id"])


def _open_new_threads(contexts, rng, stats, failures, state, targets):
    """Opens a fresh thread on a random sample of `targets`, each with a
    3-to-8-reply side conversation - the fix for threads that existed but
    were never near enough the tail's own message ids to be visible there;
    see the module doc comment."""
    for target in rng.sample(targets, k=min(SETTLE_NEW_THREADS, len(targets))):
        ctx = _actor(contexts, rng, target["author"])
        ok, thread = _try(failures, ctx, "settle_open_thread",
                           lambda ctx=ctx, target=target: _open_thread(ctx, target))
        if not ok:
            continue
        stats["settle_open_thread"] += 1
        state.add_thread(target["id"], thread["id"])
        for _ in range(rng.randint(*SETTLE_NEW_THREAD_REPLIES)):
            reply_ctx = _actor(contexts, rng)
            ok, _result = _try(
                failures, reply_ctx, "settle_reply_in_thread",
                lambda reply_ctx=reply_ctx, thread=thread:
                    _reply_in_thread(reply_ctx, rng, thread["id"]))
            if ok:
                stats["settle_reply_in_thread"] += 1


def run(contexts, state, rng):
    """Runs the settle pass; returns `(stats, failures)`, `run_account`'s shape.

    `stats` also carries `settle_coverage_hits`/`settle_coverage_targets`,
    which the run report reads to print the fraction of the newest messages
    that actually ended up with a reaction.
    """
    stats = collections.Counter()
    failures = []
    reacted_ids = set()

    targets = state.newest_top_messages(SETTLE_TARGET_MESSAGES)
    created_replies = []
    for target in targets:
        _react_to(contexts, rng, stats, failures, reacted_ids, target)
        if rng.random() < SETTLE_REPLY_COVERAGE:
            ctx = _actor(contexts, rng, target["author"])
            ok, msg = _try(failures, ctx, "settle_reply", lambda ctx=ctx, target=target: _reply(ctx, rng, target))
            if ok:
                stats["settle_reply"] += 1
                created_replies.append(
                    {"id": msg["id"], "channel_id": target["channel_id"],
                     "author": ctx.username})

    # See _react_to's own doc comment for why this second pass exists.
    for reply_target in created_replies:
        _react_to(contexts, rng, stats, failures, reacted_ids, reply_target)

    _open_new_threads(contexts, rng, stats, failures, state, targets)

    for _parent_id, thread_channel_id in state.newest_threads(SETTLE_THREAD_TARGETS):
        for _ in range(rng.randint(*SETTLE_THREAD_REPLIES)):
            ctx = _actor(contexts, rng)
            ok, _result = _try(
                failures, ctx, "settle_reply_in_thread",
                lambda ctx=ctx, channel=thread_channel_id: _reply_in_thread(ctx, rng, channel))
            if ok:
                stats["settle_reply_in_thread"] += 1

    for poll in state.newest_polls(SETTLE_POLL_TARGETS):
        _vote_on_poll(contexts, rng, stats, failures, state, poll)

    stats["settle_coverage_hits"] = len(reacted_ids)
    stats["settle_coverage_targets"] = len(targets) + len(created_replies)
    return stats, failures
