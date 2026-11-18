<!-- SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0 -->
# 0127 - A member who cannot draw spectates the canvas

Status: accepted, 2026-11-18.

## The ask

The owner, reviewing the canvas a member without the canvas permission saw (an empty board under "The canvas is not available in this channel."), 2026-11-18: "i dont like the read only scenario, they should just be put into the canvas like normal but no ability to modify the canvas, but can spectate, perhaps they should still have access to personal canvas? and readonly on shared canvas?"

Until now `USE_CANVAS` meant "view *and* draw" in one bit, so withholding it hid the canvas outright: every read route returned 403 and no live canvas frame was delivered.

## Decision

Watching a canvas needs only `VIEW_CHANNEL`; drawing needs `USE_CANVAS` as before.

- The four reads (`GET .../canvas/objects`, `.../canvas/ops`, `.../canvas/object-locks`, `.../canvas/media-slots`) gate on `VIEW_CHANNEL` alone.
- Every canvas live frame reaches whoever can see the channel, so a spectator watches ink, previews, cursors, tile drags and summons as they happen.
- Sending is unchanged: every write route and every canvas frame a client sends (cursor, previews, view, summon, screen marks) still needs `USE_CANVAS`, so a spectator's pointer is not relayed and they cannot summon anyone.
- The client treats a member whose channel permissions hold `VIEW_CHANNEL` without `USE_CANVAS` as a spectator: the canvas opens as for anyone else, with no tool strip, no undo, no object menu or tool wheel, and only the overflow items that change their own view.
  The tool stays Move, and a drag only moves the camera.
- The personal view (0082) stays theirs: they can switch to it, move and zoom, and place call tiles for themselves.
  In the shared view a call tile cannot be dragged or locked, since that arrangement is shared.
- A DM block still removes `USE_CANVAS`, so a blocked party now keeps a read-only canvas, the same as the message history a block leaves readable.

## Not changed

- A timed-out member keeps `USE_CANVAS` (they may still erase their own ink) and keeps the timeout banner; they are not a spectator.
- An overwrite that denied `USE_CANVAS` to shut someone out of the canvas entirely now leaves them watching.
  Hiding a canvas from someone now means hiding the channel.
