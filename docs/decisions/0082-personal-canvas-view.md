<!-- SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0 -->
# 0082 - A personal view beside the shared board

Status: accepted
Date: 2026-10-19

## The ask

The owner, 2026-10-18: "Maybe we can do a shared canvas and a person canvas toggle or something? Backlog it but all views should look the same between users no matter the aspect ratio between devices or resolution for now".
[0073](0073-shared-canvas-board.md) made the shared board; its "What is left" named this toggle and the restored camera that goes with it.

## Decision

A pill beside the zoom chip names the view and switches it: "Shared view" or "Personal view" (accent tint while personal).
The view is a local choice.
Nothing about it is sent, stored or visible to anyone else.

- Shared view is what 0073 and 0080 describe.
  Opening a canvas, and switching back, fits the board.
  Tile drags and resizes are the shared arrangement and are committed to the server as before.
- Personal view keeps the camera this viewer left (for the session) and lets them place and resize call tiles for themselves.
  A personal tile place is a second rect on the tile's state, drawn only on this device, never sent, and never overwritten by a server update.
  Lock and send-to-back stay shared actions, so they are not offered in the personal view.
- Ink, notes, shapes and images are shared content in both views.
  A personal view never edits them differently, and what a viewer draws is drawn for everyone.
- Containment is unchanged.
  The personal camera goes through the same clamp as the shared one, and a personal tile place goes through the same board clamp, so nothing leaves the board in either view.
- Follow and bring everyone use board rectangles, which mean the same in both views, so they work from the personal view and move only the camera.
  A followed or summoned jump does not switch the view.

## Not done

- The personal camera is not kept across closing the canvas.
- A tile focused to full screen (0081) fills the pane in both views, so a personal place only shows when it is not focused.
- No shared-versus-personal choice for ink or notes.
