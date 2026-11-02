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

## Escape with a drawing tool armed (2026-11-02)

Nick pressed Esc by instinct to put the pen down and found it did nothing, so this looked at what comparable tools do.
Excalidraw's `actionFinalize` runs on Esc for a multi-point element in progress and then sets the active tool back to the preferred selection tool ([source](https://raw.githubusercontent.com/excalidraw/excalidraw/master/packages/excalidraw/actions/actionFinalize.tsx)).
One Figma forum poster says V or Esc returns to the selection tool after drawing a shape ([Figma forum](https://forum.figma.com/ask-the-community-7/why-doesn-t-the-mouse-switch-to-selection-after-using-shortcut-r-to-create-a-graphic-i-have-to-press-v-or-esc-to-switch-it-to-selection-mode-14475)).
Miro's moderators describe Esc as deselect, and Esc twice to leave text editing and then deselect ([Miro community](https://community.miro.com/ideas/1202)).
A Blender thread asks for the same two-step behaviour: the first Esc cancels the action in progress, the second returns to the select tool ([Blender devtalk](https://devtalk.blender.org/t/pressing-esc-while-in-active-tool-go-out-of-the-tool-back-to-selection/6593)).
I could not confirm tldraw, FigJam, Photoshop or Krita from search results, so they are not cited.
Our own Esc bindings were: the open menu or popover, the text and note editors, the tool wheel, deselect, then the docked thread and member panes, then fullscreen.
None of them touched the armed tool, so there was no conflict to design around.
Decision: Esc puts a drawing tool down, in this order, one step per press.
First an open popover, menu or editor closes, since each owns focus and consumes the key.
Then an in-progress pen stroke or shape drag is dropped without being sent, and the tool stays armed.
Then an open docked thread pane closes, as it did before.
Then an armed tool other than Pan returns to Pan.
Only with Pan armed does Esc fall through to deselect, the docked member pane, and leaving fullscreen, so one press never does two of these.
