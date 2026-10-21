<!-- SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0 -->
# 0080 - Nothing leaves the board

Status: accepted
Date: 2026-10-19

## The ask

The owner, on 0.114.0 desktop: "the scaling feature clearly did not work as now i have items on desktop reaching outside of the canvas and the fit to screen to allow for seeing everything goes outside of the canvas also".
[0073](0073-shared-canvas-board.md) fixed the frame but only the camera was held to it, so strokes and tiles still painted on the letterbox.

## Decision

- Everything board content paints is clipped to the board rect: committed ink, drafts, remote previews, shapes, notes, images, and the presence and camera tiles (front and sent-to-back).
  Objects wholly outside the board are also culled, so they cost nothing and cannot be hit.
- Placement, move, resize and tile drags are clamped to the board.
  A stroke is only translated, since its geometry cannot be resized; everything else is shrunk when larger than the board.
  The same clamp runs when a remote move, preview or tile rect is applied, so a stale client cannot push content out of anyone's view.
- The note editor slides inside the board instead of the window.
- Fit frames exactly the board: the fit zoom is the larger-axis fit of the 1920 by 1080 rect, and the clip makes the edge exact.

## Content that older canvases hold outside the board

Chosen: keep it, hide it for everyone, and say so.
A pill beside the zoom chip reads "N outside the board - bring in".
Bring in moves each object the viewer may move (their own, or any with `MANAGE_CANVAS`, and not locked) onto the board with the ordinary `move` op.

Why not a server normalisation: main deploys continuously, and a migration that rewrites every canvas would be irreversible on live data.
It would also have to scale strokes, which the move op cannot do, and would move other people's work without anyone asking.
The affordance loses nothing, every view stays identical because the clip is the same everywhere, each move is in the op log and undoable, and permissions are respected.

## Limits

- Only objects the client has fetched are counted; the viewport read does not reach far outside the board.
- A stroke larger than the board cannot be brought in; it stays clipped and is not counted.
- Cursors and selection handles are not clipped.
- The server does not refuse out-of-board ops, so an old client's op still lands in the log; every current client clamps or clips it.
