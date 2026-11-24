# SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
"""Orchestrates a seeding run end to end.

Guards the target, sets up accounts and a channel, then lets every account
act in parallel (one thread each, one `Api`, one rate-limit bucket) until
each has spent its turn budget. Nothing here fabricates a timestamp: the
server stamps every write with its own clock, so a run cannot backdate
messages into earlier days to force a day-divider - see the module doc on
`seed-data.py` for what that means for a single run's history.

Any generated conversations split between two halves (`_split_conversation_
tail`): most run concurrently with the per-account utility workers, sharing
one pool so the two interleave in real time rather than reading as all
business first and all conversation second; a reserved tail then replays
strictly afterward, so the messages settle's own append lands after are
guaranteed conversation rather than left to whichever concurrent task
happened to still be posting when the interleaved phase ended - measured
against a real run, that race left the true newest messages mostly filler
regardless of how much conversation volume existed.
"""
import concurrent.futures
import datetime
import os
import random
import secrets
import sys
import tempfile

import seed_accounts
import seed_actions
import seed_conversation
import seed_credentials
import seed_fixtures
import seed_guard
import seed_ollama
import seed_ollama_pools
import seed_replay
import seed_settle
import seed_state
import seed_worker

_PACE_RANGE = (0.3, 1.5)


def _worker_accounts(accounts, admin_api, admin_username):
    """Seed accounts plus the admin, if one logged in, as its own worker."""
    workers = list(accounts)
    if admin_api is not None:
        workers.append({"username": admin_username, "api": admin_api})
    return workers


def _conversation_pace_range(turn_count, actions_per_account):
    """A per-conversation pace so this replay's own wall-clock duration
    roughly matches one utility worker's, whatever `turn_count` turned out
    to be and whatever `--actions-per-account` this run was given.

    Without this a short conversation finishes long before the utility
    loop does and goes quiet for the rest of the run, which is what let an
    earlier version's interleaving fail in practice: submitting both kinds
    of work to one pool only interleaves them while both are still
    running, and a conversation with fewer turns than a worker has actions
    reliably stops first.
    """
    target_seconds = actions_per_account * (sum(_PACE_RANGE) / 2)
    per_turn = max(target_seconds / max(turn_count, 1), 0.05)
    return (per_turn * 0.5, per_turn * 1.5)


# Share of conversations held back for the guaranteed tail; see below.
_TAIL_RESERVE_SHARE = 0.5


def _split_conversation_tail(conversations):
    """`(interleaved, tail)`: most conversations run concurrently with the
    utility loop for a genuinely mixed transcript throughout, and a
    reserved tail runs strictly afterward so the messages the settle pass's
    own append lands after are guaranteed conversation - not dependent on
    which concurrent task happened to still be posting last, which measured
    against a real run left the true newest messages still mostly filler.
    """
    conversation_list = list(conversations or ())
    if not conversation_list:
        return [], []
    reserve = min(len(conversation_list),
                  max(1, round(len(conversation_list) * _TAIL_RESERVE_SHARE)))
    split_at = len(conversation_list) - reserve
    return conversation_list[:split_at], conversation_list[split_at:]


def run(args):
    try:
        base_url = seed_guard.guard(
            args.base_url, os.environ.get("SLIM_SEED_BASE_URL"),
            args.confirm, args.i_know_this_is_production)
    except seed_guard.GuardError as exc:
        sys.exit(f"refusing to run: {exc}")

    if args.accounts < 1:
        sys.exit("refusing to run: --accounts must be at least 1")

    password = args.password or seed_credentials.load_or_create(base_url)
    # Empty by default: a stable username per persona, so a rerun logs in.
    username_tag = args.username_tag if args.username_tag is not None else ""

    try:
        invite_code, admin_api = seed_accounts.obtain_invite_code(
            base_url, args.accounts, args.invite_code,
            args.admin_username, args.admin_password, "seed")
        accounts = seed_accounts.register_accounts(
            base_url, args.accounts, password, invite_code, "seed",
            username_tag=username_tag)
        channel_name = args.channel_name or datetime.date.today().isoformat()
        channel = seed_accounts.create_seed_channel(
            accounts, admin_api, channel_name)
    except seed_accounts.AccountSetupError as exc:
        sys.exit(f"refusing to continue: {exc}")

    reused_count = sum(1 for a in accounts if a.get("reused"))
    workers = _worker_accounts(accounts, admin_api, args.admin_username)
    privileged_username = workers[-1]["username"] if admin_api else workers[0]["username"]
    usernames = [w["username"] for w in workers]
    concurrency = args.concurrency or len(workers)
    base_seed = args.seed if args.seed is not None else secrets.randbits(32)

    corpus = None
    conversations = None
    if args.ollama:
        model = args.ollama_model or seed_ollama.DEFAULT_MODEL
        corpus = seed_ollama_pools.load_or_generate(model, base_seed)
        # build_conversations reaches ollama, never the deployment itself.
        conversations = seed_conversation.build_conversations(
            model, accounts, base_seed,
            total_draws=len(workers) * args.actions_per_account)

    # See seed_actions.CONVERSATION_COVERED for what UTILITY_ACTIONS trims.
    action_set = seed_actions.UTILITY_ACTIONS if conversations else seed_actions.ACTIONS

    with tempfile.TemporaryDirectory(prefix="slimm-seed-") as scratch:
        fixtures = seed_fixtures.build(scratch, base_seed)
        state = seed_state.SeedState()
        contexts = [
            seed_worker.WorkerContext(
                api=worker["api"], username=worker["username"],
                channel_id=channel["id"], state=state,
                rng=random.Random(f"{base_seed}-{index}"),
                other_usernames=[u for u in usernames if u != worker["username"]],
                is_privileged=(worker["username"] == privileged_username),
                fixtures=fixtures, corpus=corpus)
            for index, worker in enumerate(workers)
        ]

        # See _split_conversation_tail's doc comment for the interleave/tail split.
        accounts_by_display = {a["display_name"]: a for a in accounts}
        interleaved, tail_conversations = _split_conversation_tail(conversations)

        results = []
        pool_size = concurrency + len(interleaved)
        with concurrent.futures.ThreadPoolExecutor(max_workers=pool_size) as pool:
            futures = [
                pool.submit(seed_worker.run_account, ctx,
                            args.actions_per_account, _PACE_RANGE, actions=action_set)
                for ctx in contexts
            ]
            futures += [
                pool.submit(
                    seed_replay.replay, conversation, accounts_by_display,
                    channel["id"], state,
                    random.Random(f"{base_seed}-conversation-replay-{index}"),
                    pace_range=_conversation_pace_range(
                        len(conversation.turns), args.actions_per_account))
                for index, conversation in enumerate(interleaved)
            ]
            for future in concurrent.futures.as_completed(futures):
                results.append(future.result())

        for index, conversation in enumerate(tail_conversations):
            results.append(seed_replay.replay(
                conversation, accounts_by_display, channel["id"], state,
                random.Random(f"{base_seed}-conversation-tail-{index}")))

        results.append(seed_settle.run(contexts, state, random.Random(f"{base_seed}-settle")))

    failures = _report(base_url, channel, channel_name, usernames, password, state, results,
                       corpus=corpus, conversations=conversations, reused_count=reused_count,
                       persona_count=len(accounts))
    return 1 if failures else 0


def _describe_corpus(corpus):
    """One line on whether ollama content was actually used, not just asked
    for - a run with `--ollama` and an unreachable server still succeeds, so
    the report is where that silence would otherwise go unnoticed."""
    if corpus is None:
        return "ollama content: not requested"
    if corpus.is_empty():
        return "ollama content: requested but unavailable, used canned content"
    return (f"ollama content: {len(corpus.short)} short, {len(corpus.long)} long, "
            f"{len(corpus.code)} code, {len(corpus.polls)} poll pool entries")


def _describe_conversations(conversations):
    """One line on whether a generated conversation replay actually ran -
    `None` when it never applied (no `--ollama`), distinct from `--ollama`
    running but producing nothing usable, the same distinction
    `_describe_corpus` already draws for the pooled corpus."""
    if conversations is None:
        return None
    if not conversations:
        return "generated conversations: none usable, ran the full action set instead"
    turn_count = sum(len(c.turns) for c in conversations)
    return f"generated conversations: {len(conversations)} ({turn_count} turns total)"


def _report(base_url, channel, channel_name, usernames, password, state, results,
            corpus=None, conversations=None, reused_count=0, persona_count=0):
    totals = {}
    failures = []
    for stats, worker_failures in results:
        for name, count in stats.items():
            totals[name] = totals.get(name, 0) + count
        failures.extend(worker_failures)

    coverage_hits = totals.pop("settle_coverage_hits", None)
    coverage_targets = totals.pop("settle_coverage_targets", None)

    print(f"seeded {base_url}")
    print(f"channel: {channel_name!r} ({channel['id']})")
    print(f"accounts ({len(usernames)}): {', '.join(usernames)}")
    if persona_count:
        print(f"  {reused_count} reused from a previous run, "
              f"{persona_count - reused_count} newly registered")
    print(f"shared password: {password}")
    print(_describe_corpus(corpus))
    conversations_line = _describe_conversations(conversations)
    if conversations_line:
        print(conversations_line)
    print(f"created: {state.counts()}")
    recency = state.recency_stats()
    if recency["rate"] is not None:
        print(f"target selection favoured recent messages/threads "
              f"{recency['rate']:.0%} of the time "
              f"({recency['from_recent_window']}/{recency['draws']} draws), "
              f"see seed_state.RECENCY_BIAS")
    if coverage_targets:
        print(f"settle pass: {coverage_hits}/{coverage_targets} of the newest "
              f"messages carry a reaction ({coverage_hits / coverage_targets:.0%})")
    print("actions performed:")
    for name in sorted(totals):
        print(f"  {name}: {totals[name]}")
    if failures:
        print(f"{len(failures)} actions failed after retrying and were skipped:")
        for username, action, reason in failures[:20]:
            print(f"  {username} / {action}: {reason}")
        if len(failures) > 20:
            print(f"  ... and {len(failures) - 20} more")
    return failures
