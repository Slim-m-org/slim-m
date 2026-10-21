<!-- SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0 -->
# 0082 - A personal view beside the shared board

Status: accepted
Date: 2026-10-19 (answers recorded 2026-10-20)

## The ask

The owner, 2026-10-18: "Maybe we can do a shared canvas and a person canvas toggle or something? Backlog it but all views should look the same between users no matter the aspect ratio between devices or resolution for now".
[0073](0073-shared-canvas-board.md) made the shared board; its "What is left" named this toggle and the restored camera that goes with it.

## Decision

A pill beside the zoom chip names the view and switches it: "Shared view" or "Personal view" (accent tint while personal).
The view is a local choice.
Nothing about it is sent to the server or visible to anyone else.

- Shared view is what 0073 and 0080 describe.
  Opening a canvas, and switching back, fits the board.
  Tile drags and resizes are the shared arrangement and are committed to the server as before.
- Personal view keeps the camera this viewer left and lets them place and resize call tiles for themselves.
  A personal tile place is a second rect on the tile's state, drawn only on this device, never sent, and never overwritten by a server update.
  Lock and send-to-back stay shared actions, so they are not offered in the personal view.
- Ink, notes, shapes and images are shared content in both views.
  A personal view never edits them differently, and what a viewer draws is drawn for everyone.
- Containment is unchanged.
  The personal camera goes through the same clamp as the shared one, and a personal tile place goes through the same board clamp, so nothing leaves the board in either view.
- The layout is remembered per channel, on this device.
  Reopening a channel's canvas, or restarting the app, restores the camera, the tile places and which view was showing.
  A tile place for someone who is not in the call is kept and ignored until they are, and every stored place and camera goes through the board clamp again on the way back, so a board that changed cannot strand anything.
- "Reset my layout" sits beside the pill whenever there is a layout of your own to give up.
  It drops the camera and the tile places and returns to the shared view.
  It is a visible, labelled button with its own screen reader label, reachable by keyboard, and padded to a touch target on narrow windows ([desktop-vs-mobile](../design/desktop-vs-mobile.md) law 2; it is a control that stays on screen, not a menu, so no surface rule applies).
- Following someone, or being summoned with bring everyone, switches this viewer to the shared view, because those are shared board rectangles.
  The personal layout stays saved for when they switch back.
- The canvas is never locked.
  The shared view stays as freely pannable and zoomable as before, and following still ends on the follower's own pan or zoom.

## Storage

The layout is per-viewer convenience state and never reaches the server or anyone else.
It lives in the local drift store beside the composer drafts, the one table there that is not a cache of server state: `canvas_personal_layouts`, one row per channel holding the layout as JSON, written a moment after a pan or drag settles and when the canvas closes.
Decision [0068](0068-multiple-servers-in-one-app.md) gives every account its own database file, so two Spaces or accounts cannot collide and the channel id alone is the key.
Signing out clears it with the rest of the cache.
It is bounded two ways: rows for channels the account no longer has are dropped on the next save, and past 40 channels the least recently changed go first.
A channel keeps at most 64 tile places.

## Not done

- A tile focused to full screen (0081) fills the pane in both views, so a personal place only shows when it is not focused.
- No shared-versus-personal choice for ink or notes.
