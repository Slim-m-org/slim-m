# SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
"""The three tools e2e_canvas.py's own module doc says it does not cover:
note, shape, and reordering a stroke - each written after the canvas grew
past the single pen it shipped with (see docs/research/canvas-removal-design-2026-07-31.md
and the canvas decision records for why).

Split out of e2e_canvas.py to stay under the file budget; every helper used
here (origin, at_frac, wait_for_summary, wait_for_kind_count,
open_activity_log, close_activity_log, object_of_kind, STROKE_MID) is
defined there and imported rather than duplicated.

Note and shape are placed with a single tap, not a drag - `CanvasSurface`
fires `onNotePlace`/`onShapePlace` once, on pointer-down (see
canvas_surface.dart's own `_down`), so a `drag()` call with one point is a
real tap: press and release at the same spot.
"""
import e2e_labels as L
from e2e_api import wait_until
from e2e_canvas import (
    STROKE_MID,
    at,
    at_frac,
    close_activity_log,
    object_of_kind,
    open_activity_log,
    origin,
    wait_for_summary,
)

# A fraction of the surface's own live size, not a fixed pixel offset - see this module's own doc for why.
_NOTE_POINT = (0.15, 0.5)
_SHAPE_POINT = (0.55, 0.5)
_MOVE_TEST_POINT = (0.85, 0.15)
_DOCK_TOP_MARGIN = 40  # half the tools row plus the card's padding and a gap


def assert_clear_of_dock(client, point):
    """Points stay in the top half: the dock stacks to three rows at this window's pane width.
    A tap under the floating dock lands on the dock, not the canvas, and
    reads later as a note field or a shape that never appeared.
    """
    tools = next((n for n in client.nodes() if n["t"].startswith(L.ERASER_TOOL)), None)
    if tools and point[1] >= tools["y"] - _DOCK_TOP_MARGIN:
        raise AssertionError(
            f"{client.name}: the tap at y={point[1]:.0f} is under the dock "
            f"(its tools row is at y={tools['y']:.0f})")


def place_note_and_see_it_live(a, b, admin_api, channel_id):
    """`a` drops a note carrying real text with the note tool; `b`, already
    watching, sees it arrive - text and all, not just an empty box.
    """
    point = at_frac(a.canvas_rect(), *_NOTE_POINT)
    a.click(L.NOTE_TOOL)
    assert_clear_of_dock(a, point)
    a.gestures(True)
    a.drag([point])
    a.gestures(False)

    a.type_into(L.NOTE_TEXT_FIELD, "a note from alice")
    a.click(L.ADD_NOTE)

    wait_for_summary(a, "1 note")
    wait_for_summary(b, "1 note")
    print("  a's note arrived on b's screen live")

    note = object_of_kind(admin_api, channel_id, "note")
    assert note["props"].get("text") == "a note from alice", \
        "the note's own text did not reach the server"


def place_shape_and_see_it_live(a, b, admin_api, channel_id):
    """`a` drops the default (rectangle) shape with the shape tool; `b`
    sees it arrive too.
    """
    point = at_frac(a.canvas_rect(), *_SHAPE_POINT)
    a.click(L.SHAPE_TOOL)
    assert_clear_of_dock(a, point)
    a.gestures(True)
    a.drag([point])
    a.gestures(False)

    wait_for_summary(a, "1 shape")
    wait_for_summary(b, "1 shape")
    print("  a's shape arrived on b's screen live")

    shape = object_of_kind(admin_api, channel_id, "shape")
    assert shape["props"].get("shape") == "rectangle", \
        "the shape's own kind did not reach the server"


def newest_of_kind(api, channel_id, kind):
    """The most recently placed object of [kind], by the server's own
    `created_at` - unlike `object_of_kind` in e2e_canvas.py, which never has
    to tell two of a kind apart because it only ever runs while exactly one
    exists.
    """
    return max((o for o in api.canvas_objects(channel_id) if o["kind"] == kind),
               key=lambda o: o["created_at"])


def place_then_move_without_switching_tools(a, admin_api, channel_id):
    """Placing a shape leaves the surface on Move with the new shape already
    selected (#456's own fix for "no way to resize what you just placed
    without switching tools first"), so a drag right where it was just
    placed, with no click on the Move tool in between, moves it rather than
    placing a second shape - `CanvasSurface.onShapePlace` fires again on
    pointer-down while the shape tool stays armed, which is exactly what a
    regression here would produce instead.

    Checked at the server only, not through the accessibility tree, and
    that was not the first draft. `CanvasSelectionSemantics`' own "Selected
    shape" node is real and its isolated widget test
    (`canvas_selection_semantics_test.dart`) passes for this exact case, but
    live, through this pane, it never reached the DOM at all: the selection
    outline and resize handles paint correctly (`SelectionPainter` reads the
    identical `document.selectedObjectId`), yet no node anywhere in the tree
    - checked by raw `aria-label` attribute, not only rendered text - ever
    named the shape. That gap is real and worth a look on its own, but
    tracking it down is past what this pass can responsibly claim to have
    fixed; asserting the label here would be exactly the "passes whether or
    not it works" shape this harness's own doc already warns against, so
    the object's server-side position is what this checks instead. Runs
    after `erase_undo_clear_and_restore` and leaves its extra shape in place
    rather than deleting it, so it does not need to touch that scenario's
    own hardcoded object count; `reload_persists` reads the server's count
    fresh and absorbs it without any change there either.
    """
    before = sum(1 for o in admin_api.canvas_objects(channel_id)
                 if o["kind"] == "shape")
    point = at_frac(a.canvas_rect(), *_MOVE_TEST_POINT)
    a.click(L.SHAPE_TOOL)
    a.gestures(True)
    a.drag([point])
    a.gestures(False)

    def _shape_count():
        return sum(1 for o in admin_api.canvas_objects(channel_id)
                    if o["kind"] == "shape")

    wait_until(_shape_count, lambda count: count == before + 1,
                "the newly placed shape never reached the server")
    placed = newest_of_kind(admin_api, channel_id, "shape")
    print("  placing a shape reached the server")

    a.gestures(True)
    a.drag([point, (point[0] + 40, point[1] + 30)])
    a.gestures(False)

    moved = wait_until(
        lambda: admin_api.canvas_object(channel_id, placed["id"]),
        lambda obj: obj["x"] != placed["x"] or obj["y"] != placed["y"],
        "dragging right after placing, with no tool switch, never moved "
        "the object - Move was never armed by the placement")
    print(f"  dragging it immediately moved it to "
          f"({moved['x']:.0f}, {moved['y']:.0f}) rather than placing a "
          f"second shape")

    after = sum(1 for o in admin_api.canvas_objects(channel_id)
                if o["kind"] == "shape")
    assert after == before + 1, (
        f"expected the drag to move the placed shape rather than add a "
        f"third: {before} shape(s) before, {after} now")


def _others_z(api, channel_id, object_id):
    return [o["z_index"] for o in api.canvas_objects(channel_id)
            if o["id"] != object_id]


def reorder_stroke_and_see_it_live(a, b, admin_api, channel_id):
    """Selects the pen stroke with the Move tool - a stroke can only ever
    be reordered, never dragged, see `beginSelect`'s own doc - and brings
    it above every other object, then sends it back below all of them.

    A stroke's own z_index is the one property this scenario can check on
    the server that a screen genuinely cannot show (`CanvasSurface` paints,
    it does not narrate), so the cross-client proof is `b`'s activity log
    instead: `CanvasObjectReordered` carries no actor field at all (see
    canvas_activity_log.dart's own doc on why a reorder is treated as a
    moderation-shaped event), so "An object's stacking order changed."
    is what a live receiver sees regardless of who moved it.
    """
    stroke = object_of_kind(admin_api, channel_id, "stroke")

    a.click(L.PAN_TOOL)
    a.gestures(True)
    a.drag([at(origin(a), STROKE_MID)])
    a.gestures(False)

    a.click(L.MORE_CANVAS_ACTIONS)
    a.click(L.BRING_TO_FRONT)

    raised = wait_until(
        lambda: admin_api.canvas_object(channel_id, stroke["id"]),
        lambda obj: obj["z_index"] > max(_others_z(
            admin_api, channel_id, stroke["id"])),
        "the stroke never rose above every other object on the server")
    print(f"  brought the stroke to the front (z_index {raised['z_index']})")

    open_activity_log(b)
    b.wait_for("stacking order changed", timeout=20)
    b.shot("canvas-reorder-in-activity-log")
    close_activity_log(b)
    print("  b's activity log recorded the reorder live, "
          "not only the server's own row")

    a.click(L.MORE_CANVAS_ACTIONS)
    a.click(L.SEND_TO_BACK)

    lowered = wait_until(
        lambda: admin_api.canvas_object(channel_id, stroke["id"]),
        lambda obj: obj["z_index"] < min(_others_z(
            admin_api, channel_id, stroke["id"])),
        "the stroke never dropped below every other object on the server")
    print(f"  sent the stroke back (z_index {lowered['z_index']})")

