# SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
"""Composes one deliberate diagram on top of the random main pass: a box
drawn around a busy cluster, an arrow pointing from it to a callout note,
a divider line, and three notes at genuinely different lengths - a
two-word label, a sentence, and one long enough to test wrapping.

Placed after `seed_canvas_history.run` rather than folded into the main
pass, and never handed to that history pass as a target: this is the one
part of the board meant to read as a diagram somebody actually made, so
nothing here gets randomly moved, resized, reordered, removed or restored
the way the rest of the seeded content deliberately is. Authorship is
still spread across accounts round-robin, or the whole thing reads as one
person's work.

A shape's line and arrow primitives always draw their own box's diagonal
from top-left to bottom-right (see `canvas_painters_shapes.dart`'s own
doc), so an arrow "pointing" from one thing to another only renders
correctly when the target sits down and to the right of the source. Every
box below is placed with that constraint in mind rather than left to
chance.
"""
import uuid7

import seed_canvas_ops as ops

_SHORT_NOTE = "ship blockers"
_SENTENCE_NOTE = "Check the collapse-to-strip fix before the next release."
_LONG_NOTE = (
    "Retro notes from the last canvas review: collapse-to-strip turned out "
    "to already be built, so closing the pane already tore the old subtree "
    "down and freed the decoded image bitmap - the only thing worth "
    "proving was that disposal actually ran, not that the widget merely "
    "vanished. The activity log is fed from two places and the split "
    "matters: a catch-up op discloses its actor exactly when the caller "
    "holds manage rights, but a live socket frame for a removal, a clear, "
    "or a restore never carries an actor at all, so a moderator watching "
    "live sees less than the same event replayed from catch-up would show "
    "them later. That asymmetry is written down rather than closed, since "
    "the live frame literally has no field to disclose regardless of "
    "permission. Blocking on the log reuses the exact isBlocked signature "
    "the cursor relay already filters a remote pointer with, so an entry "
    "from a blocked author never reaches the list, and an entry with no "
    "actor is never filtered since there is nothing to match against. The "
    "panel itself is a real navigable list built from the shared list row "
    "component rather than a hand-rolled one, and dumping the actual "
    "semantics tree caught a stale doc comment claiming the row excluded "
    "its own relative timestamp from the accessible label, when the dump "
    "showed the row folds it in. Three touched files are further past the "
    "line budget now than before this pass, and the next person adding to "
    "any of them should plan on a split rather than one more small "
    "addition on top."
)

_LABEL_W, _LABEL_H = 160, 70
_CALLOUT_W, _CALLOUT_H = 260, 110
_LONG_NOTE_W, _LONG_NOTE_H = 360, 480
_CLUSTER_RADIUS = 650
_RECT_PAD = 50
_DIVIDER_W, _DIVIDER_H = 1600, 4


def _note(x, y, w, h, text):
    return {"id": uuid7.uuid7(), "kind": "note", "x": round(x, 2),
            "y": round(y, 2), "w": w, "h": h, "props": {"text": text}}


def _shape(kind, x, y, w, h):
    return {"id": uuid7.uuid7(), "kind": "shape", "x": round(x, 2),
            "y": round(y, 2), "w": round(w, 2), "h": round(h, 2),
            "props": {"shape": kind}}


def _cluster_bounds(placed, center):
    """The bounding box of every placed object within `_CLUSTER_RADIUS` of
    `center`, or a fixed-size placeholder if the sample landed empty -
    which keeps this deterministic-enough for a small `--objects` run
    rather than failing the diagram outright."""
    cx, cy = center
    near = [p for p in placed if
            (p["x"] + p["w"] / 2 - cx) ** 2 + (p["y"] + p["h"] / 2 - cy) ** 2
            <= _CLUSTER_RADIUS ** 2]
    if not near:
        return cx - 300, cy - 200, cx + 300, cy + 200
    return (min(p["x"] for p in near), min(p["y"] for p in near),
            max(p["x"] + p["w"] for p in near), max(p["y"] + p["h"] for p in near))


def _place(api, channel_id, placement, author_index):
    result = ops.place_object(api, channel_id, placement)
    result["author_index"] = author_index
    return result


def run(api_by_index, channel_id, centers, weights, placed, rng):
    """Places the diagram and returns its rows, the same shape
    `place_main_pass` returns."""
    accounts = len(api_by_index)

    def author(offset):
        return api_by_index[offset % accounts]

    busiest = weights.index(max(weights))
    min_x, min_y, max_x, max_y = _cluster_bounds(placed, centers[busiest])
    rect_x, rect_y = min_x - _RECT_PAD, min_y - _RECT_PAD
    rect_w = (max_x - min_x) + _RECT_PAD * 2
    rect_h = (max_y - min_y) + _RECT_PAD * 2

    diagram = [_place(
        author(0), channel_id,
        _shape("rectangle", rect_x, rect_y, rect_w, rect_h), 0)]

    label_cx = rect_x + rect_w * 0.25
    label_y = rect_y - _LABEL_H - 24
    diagram.append(_place(
        author(1), channel_id,
        _note(label_cx - _LABEL_W / 2, label_y, _LABEL_W, _LABEL_H,
              _SHORT_NOTE), 1))

    diagram.append(_place(
        author(2), channel_id,
        _shape("line", label_cx - _DIVIDER_W / 2, label_y - 40, _DIVIDER_W,
               _DIVIDER_H), 2))

    # Down and right of the rectangle, so the arrow's own diagonal actually points at the callout.
    callout_x, callout_y = rect_x + rect_w + 220, rect_y + rect_h + 140
    diagram.append(_place(
        author(3), channel_id,
        _note(callout_x, callout_y, _CALLOUT_W, _CALLOUT_H, _SENTENCE_NOTE),
        3))

    arrow_x0, arrow_y0 = rect_x + rect_w, rect_y + rect_h
    arrow_x1, arrow_y1 = callout_x, callout_y
    diagram.append(_place(
        author(0), channel_id,
        _shape("arrow", arrow_x0, arrow_y0, arrow_x1 - arrow_x0,
               arrow_y1 - arrow_y0), 0))

    long_center = centers[weights.index(min(weights))]
    diagram.append(_place(
        author(4), channel_id,
        _note(long_center[0] - _LONG_NOTE_W / 2,
              long_center[1] + _CLUSTER_RADIUS,
              _LONG_NOTE_W, _LONG_NOTE_H, _LONG_NOTE), 4))

    return diagram
