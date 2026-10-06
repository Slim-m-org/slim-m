# SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
"""The op-stream history pass: move, resize, reorder, remove and restore.

Run after the main placement pass so the canvas ships with real history
rather than an op feed that is entirely `place` - the task this seeder
exists for names move/resize/reorder/remove/restore explicitly as the paths
worth exercising, since those are what a client's undo and reconciliation
code actually has to handle.

A `move` request also carries `w`/`h`, so a resize rides the same op kind
`_run_moves` already calls; there is no separate resize verb to test.
"""
import urllib.error

import uuid7

import seed_canvas_layout as layout
import seed_canvas_ops as ops

# Chance an action routes through admin_api, to exercise MANAGE_CANVAS.
_MODERATION_CHANCE = 0.15


def run_throwaway_batch(admin_api, channel_id, count, place_fn):
    """Places `count` small placeholder strokes, clears them, restores the
    clear, then removes the same objects again individually - a genuine
    `clear` and a genuine `restore` in the op feed, without leaving
    placeholder art on the final canvas. All three ops are authored by
    `admin_api`, since `clear` needs MANAGE_CANVAS unconditionally. A refused
    clear removes the placeholders itself, which needs no such permission."""
    placed = [place_fn() for _ in range(count)]
    before_seq = placed[-1]["seq"]
    try:
        clear_op = ops.clear(
            admin_api, channel_id, uuid7.uuid7(), before_seq)["op"]
    except urllib.error.HTTPError as exc:
        if exc.code == 403:
            ops.remove(admin_api, channel_id, uuid7.uuid7(),
                       [p["id"] for p in placed])
        raise
    restore_op = ops.restore(
        admin_api, channel_id, uuid7.uuid7(), clear_op["id"])["op"]
    remove_op = ops.remove(
        admin_api, channel_id, uuid7.uuid7(), [p["id"] for p in placed])["op"]
    return {"placed": len(placed), "clear": clear_op, "restore": restore_op,
            "remove": remove_op}


def run(api_by_index, admin_api, channel_id, placed, rng):
    """Moves, resizes, reorders, removes and restores a sample of `placed`.

    `placed` is every object the main pass created, each a dict carrying
    its own `author_index` into `api_by_index`. `admin_api` (`None` if this
    account turned out not to hold MANAGE_CANVAS) is used for a minority of
    actions to exercise the moderation path; a 403 there is counted in
    `stats["forbidden"]` rather than failing the run.
    """
    stats = {"moved": 0, "resized": 0, "reordered": 0, "removed": 0,
              "restored": 0, "forbidden": 0}
    remaining = list(placed)
    rng.shuffle(remaining)

    move_count = max(1, len(remaining) // 8)
    movable, remaining = remaining[:move_count], remaining[move_count:]
    _run_moves(api_by_index, admin_api, channel_id, movable, rng, stats)

    reorder_count = min(10, max(1, len(remaining) // 15))
    reorderable, remaining = remaining[:reorder_count], remaining[reorder_count:]
    max_z = max((p["z_index"] for p in placed), default=0)
    _run_reorders(api_by_index, admin_api, channel_id, reorderable, rng,
                  stats, max_z)

    remove_count = max(3, len(remaining) // 6)
    candidates = remaining[:remove_count]
    removed_ops, restored_ops = _run_removes_and_restores(
        api_by_index, admin_api, channel_id, candidates, rng, stats)
    return stats, removed_ops, restored_ops


def _actor_api(rng, api_by_index, admin_api, target):
    if admin_api is not None and rng.random() < _MODERATION_CHANCE:
        return admin_api
    return api_by_index[target["author_index"]]


def _run_moves(api_by_index, admin_api, channel_id, targets, rng, stats):
    for target in targets:
        api = _actor_api(rng, api_by_index, admin_api, target)
        new_x, new_y = layout.sample_position(
            rng, [(target["x"], target["y"])], [1], sigma_range=(200, 600),
            stray_chance=0.0)
        w, h = target["w"], target["h"]
        resized = rng.random() < 0.4
        if resized:
            scale = layout.pick_image_scale(rng)
            w, h = round(w * scale, 2), round(h * scale, 2)
        try:
            ops.move(api, channel_id, uuid7.uuid7(), target["id"],
                     round(new_x, 2), round(new_y, 2), w, h)
        except urllib.error.HTTPError as exc:
            if exc.code != 403:
                raise
            stats["forbidden"] += 1
            continue
        stats["moved"] += 1
        if resized:
            stats["resized"] += 1


def _run_reorders(api_by_index, admin_api, channel_id, targets, rng, stats,
                   max_z):
    for index, target in enumerate(targets):
        api = _actor_api(rng, api_by_index, admin_api, target)
        # one deliberately negative index, since any integer is legal here.
        z_index = -1000 - index if index == 0 else max_z + 10 + index
        try:
            ops.reorder(api, channel_id, uuid7.uuid7(), target["id"], z_index)
        except urllib.error.HTTPError as exc:
            if exc.code != 403:
                raise
            stats["forbidden"] += 1
            continue
        stats["reordered"] += 1


def _try_remove(api, channel_id, object_ids, stats):
    try:
        result = ops.remove(api, channel_id, uuid7.uuid7(), object_ids)
    except urllib.error.HTTPError as exc:
        if exc.code != 403:
            raise
        stats["forbidden"] += 1
        return None
    stats["removed"] += result["op"]["affected"]
    return result["op"]


def _try_restore(api, channel_id, target_op, stats):
    try:
        result = ops.restore(api, channel_id, uuid7.uuid7(), target_op)
    except urllib.error.HTTPError as exc:
        if exc.code != 403:
            raise
        stats["forbidden"] += 1
        return None
    stats["restored"] += result["op"]["affected"]
    return result["op"]


def _run_removes_and_restores(api_by_index, admin_api, channel_id,
                               candidates, rng, stats):
    """A third of `candidates` removed one at a time by their own author, a
    third removed together in one batch op, and - if `admin_api` is
    available - up to three removed by the admin account acting on
    another author's object, left un-restored as a permanent moderation
    act. Every other individually-removed object is then restored, one of
    those restores routed through the admin account on a member-authored
    op specifically to exercise restore's MANAGE_CANVAS gate."""
    if not candidates:
        return [], []
    third = max(1, len(candidates) // 3)
    solo = candidates[:third]
    batch = candidates[third:third * 2]
    moderated = candidates[third * 2:third * 2 + 3] if admin_api else []

    remove_ops = []
    for target in solo:
        author_api = api_by_index[target["author_index"]]
        op = _try_remove(author_api, channel_id, [target["id"]], stats)
        if op:
            remove_ops.append((op["id"], author_api))

    if batch:
        author_api = api_by_index[batch[0]["author_index"]]
        op = _try_remove(author_api, channel_id,
                          [t["id"] for t in batch], stats)
        if op:
            remove_ops.append((op["id"], author_api))

    for target in moderated:
        _try_remove(admin_api, channel_id, [target["id"]], stats)

    restored = []
    for index, (op_id, author_api) in enumerate(remove_ops):
        if index % 2:
            continue
        actor = admin_api if admin_api and index % 6 == 0 else author_api
        if _try_restore(actor, channel_id, op_id, stats):
            restored.append(op_id)
    return [op_id for op_id, _ in remove_ops], restored
