<!-- SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0 -->
# 0137 - Canvas edges

Status: accepted
Date: 2026-11-24
Extends: 0017, 0072, 0073, 0085, 0087, 0127; amends 0047 point 5

## The ask

Nick, 2026-11-24: "no arrows in canvas tools, might be nice to have like the obisidan notes canvas arrows that connect to other nodes like notes and boxes and such".
The free-standing Shape arrow stays; it attaches to nothing.

## Decision

A connection is a new object kind, `edge`, never a shape sub-kind: a shape is the diagonal of its own box, and an edge's geometry comes from other objects.
"Connector" already names the external connector runtime (0090, 0134), so the wire, code and docs say edge and the UI says "connection" and "Connect".

Props: `from` and `to` (`{object_id, side}` or a free `{x, y}`), `arrow` none|end|both, `color` (palette key or `#rrggbb`, absent is the board's neutral ink), `label` (one trimmed line, at most 120 characters).
`text` is never an edge prop.
At least one end is attached, the two attached ends differ, and attachable kinds are note, text, shape, image, emoji and module tile.
Strokes, edges and camera or screen tiles are not attachable: those tiles live in `canvas_media_slots`, not `canvas_objects`, so a foreign key cannot name them.
An end in another channel answers 404 like a missing one.

The server derives the stored box as the plain union of the end boxes and points, written with a dedicated update that names x, y, w and h so the R-Tree trigger fires, and exempt from `MAX_OBJECT_EXTENT`.
The same function runs in Rust and Dart, pinned by `schema/test-vectors/canvas_edge_hull.json`.
It is recomputed on place, on every edit and on a move of either end.
A `move` of an edge is a 400.
Batch placement refuses edges.
At most 64 live edges attach to one object (409), so a move or an erase rewrites a bounded number of rows.

An edit merges at the top level: an absent key keeps its value and `null` deletes it, and the merged props are validated and size-checked again.

## Cascade, undo and purge

Migration 0221 adds `canvas_edge_ends` (derived from props, for finding edges by index) and `canvas_op_cascades` (the edges one remove or clear took with it).
An erase or clear takes every edge attached to what it removes in the same transaction, locked or not.
The remove's `object_ids`, its frame and the op feed stay the directly erased ids, which keeps the 64 id frame bound and means an old client never hears of an object it never held.
Clients cascade locally from their end index.
A restore revives the op's direct targets (author-checked as before) plus its cascade rows (not author-checked, since they fell with the actor's own erase), and an edge only when every attached end is live afterwards; the ends are read from props, never from row counts.
Revived edges are in the restore's touched set, targets and frame.
A clear records the edges its sweep took, including ones newer than its fence.
Purging an object purges the dead edges attached to it.

## Old clients

Shipped client-v0.136.0 skips a kind it does not draw: `canvas_object_inputs.dart:23` `_ => null`, `canvas_sync.dart:364-365`, `canvas_engine.dart:446-447`.
A remove or restore naming an id it never held is a no-op.
The activity log says "placed a stroke", which is cosmetic.
`/version` carries `canvas_edges`; a new client on an older server hides the Connect tool, the side dots and the connection menu.

## Client

Edges are held by `CanvasEdges` beside the document, never in the slot scene: they are routed at paint time from the boxes their ends are drawn at, so a drag, a resize and a remote preview re-route them with nothing to invalidate.
An edge whose end is not held yet (the board is still paging) is neither drawn nor hit-testable until it arrives.
`CanvasObjectKind.edge` exists for scoped clears and `kindOf`, but an edge is not a `CanvasStroke`.
A region read reports an edge's hull from its held ends, and counts it touched when either end is.

Interaction: hovering (pointer) or selecting (touch, 44dp targets) a connectable object shows four side dots, and dragging one draws the edge.
The Connect tool (key C, Lucide `spline`, after Shape in `canvasToolOrder`, amending 0047 point 5) draws from anywhere on an object.
Dropping on empty board leaves a free end; a drag that would free both ends snaps back; a click that goes nowhere draws nothing.
The selected connection shows end handles and a bar: colour (neutral first), arrow as a segmented row, Edit label, Delete.
`[` and `]` step through connections, Enter edits the label, Delete erases.
Layout follows desktop-vs-mobile Law 1 (width decides): at 600 and wider the bar floats above the connection; under 600 it docks full width above the dock and keyboard.
Law 2 (30-38dp pointer, 44dp touch) sizes the controls, and Law 3 gives every hover a long-press: dots on select, the object menu on long-press.
Surface rule 1 (context menu) covers the object menu and arrow is a segmented row, never a dropdown.
Label editing follows the translation-table row "inline edit-in-place -> the same, composer expanded to fit; never a separate edit screen".
Escape cannot be the only way to cancel, so on touch cancel is undo (each edit is one undo entry) or Android back.
Activity log: "a connection" and "connections".
