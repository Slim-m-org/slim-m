<!-- SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0 -->
# 0079 - The message hover toolbar lives in the overlay

Status: accepted
Date: 2026-10-19

## The ask

The owner noticed one-line follow-up messages sitting further apart than the rest of the list.
Rows measured 30px where the density spacing gives 24px.

## Cause

The hover toolbar is 30px tall and lived inside its row, so non-compact rows had a 30px minimum height to keep the whole plate hittable.
A control laid out past its parent's edge paints but cannot be hit, because every ancestor rejects a pointer outside its own box.

## Rule

- This reverses the "grow the row" recommendation in `docs/research/hover-toolbar-density-2026-09-30.md`.
- The toolbar is built in the overlay (`message_toolbar_anchor.dart`, `OverlayPortal.overlayChildLayoutBuilder`) and hangs from the row's top right.
  A one-line row keeps its density height and the plate overhangs the row below, fully clickable.
- The row reports the pointer over its toolbar through `HoverRevealScope.reportOverlayHover`, so moving onto the overhang does not read as leaving the row.
- The plate is hidden while its row is scrolled so far out of the list that the whole plate would not fit, rather than floating over the header.
- Two adjacent rows can both show a plate (focus on one, hover on the other); they overlap by up to 6px and the later one sits on top.

## Why

The research weighed this against permanent looseness and picked looseness for its structural simplicity.
The owner's report is that the looseness is the bug, and `OverlayPortal.overlayChildLayoutBuilder` removes most of the position-tracking cost that research expected.
