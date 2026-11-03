<!-- SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0 -->
# Screen overlay: what a viewer's mark did not do, and what could come next

Date: 2026-11-02.
Status: proposal, nothing here is built except the monitor fix.

## What the owner saw

Viewers' strokes and a sticky note showed on the viewer's tile, but nothing appeared on the sharer's real screen.

## What was checked

- The native window was run in a nested KWin (own config, never the owner's screen), both standalone and inside the real debug client.
  On one output it draws strokes and notes over every window, click-through.
- The server relay and the Dart gate have tests and pass.
- On two outputs GDK reports neither as primary.
  The old pick fell back to "the primary monitor" when shapes tied, which resolved to monitor 0 every time.
  Sharing the second of two identical monitors therefore drew the overlay on the first one.
- That is the most likely cause of the report, but it was not reproduced with a real portal share, because the portal picker needs a person.

## Fix

The overlay opens on every monitor whose shape matches the captured size, and on all of them when the size is unknown.
The consent frame carries an aspect only when those monitors agree on one.

## Further functionality that fits

Ordered by value for the effort.

1. Laser pointer.
   A mark that is a dot following the pen and vanishing on release, with no trail kept.
   It reuses the stroke frame with a short hold, so the relay and the overlay need only a new kind.
2. Sharer clears all.
   One button next to "Viewers can draw on your screen" that drops the live board and tells viewers.
   It needs one new frame kind and no native change.
3. Names beside marks.
   A small label at the stroke's start with the drawer's name, in the drawer's colour, so two viewers are told apart.
   The frame already carries the author; the native side needs a text primitive, which notes already have.
4. Longer hold for the sharer's own marks.
   Let the sharer pin a mark until clicked away.
   This needs input on the overlay, which the design deliberately forbids, so it is not proposed.

## Not proposed

- Persisting marks.
  Marks are ephemeral by decision 0096.
- Drawing by the sharer on their own screen.
  That is an annotation tool in its own right, with its own input-grab problems.
