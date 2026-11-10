#!/usr/bin/env python3
# SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
"""Fills a deployment with varied, realistic-looking chat activity.

Creates a channel named for today's date, then N accounts (default 10) that
by default are the *same* accounts a previous run against this deployment
already created (see "Repeat runs" below), acting in parallel: short and
long messages, emoji, markdown, real code functions across several
languages, links (video, article, image, repo), mentions, polls,
attachments, replies, threads, reactions, edits, deletes, and pins, picked
at random from a weighted set so the result reads like an uneven real
conversation rather than a uniform sample. Target selection for reactions
and threads is recency-weighted (see scripts/lib/seed_state.py) and a
settle pass at the end (scripts/lib/seed_settle.py) both guarantees a
message can carry several different emoji or one emoji from several
different reactors, and opens brand new, multi-reply threads on the newest
messages specifically - so the screenful anyone actually opens a channel to
look at is not the barest part of it. Drives plain REST, reusing
scripts/lib/e2e_api.py rather than a second HTTP client.

With --ollama, the chat itself is not drawn from pools of disconnected
lines: scripts/lib/seed_conversation.py asks the model for a handful of
whole, structured multi-speaker conversations - real participant names,
who replies to whom, which turn opens a side thread, who reacts with what -
in one call each, and scripts/lib/seed_replay.py sends the result turn by
turn. A conversation the model garbles past usefulness is dropped rather
than sent; --ollama absent, or every conversation unusable, falls all the
way back to the pooled-and-templated behaviour this script always had.

Repeat runs against the same deployment reuse the same accounts by default:
--username-tag is empty unless given (so a persona's username is the same,
e.g. seed-alan, every run) and the shared password is cached per deployment
under ~/.cache/slim-m-seed/ unless --password overrides it, so
register_accounts logs into an account that is already registered instead
of minting a fresh one. Pass --username-tag to get a separate, fresh cohort
alongside whatever already exists instead.

The server's attachment upload sniffs content type from the bytes it is
given, never from a filename or a declared Content-Type header; the allowed
set is crates/slimm-server/src/media/content_type.rs's ALLOWED_TYPES.
Nothing outside it can be attached at all: anything else gets a 400
"unsupported attachment type" regardless of extension.
scripts/lib/seed_media.py generates real, varied PNGs (wide, tall, small, a
medium "screenshot", and one near the default per-upload ceiling), one
genuinely structured PDF, a plain-text log, a real zip archive, and a real
PCM WAV tone - all stdlib-only, so always present - plus a short, genuinely
valid mp4 clip via ffmpeg's synthetic test source when ffmpeg is on PATH,
skipped with a printed reason rather than a failure when it is not. webm and ogg are not generated: ffmpeg can produce both, but one
real video and one real audio fixture already exercises those types
without doubling the generator surface for no visible difference in the
transcript. Large code and log-shaped reference content still mostly rides
message text as fenced code blocks too, which the server has no format
restriction on at all. Video beyond the one generated clip is still covered
by links (see scripts/lib/seed_links.py) rather than more generated files.

Two things it does not do. It cannot fabricate a message's timestamp - the
server stamps every write with its own clock - so a single run cannot force
a day-divider across a real midnight; run it again on a later day against
the same deployment for that. And cleanup is not its job: it prints every
account, the channel, and the shared password it created, so a person can
find and remove them by hand.

    python3 scripts/seed-data.py --base-url http://localhost:8080 --confirm

An already-claimed deployment (one that already has an admin account) needs
that admin's credentials, to create the channel and mint an invite if the
join policy requires one:

    python3 scripts/seed-data.py --base-url http://localhost:8080 --confirm \\
        --admin-username alice --admin-password ... --invite-code XYZ

Nothing here has a default target, and nothing writes without --confirm; see
scripts/lib/seed_guard.py for why, and for the extra flag the one documented
live deployment needs on top of that.
"""
import argparse
import os
import sys

sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), "lib"))

import seed_run  # noqa: E402


def _parse_args(argv):
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("--base-url", default=None,
                         help="the server to seed; no default, also readable "
                              "from SLIM_SEED_BASE_URL")
    parser.add_argument("--confirm", action="store_true",
                         help="required before anything is written")
    parser.add_argument("--i-know-this-is-production", action="store_true",
                         help="also required if the target is the documented "
                              "live deployment")
    parser.add_argument("--accounts", type=int, default=10,
                         help="how many accounts act in parallel (default 10)")
    parser.add_argument("--actions-per-account", type=int, default=40,
                         help="turns each account takes (default 40)")
    parser.add_argument("--concurrency", type=int, default=None,
                         help="how many accounts act at once; defaults to "
                              "the account count, lower it to throttle a run")
    parser.add_argument("--invite-code", default=None,
                         help="an existing invite code, if the join policy "
                              "requires one and no admin login is given")
    parser.add_argument("--admin-username", default=None,
                         help="an account with CREATE_INVITE and "
                              "MANAGE_CHANNELS, for an already-claimed "
                              "deployment")
    parser.add_argument("--admin-password", default=None)
    parser.add_argument("--password", default=None,
                         help="shared password for the seed accounts; "
                              "cached per deployment under "
                              "~/.cache/slim-m-seed/ if omitted, so a "
                              "repeat run can still log into the same "
                              "accounts")
    parser.add_argument("--channel-name", default=None,
                         help="defaults to today's date")
    parser.add_argument("--seed", type=int, default=None,
                         help="random seed, for a reproducible run")
    parser.add_argument("--username-tag", default=None,
                         help="namespaces seed account usernames; empty "
                              "(stable across runs, so a repeat run logs "
                              "into the same accounts) if omitted - pass a "
                              "value for a separate, fresh cohort alongside "
                              "whatever already exists")
    parser.add_argument("--ollama", action="store_true",
                         help="generate message content with a local Ollama "
                              "model instead of the canned templates; off "
                              "by default, and any failure here (unreachable, "
                              "missing model, a bad response) just falls "
                              "back to the canned content rather than "
                              "aborting the run")
    parser.add_argument("--ollama-model", default=None,
                         help="overrides the model asked of Ollama "
                              "(default qwen3:8b); has no effect without "
                              "--ollama")
    args = parser.parse_args(argv)
    if args.admin_username and not args.admin_password:
        parser.error("--admin-username needs --admin-password")
    return args


def main(argv=None):
    return seed_run.run(_parse_args(argv))


if __name__ == "__main__":
    sys.exit(main())
