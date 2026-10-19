<!-- SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0 -->
# 0073 - The canvas is one shared board

Status: accepted
Date: 2026-10-18

## The ask

The owner asked: "All views should look the same between users no matter the aspect ratio between devices or resolution for now."
They also asked for follow and "bring everyone to me", a pen that is the same thickness on the drawer's screen at any zoom, and handles that a finger can grab.

## Decision

The canvas has one fixed frame in world units, the board.
It is 1920 by 1080, so 16:9, with its top-left at the world origin.
Every viewer fits the whole board to their screen and letterboxes whatever does not fill the other axis.
A phone at 390 wide, a 1280 laptop and a 2560 monitor therefore show the same content at the same relative position.

- The camera is held over the board.
  The lowest zoom is the fit, so nobody can zoom out past it or pan off a fitted board.
- A viewer can zoom in temporarily for drawing detail, up to the old maximum.
  The pan is then clamped so the view never leaves the board.
  The zoom chip reads 100% at the fit, and tapping it (or Follow) brings the view back.
- Opening a canvas always fits the board.
  The remembered per-channel camera is gone: with a fixed frame and only temporary zoom there is nothing worth restoring.
  A personal view toggle is a separate backlog card, and the memory returns with it.
- A press that starts a mark outside the board is ignored, and ink dragged past the edge is clamped to it.
  Objects that older canvases hold outside the frame stay in the store and are not shown to anyone by default.
- Tiles keep their positions in world units.
  The default tile layout wraps at the board width, not the viewer's window, so untouched tiles land in the same place for everyone.

## Follow and bring everyone

A member's view is the part of the board they see, as a world rectangle.
It is relayed on the ephemeral websocket path as `canvas.view` and fanned out as `canvas.view.updated`, gated like a cursor (view plus `USE_CANVAS`), rate-limited with the cursor budget, never stored.
Whoever has not moved shows the whole board, so a member with no frame yet is followed as the whole board.

- Tapping a person (the follow strip, or their cursor) follows them: the follower fits the leader's rectangle inside their own screen and keeps their own aspect, so a different shape sees extra board rather than a crop.
- "Bring everyone to me" sends the same frame with `summon` set.
  Anyone may use it.
  Receivers jump once and stay free, so they can leave at once.
- Following stops on the follower's own pan or zoom, or when the person is tapped again.
  A window resize only refits.

## Pen thickness

Thin, Medium and Thick are screen pixels on the drawer's screen.
A stroke is stored with width = pixels / zoom at draw time, so every viewer still agrees on the geometry.
The draft is painted at the pixel width, so it matches what lands.
The pen button shows the armed colour and thickness as a sample.

## Touch

Selection handles are drawn larger on touch (18 px, still screen-constant), the resize hit radius stays 22 px, and stroke and box hit slop are a screen distance (4 px, 12 px on touch) divided by zoom.

## What this supersedes

- [0010](0010-canvas-media-tiles.md): the default tile arrangement is computed in world units on the board, not from the viewer's window; the shared, persistent placement itself stands.
- [0017](0017-unified-canvas-items-and-context-menu.md): nothing in the item model changes; "a bounded large world" is narrowed to the board for placing new marks.

## What is left

- A personal view toggle (free pan and zoom) and the restored camera that goes with it.
- Tiles and content past the board edge: see [0080](0080-board-containment.md).
