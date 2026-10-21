<!-- SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0 -->
# 0086 - Avatar tiles leave the board, the roster moves to the dock, and ink paints above tiles

Status: accepted
Date: 2026-10-20
Amends [0010](0010-canvas-media-tiles.md) and [0081](0081-canvas-tile-fullscreen-keeps-the-canvas.md).

## The ask

The owner, after the canvas audit: a person with no camera and no share should not take a tile on the board.
Speaking should show on the cursor label, and the call dock should list who is in the call.
Ink, live drafts and cursors should paint above tiles, and a personal camera should never reach anyone else.

## Decision

- A tile exists only for a live camera or a live screen share.
  Someone with neither has no tile, so the default arrangement, the server media slots and the video interest set all name feeds only.
  [0010](0010-canvas-media-tiles.md) gave every participant a standing tile; that part is withdrawn.
- Speaking shows as a glow on the speaker's cursor label on the board.
  Someone who has not moved a pointer has no cursor, and the dock roster below carries them.
- The call dock gets a compact roster of avatars: everyone in the call, a speaking ring, a muted or deafened badge.
  Left-click, tap, right-click and long-press open the same participant menu a call tile has (volume, mute for me, hide camera, follow, summon and the rest), wired once in `CanvasParticipantMenu` and shared with the participants sheet.
  Past a width-based count the rest fold into a "+n" that opens the sheet.
- Ink, live drafts and cursors paint above every tile.
  All tile video paints in `CanvasPresenceBackdrop` under `CanvasSurface`; `CanvasPresenceLayer` above it carries the gestures, the name badge and the controls.
  Send to back and bring to front no longer exist for tiles, since depth against ink is no longer a choice.
  The stored flag stays on the media slot and is ignored.
- Personal view stays private ([0082](0082-personal-canvas-view.md)).
  The view relay, follow and summon send the shared view only, and nothing about a personal camera leaves the device.
- A phone leaves its portrait lock only while a canvas tile is full screen, and the canvas then lays out from the real window size.
  This amends the "What this gives up" section of [0081](0081-canvas-tile-fullscreen-keeps-the-canvas.md) and reuses the rotation of [0058](0058-phone-landscape-for-full-screen-call-video.md).
  The shell stays portrait, which is the `keepPortraitShell` exception for this one surface.

## What this gives up

A camera that turns off removes its tile, and turning it back on returns it to the saved slot rather than a placeholder.
Depth between a tile and ink can no longer be chosen.
