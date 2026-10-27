<!-- SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0 -->
# 0081 - Full screen on a canvas tile keeps the canvas

Status: accepted
Date: 2026-10-19
Amended by [0086](0086-avatar-tiles-leave-the-board.md): a phone rotates while a canvas tile is full screen.

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


## Addendum 2026-10-21 - full screen moves the camera, not the tile

The owner, testing the first build: the share was blown up to fill the window while the board and the other objects stayed at their camera, so ink drawn over it was stored at board scale and no longer lined up with the share once he left full screen.
The feed is no longer a separate layer sized to the pane.

- The tile stays a board object at its own world rect and its video paints in the backdrop like any other tile.
  Full screen fits the camera to that rect: aspect-fit, centred, above the dock, held to the board.
  The tile, the ink and everything around them scale together, and ink drawn while full screen is stored in world coordinates over the part of the share it was drawn on.
- It is a local view change.
  Nothing is sent, the shared or personal view is not switched, and it works from either ([0082](0082-personal-canvas-view.md)).
  The tile's own rect is read as this viewer sees it, so a personal place is the one that is fitted.
- The camera is refitted when the tile moves or resizes, the window changes size (a phone rotating included), or the dock's reserved height changes.
  A pan or zoom the viewer makes in full screen is left alone until one of those happens.
- Leaving (the dock's exit, Escape, the share ending) puts back the camera that was there before, once the chrome has returned and the viewport is the old size.
  A camera that was fitted to the board is fitted again rather than copied, so a different window size cannot strand it.
- The focused tile takes no drag or resize handles, so it cannot be moved from under the camera; its name label still sits over the video.
- The video is the same view widget at the size it is painted, so a share is subscribed at a resolution fit for the screen.


## Addendum 2026-10-27 - rules for full screen, following and summons

The owner agreed the v115 model is right and asked for the open edges to be written down.

- Others' ink and cursors over a full screen share always show.
  A person who does not want to see them uses their personal view ([0082](0082-personal-canvas-view.md)) or watches from the plain voice call, which has no canvas.
  There is no hide-ink toggle in full screen.
- Escape exits, and F toggles full screen for the tile that has keyboard focus (and exits when one is already full screen).
  Neither key acts while a text field has the keyboard.
- A screen reader hears "Full screen, <tile name>" on entering and "Exited full screen" on leaving.
- Full screen from the personal view exits back to the personal view.
  The fitted camera is never saved as the personal layout, including when the app closes while a tile is full screen.
- A second full screen request while one is open refits to the new tile.
- Following: when the person you follow has a tile full screen, you are put into full screen on the same tile, if you can see that share.
  When they leave full screen you leave too and keep following them.
  Stopping the follow leaves you where you are.
  The view frame carries the tile key (`tile`, optional) for this.
- A summon is a request, not a move.
  The receiver sees Accept and Decline, and an unanswered request lapses quietly after 30 seconds.
  On Accept a full screen receiver leaves full screen first, then moves to the summoner's view.
  Someone you already follow is not asked again, since you move with them anyway.
- The name chip over a full screen tile sits below the view and zoom pills, so it no longer overlaps them.
- Phones: full screen already folds the dock, tool row included, behind a handle, same as desktop.
  This stays; no separate phone rule.
- Not decided here: the camera stopping at maximum zoom on a small share, a tile at the board edge sitting off-centre, and a pinned dock refitting slightly smaller.
