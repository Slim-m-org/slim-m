<!-- SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0 -->
# 0085 - Clear versus locks, erased canvas content, and paging a big board

Status: accepted
Date: 2026-10-21

## The ask

The owner's answers after the full canvas audit:

- Clear canvas removes every unlocked object.
  A second clear, when only locked objects remain, removes those too.
  A scoped clear follows the same rule.
- Moderators can purge an image or object for good, and erased content (op rows, object rows, image bytes) is hard-deleted after the space's message retention window.
  Nothing is deleted when retention is off.
- On a big board the first read loads the visible area first, then pages in the rest, so every viewer converges on the same board.

## Clear and locks

A `clear` (or `clear_scoped`) first takes the unlocked objects under its fence and scope.
If none match, it takes the locked ones, so a second clear empties the board.

A replay folds a clear as a fence, so it has to know what the clear left standing.
The op's `canvas_op_targets` rows name the locked objects it spared, and the feed and the live frame carry them as `spared_ids`.
A clear that spared something is served as `clear_scoped` (feed kind and `canvas.cleared_scoped` frame), never as `clear`: a client that predates this treats an unknown kind as a resync, where a plain `clear` would have removed the locked objects.
The frame names at most 64 ids; `spared_count` is the true total and a receiver seeing fewer ids than the count refetches, the same fallback `canvas.objects.restored` uses.

A clear stores how many objects it removed (migration 0144, `canvas_ops.affected`), so a retried request reports what the original did even after an undo.
Restoring a locked object brings its lock back with it, so the server publishes `canvas.object.lock_changed` for each restored object that is locked.

## Erased content

A moderator removes one object for good with `DELETE /channels/{id}/canvas/objects/{object_id}` (`MANAGE_CANVAS`).
A live object is unlocked and erased first so every viewer drops it, then its rows are deleted.

The sweep also deletes objects erased longer ago than the space's message retention window, with their op rows, targets, audit rows, lock and attachment link.
The attachment sweep then frees the image bytes once nothing else references them.
With retention off nothing is deleted.

Deleting ops leaves a gap a cursor part-way through it cannot replay across, the same hazard compacting `remove` and `restore` pairs has.
The sweep keeps a pair a `clear` separates, and every delete raises a per-channel watermark (a `canvas_swept` row in `channel_seq_counters`).
`GET .../canvas/ops` answers `reset` to a cursor above 0 and below the watermark.

## Paging a big board

`GET .../canvas/objects` takes `cursor_seq`: it pages the region by canvas `seq`, oldest first, answering `next_cursor` and `total_objects`.
A client draws the visible area from one ordinary read, then pages the whole board in the background and merges by object id.
Objects placed, moved or removed meanwhile arrive through the op stream, so every viewer converges.
A read of any kind also stops at about 900 KiB of response with `has_more` true.

## Not done

- The client work (visible-area-first load, the "loaded / total" indicator, the purge menu item, honouring `spared_ids`) is batch 2.
- Moving `props` to a side table to cut the write cost of a huge clear is not done; hold time is unchanged.

## Addendum 2026-10-21: one Delete, always for good

The owner's decision after testing the batch: the canvas object menu has a single "Delete", and it always deletes for good.
There is no soft delete and no "Delete for good" beside it.

`DELETE /channels/{id}/canvas/objects/{object_id}` is that Delete.
It needs `VIEW_CHANNEL` and `USE_CANVAS`, and either being the object's author or holding `MANAGE_CANVAS`.
A moderator's delete also unlocks a locked object first; an author unlocks their own object first (409 otherwise).
The reply is the object's last row, so the client can undo: it places the same row again for as long as the session lasts.
Other viewers drop the object through the erase frame the route publishes before the rows go.
The eraser still removes ink and shapes with ordinary `remove` ops, which the retention sweep above handles.
