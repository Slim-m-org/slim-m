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

## Not done

The OS window does not go fullscreen with it, as the old route did on desktop.
