<!-- SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0 -->
# 0081 - Full screen on a canvas tile keeps the canvas

Status: accepted
Date: 2026-10-19

## The ask

The owner, 2026-10-14: "when i fullscreen on someones screenshare id still like to see if someone draws something or puts an image on it, i want to maintain those controls in fullscreen, but maybe we make the dock collapsable with a half sphere with an up/down caret symbol ... it only appears if you move mouse towards bottom of screen".
[0010](0010-canvas-media-tiles.md) had the tile reuse the voice screen's fullscreen route, which covers the canvas.

## Decision

- Full screen on a canvas tile no longer opens a route.
  The feed fills the canvas pane under the ink, so drawings, images, notes and cursors stay on top, and the other tiles stay where they are.
  The pane goes fullscreen to give it room, and leaving (the dock's exit button, Escape, or the share ending) puts both back.
- Fullscreen keeps the dock's tools and call controls instead of folding them to one button.
  The dock tucks behind a half-sphere handle with a chevron.
  A pointer near the bottom edge reveals it, and a tap on the handle pins it open or folds it; the tap is the touch equivalent of the hover.
- Every tile stays subscribed while one is focused, because the others are still on screen.
- The OS window goes fullscreen while a tile is focused, as the old route did, through the shared `WindowFullscreenHold` that the fullscreen video route also uses.
  It is released on exit, Escape, the share ending, closing the canvas and dispose.
- At phone width the header that held undo, the overflow menu and the way out is gone in fullscreen, so they sit in the dock's tools card beside the tools.
- The dock reserves only the handle's height while folded, so snackbars sit where the screen is actually free.
- The window hold is counted, so a canvas tile and a call's fullscreen route sharing one window leave fullscreen only when the last of them lets go.
- A tile's menu has one Full screen row, the canvas's own.
  The participant rows on a canvas leave out the route's "Full screen" and "Camera full screen".

## What this gives up

[0058](0058-phone-landscape-for-full-screen-call-video.md) let a locked phone rotate for the fullscreen video route.
A focused canvas tile no longer opens that route, so a phone cannot rotate to give the feed the whole landscape width; it fills the portrait pane.
The shell's portrait layout is width-driven (`keepPortraitShell`), so rotating the canvas needs the pane to read the real window size, which is its own piece of work.
Until the owner decides whether to build it, rotating to watch a share full screen is the call's own fullscreen route, still reachable from the voice screen.

