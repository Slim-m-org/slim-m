#!/usr/bin/env python3
# SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
"""Fills a channel's Voice Canvas with realistic, reviewable content.

The canvas shipped strokes, an eraser, undo, clear, restore, pasted
images, move, resize and z-order with no way to put content on one except
by hand, one object at a time - which makes it nearly impossible to look
at a realistic canvas or review how any of that feels with real content on
it. This is a second, separate seeder from scripts/seed-data.py rather than
a flag on it: the canvas is a different API surface entirely (two routes,
geometric placements and an op stream, not conversational messages), reuses
almost none of the message seeder's per-turn action machinery, and creates
its own dedicated channel so canvas review content does not get mixed into
a channel meant for reading chat history.

A run places a clustered mix of hand-drawn-looking strokes (freehand
doodles, rough ellipses, wavy lines, zigzags and bounded scribbles - never
a straight two-point line, which reads as machine-made), varied real
images (reusing scripts/lib/seed_media.py's generators), and a scatter of
background notes and shapes around a handful of weighted cluster centers,
so the result has busy regions and empty space rather than a uniform
scatter. On top of that it composes one deliberate diagram - a box drawn
around the busiest cluster, an arrow to a callout note, a divider line,
and three notes at genuinely different lengths - so the board reads as
something somebody actually made rather than only a random scatter of
every object kind. It then exercises the op stream for real: a
clear-and-restore demo on a throwaway batch, plus moves, resizes,
reorders, removes and restores across the main content, some of them
routed through a second account to exercise MANAGE_CANVAS rather than only
the self-authored path. A handful of deliberate edge-case probes (an
oversized props payload, an over-extent placement, a restore aimed at the
wrong op kind, and others) round out the run as an integration check on
the canvas API itself, not just a content generator.

Long strokes are split by their *encoded byte size* against
`MAX_PROPS_BYTES`, the same way the client's own `splitStroke` works (see
client/packages/voice_canvas/lib/src/stroke_splitter.dart) - never by a point count, since a point's
encoded length varies from four characters to seventeen.

    python3 scripts/seed-canvas.py --base-url http://localhost:8080 --confirm

An already-claimed deployment needs an admin login the same way
seed-data.py does, to mint an invite and to authorize the clear/moderation
demos with real MANAGE_CANVAS rather than guessing at it:

    python3 scripts/seed-canvas.py --base-url http://localhost:8080 --confirm \\
        --admin-username alice --admin-password ... --invite-code XYZ

Nothing here has a default target, and nothing writes without --confirm;
see scripts/lib/seed_guard.py for why, and for the extra flag the one
documented live deployment needs on top of that.
"""
import argparse
import os
import sys

sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), "lib"))

import seed_canvas_run  # noqa: E402


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
    parser.add_argument("--accounts", type=int, default=3,
                         help="how many accounts author canvas content "
                              "(default 3, minimum 2 so a moderation-gated "
                              "action has someone else's object to act on)")
    parser.add_argument("--objects", type=int, default=220,
                         help="how many objects to place in the main pass, "
                              "before history operations run (default 220)")
    parser.add_argument("--image-ratio", type=float, default=0.28,
                         help="fraction of the main pass that is images "
                              "rather than strokes (default 0.28)")
    parser.add_argument("--note-ratio", type=float, default=0.06,
                         help="fraction of the main pass that is "
                              "background notes (default 0.06); the "
                              "deliberate diagram's own three notes are "
                              "on top of this")
    parser.add_argument("--shape-ratio", type=float, default=0.05,
                         help="fraction of the main pass that is "
                              "background shapes (default 0.05); the "
                              "deliberate diagram's own three shapes are "
                              "on top of this")
    parser.add_argument("--clusters", type=int, default=5,
                         help="how many weighted cluster centers to scatter "
                              "content around (default 5)")
    parser.add_argument("--invite-code", default=None,
                         help="an existing invite code, if the join policy "
                              "requires one and no admin login is given")
    parser.add_argument("--admin-username", default=None,
                         help="an account with CREATE_INVITE and "
                              "MANAGE_CHANNELS, for an already-claimed "
                              "deployment; also the account MANAGE_CANVAS "
                              "demos run as")
    parser.add_argument("--admin-password", default=None)
    parser.add_argument("--password", default=None,
                         help="shared password for the seed accounts; "
                              "cached per deployment under "
                              "~/.cache/slim-m-seed/ if omitted")
    parser.add_argument("--channel-name", default=None,
                         help="defaults to 'canvas-<today's date>'")
    parser.add_argument("--seed", type=int, default=None,
                         help="random seed, for a reproducible run")
    parser.add_argument("--username-tag", default=None,
                         help="namespaces seed account usernames; empty "
                              "(shared with scripts/seed-data.py's own "
                              "personas) if omitted")
    args = parser.parse_args(argv)
    if args.admin_username and not args.admin_password:
        parser.error("--admin-username needs --admin-password")
    return args


def main(argv=None):
    return seed_canvas_run.run(_parse_args(argv))


if __name__ == "__main__":
    sys.exit(main())
