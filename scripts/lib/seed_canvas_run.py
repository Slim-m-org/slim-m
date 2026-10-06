# SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
"""Orchestrates a canvas seeding run end to end: accounts, a channel, a
clustered mix of strokes and images, real op-stream history (moves,
resizes, reorders, removes and restores), a handful of edge-case probes,
and a readback through both canvas routes to prove it all stuck.

Mirrors seed_run.py's shape (guard, accounts, channel, act, report) for the
messaging seeder, but the canvas surface is two routes rather than a dozen,
so acting is a plain sequential pass instead of a worker pool - nothing
here needs concurrency to look like real use, and sequential is far easier
to reason about when a step fails.
"""
import datetime
import os
import random
import secrets
import sys
import tempfile
import urllib.error

import seed_accounts
import seed_canvas_content as content
import seed_canvas_diagram as diagram
import seed_canvas_geometry as geom
import seed_canvas_history as history
import seed_canvas_images
import seed_canvas_layout as layout
import seed_canvas_ops as ops
import seed_canvas_probes as probes
import seed_credentials
import seed_guard
import uuid7

# The server's page clamp and its CANVAS_OP_GAP (store/canvas_ops.rs).
_PAGE = 200
_OP_GAP = 2000


def run(args):
    try:
        base_url = seed_guard.guard(
            args.base_url, os.environ.get("SLIM_SEED_BASE_URL"),
            args.confirm, args.i_know_this_is_production)
    except seed_guard.GuardError as exc:
        sys.exit(f"refusing to run: {exc}")

    if args.accounts < 2:
        sys.exit("refusing to run: --accounts must be at least 2, so a "
                  "moderation-gated action has someone else's object to "
                  "act on")
    if args.image_ratio + args.note_ratio + args.shape_ratio > 1.0:
        sys.exit("refusing to run: --image-ratio, --note-ratio and "
                  "--shape-ratio together exceed 1.0, leaving no room "
                  "for strokes")

    password = args.password or seed_credentials.load_or_create(base_url)
    username_tag = args.username_tag if args.username_tag is not None else ""

    try:
        invite_code, explicit_admin_api = seed_accounts.obtain_invite_code(
            base_url, args.accounts, args.invite_code,
            args.admin_username, args.admin_password, "canvas-seed")
        accounts = seed_accounts.register_accounts(
            base_url, args.accounts, password, invite_code, "canvas-seed",
            username_tag=username_tag)
        channel_name = (args.channel_name
                         or f"canvas-{datetime.date.today().isoformat()}")
        channel = seed_accounts.create_seed_channel(
            accounts, explicit_admin_api, channel_name)
    except seed_accounts.AccountSetupError as exc:
        sys.exit(f"refusing to continue: {exc}")

    api_by_index = [a["api"] for a in accounts]
    admin_candidate = explicit_admin_api or api_by_index[0]
    channel_id = channel["id"]
    base_seed = args.seed if args.seed is not None else secrets.randbits(32)
    rng = random.Random(base_seed)

    with tempfile.TemporaryDirectory(prefix="slimm-canvas-seed-") as scratch:
        report = _seed(admin_candidate, api_by_index, channel_id, args, rng,
                        scratch)

    _print_report(base_url, channel, channel_name, accounts, password, report)
    return 0


def _seed(admin_candidate, api_by_index, channel_id, args, rng, scratch):
    warnings = []
    throwaway, admin_api = _run_throwaway_batch(
        admin_candidate, channel_id, rng, warnings)

    images = seed_canvas_images.build(scratch, rng)
    uploaded = content.upload_images(api_by_index, images)

    centers = layout.cluster_centers(rng, args.clusters)
    weights = layout.cluster_weights(rng, args.clusters)
    placed, counts = content.place_main_pass(
        api_by_index, channel_id, centers, weights, uploaded, args.objects,
        args.image_ratio, args.note_ratio, args.shape_ratio, rng)
    extra, did_split = content.place_oversized_stroke(
        api_by_index[0], channel_id, 0, centers, weights, rng)
    placed += extra
    if did_split:
        counts["split_stroke_events"] += 1

    history_stats, removed_ops, restored_ops = history.run(
        api_by_index, admin_api, channel_id, placed, rng)

    # Placed after history, and never handed to it, so it stays exactly as drawn - see its own module doc.
    diagram_placed = diagram.run(api_by_index, channel_id, centers, weights,
                                  placed, rng)

    probe_target = _place_probe_target(api_by_index[0], channel_id, rng)
    member_api = _pick_member_api(api_by_index, admin_api)
    findings = probes.run(admin_api or api_by_index[0], member_api,
                           channel_id, probe_target)

    readback, ops_readback = _readback(
        api_by_index[0], channel_id, placed + diagram_placed, centers)

    return {
        "warnings": warnings, "throwaway": throwaway, "uploaded": len(uploaded),
        "placed_total": len(placed), "counts": counts, "history": history_stats,
        "removed_ops": len(removed_ops), "restored_ops": len(restored_ops),
        "diagram_placed": len(diagram_placed), "findings": findings,
        "readback": readback, "ops_readback": ops_readback,
    }


def _run_throwaway_batch(admin_candidate, channel_id, rng, warnings):
    def place_throwaway():
        points = geom.freehand_stroke(rng, (50, 50), steps=12)
        placement = geom.stroke_placements(
            points, 2.0, "annotation", uuid7.uuid7)[0]
        return ops.place_object(admin_candidate, channel_id, placement)

    try:
        return (history.run_throwaway_batch(admin_candidate, channel_id, 8,
                                             place_throwaway),
                admin_candidate)
    except urllib.error.HTTPError as exc:
        if exc.code != 403:
            raise
        warnings.append(
            "the presumed admin account has no MANAGE_CANVAS; skipped the "
            "clear demo and every moderation-gated history action")
        return None, None


def _place_probe_target(api, channel_id, rng):
    """A fresh object placed after every other pass, so it is guaranteed
    untouched by history and safe for the replay probe to reuse."""
    points = geom.freehand_stroke(rng, (0, 0), steps=10)
    placement = geom.stroke_placements(points, 2.0, "annotation", uuid7.uuid7)[0]
    return ops.place_object(api, channel_id, placement)


def _pick_member_api(api_by_index, admin_api):
    if admin_api is None:
        return api_by_index[1] if len(api_by_index) > 1 else api_by_index[0]
    return next((api for api in api_by_index if api is not admin_api),
                api_by_index[0])


def _readback(api, channel_id, placed, centers):
    all_x = [p["x"] for p in placed] + [c[0] for c in centers]
    all_y = [p["y"] for p in placed] + [c[1] for c in centers]
    pad = 1500
    rect = (min(all_x) - pad, min(all_y) - pad, max(all_x) + pad, max(all_y) + pad)
    viewport = ops.viewport(api, channel_id, rect, limit=2000)
    return (
        {"objects": len(viewport["objects"]), "has_more": viewport["has_more"],
         "latest_seq": viewport["latest_seq"]},
        _ops_readback(api, channel_id),
    )


def _ops_readback(api, channel_id):
    """Every op the server will still replay, paged to the end.

    A cursor more than `_OP_GAP` behind gets `reset` and no ops, so a long
    stream is read from the oldest cursor the server accepts, and says so.
    """
    start = 0
    page = ops.ops_page(api, channel_id, after_seq=start, limit=_PAGE)
    if page["reset"]:
        start = max(0, page["latest_seq"] - _OP_GAP)
        page = ops.ops_page(api, channel_id, after_seq=start, limit=_PAGE)
    collected = []
    while not page["reset"]:
        collected.extend(page["ops"])
        if not (page["has_more"] and page["ops"]):
            break
        page = ops.ops_page(api, channel_id, after_seq=collected[-1]["seq"],
                            limit=_PAGE)
    return {"count": len(collected), "latest_seq": page["latest_seq"],
            "by_kind": _count_kinds(collected), "from_seq": start,
            "reset": page["reset"]}


def _count_kinds(op_list):
    counts = {}
    for op in op_list:
        counts[op["kind"]] = counts.get(op["kind"], 0) + 1
    return counts


def _print_report(base_url, channel, channel_name, accounts, password, report):
    print(f"seeded canvas on {base_url}")
    print(f"channel: {channel_name!r} ({channel['id']})")
    print(f"accounts ({len(accounts)}): "
          f"{', '.join(a['username'] for a in accounts)}")
    print(f"shared password: {password}")
    for warning in report["warnings"]:
        print(f"note: {warning}")
    if report["throwaway"]:
        t = report["throwaway"]
        print(f"throwaway batch: placed {t['placed']}, "
              f"cleared, restored {t['restore']['affected']}, "
              f"re-removed {t['remove']['affected']}")
    counts = report["counts"]
    print(f"uploaded {report['uploaded']} unique image attachments")
    print(f"placed {report['placed_total']} objects total: "
          f"{counts['strokes']} stroke actions, {counts['images']} images, "
          f"{counts['notes']} notes, {counts['shapes']} shapes "
          f"({counts['split_stroke_events']} strokes needed byte-budget "
          "splitting into more than one object)")
    print(f"composed a deliberate diagram: {report['diagram_placed']} "
          "objects (a box around the busiest cluster, an arrow to a "
          "callout note, a divider line, and 3 notes from a two-word "
          "label up to one near the client's own length ceiling)")
    h = report["history"]
    print(f"history: {h['moved']} moved ({h['resized']} also resized), "
          f"{h['reordered']} reordered, {h['removed']} objects removed "
          f"across {report['removed_ops']} ops, {h['restored']} objects "
          f"restored across {report['restored_ops']} ops, {h['forbidden']} "
          "moderation-only attempts came back 403 (accepted, not fatal)")
    r = report["readback"]
    print(f"viewport readback: {r['objects']} objects, "
          f"has_more={r['has_more']}, latest_seq={r['latest_seq']}")
    o = report["ops_readback"]
    window = ("" if o["from_seq"] == 0
              else f" (only after seq {o['from_seq']}, the server's replay "
                   "window)")
    print(f"ops feed readback: {o['count']} ops{window}, "
          f"latest_seq={o['latest_seq']}, by kind: {o['by_kind']}")
    if o["reset"]:
        print("note: the server answered the ops feed with reset, so no ops "
              "could be read back")
    print("probes:")
    for finding in report["findings"]:
        mark = "ok" if finding["ok"] else "UNEXPECTED"
        print(f"  [{mark}] {finding['name']}: expected {finding['expected']}, "
              f"got {finding['actual']} - {finding['detail']}")
