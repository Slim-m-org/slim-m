<!-- SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0 -->
# 0094 - Canvas mouse controls, tool wheel, zoom bounds and pen size

Status: accepted
Date: 2026-10-27

## The ask

The owner, 2026-10-23, wanted the canvas to be mouse-first, never to show past the board's edge, and a pen size that feels constant.
Decisions on 2026-10-26: left click stays Move, a right-click hold opens a tool menu, and the pen size is a screen-feel slider.

## Decision

- Left click keeps the armed tool, and Move stays the default.
  Panning is the middle button, Space plus drag, the wheel and the arrow keys; none of that changes.
- A right click over an object opens that object's menu (front, back, lock, delete, edit note).
  Call tiles keep their own menu, since they sit above the ink.
- A quick right click on empty canvas keeps today's quick actions.
  Both menus open on the release, so a hold never leaves one behind.
- Holding the right button on empty canvas for the long-press time opens the tool wheel at the pointer: Move, Pen, Note, Shape, Eraser, Paste image.
  A flick toward a tool and a release picks it.
  A release without a flick leaves the wheel open to click.
  The release that ends a hold opens no quick actions; the next right press clears that.
- Without a mouse the wheel opens from the context-menu key or Shift+F10 when nothing is selected, and closes on Escape.
  Tab and the arrows move between tools and Enter picks.
  The wheel is a named route for screen readers, and each tool is a labelled button.
  The tool strip and the H, P, N, S, E keys stay as the other keyboard routes.
- Touch keeps its long-press equivalents (desktop-vs-mobile rule 3).
  The wheel is a mouse gesture, so it adds no hover-only action.
- The wheel offers only what the strip offers: tools that place objects are disabled while the canvas is not writable.

## Zoom bounds

- The zoom floor is the zoom at which the board covers the view on both axes, so the view never shows past an edge.
  The camera is pinned to the board, above the dock.
  Where even the cover is past the maximum zoom, the old contain fit is the floor.
- Fit and Recenter still open the shared area at its own fit zoom.
  On a pane far taller or wider than 16:9 the cover is above that fit, so the opening view sits at the floor and the zoom pill reads 100 percent there.
- A call tile's full screen still fits the tile, which is a zoom in.
- The plain wheel still pans.
  Whether it should zoom is undecided and left alone.

## Pen size

- The size slider is in screen pixels, 1 to 24, with a dot preview of the same size.
- A stroke stores `width / zoom` at the moment it is drawn, so everyone sees one stroke and the drawer sees the size they chose.
- Shapes and the eraser have no size today (a fixed outline and a fixed ring), so there is nothing to convert yet.
