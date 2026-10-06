# SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
"""The Voice Canvas across two clients: draw, paste, move, resize, erase,
clear, undo, and a reload that proves what persists actually persists.

Note, shape and reorder scenarios live in e2e_canvas_shapes.py, split out to
stay under the file budget; it imports the helpers below rather than
duplicating them.

The canvas is a `CustomPainter` and publishes almost nothing else to the
accessibility tree this harness drives - see docs/e2e.md's "Driving a canvas
app". Two things stand in for the widgets a normal scenario would click: the
surface's own container `Semantics` node, whose label always starts
"Canvas," and states the live object count ("Canvas, 2 objects: 1 stroke,
1 image, 0 notes, 0 shapes"), updated on every local and live change so it
is this scenario's main proof both clients agree without opening anything;
and `CanvasActivityLog`'s panel (canvas_activity_log.dart,
canvas_activity_panel.dart), a real list of `AppListRow`s a screen reader -
and this harness - can browse, reached for what the object count cannot
show: that a move, a resize (the same wire op with a different box) or a
reorder actually arrived on the client that did not make it, not only that
the server's own row changed.

Stroke offsets clear the presence bubbles, which is why they sit low and to
the left rather than at the `(80, 80)` they used to. A voice channel's canvas
draws a tile per person in the call, and an untouched one starts at world
`(24, 24)` and is 220x160 (`CanvasPresenceLayout`'s own margin, tileWidth and
tileHeight), so the old offsets ran straight through the drawer's own bubble -
which absorbed the press and left the surface with no stroke to commit. None
of that existed while these scenarios ran in a text channel, where nobody is
in a call and there are no tiles at all. `y` clears the untouched row
(24 + 160), and `x` stays left of where `move_and_resize_converges` later
drags that tile to, which is what the eraser needs afterwards.

Camera math: `Camera` starts at `(0, 0)` with `zoom: 1` (canvas_stroke.dart)
and nothing here ever pans or zooms, so a world coordinate and a page
coordinate differ by exactly one constant offset for the whole scenario -
the canvas surface's own top-left, fetched once as `origin`. Note and shape
placements land as a fraction of the surface's own live width and height,
not a fixed pixel offset, because they run after the image has already been
dragged and resized once (move_and_resize_converges) and a fixed offset
picked blind risks landing on top of wherever that ended up.

Drawing, moving, resizing and placing a note or shape all need raw pointer
events: the semantics tree sits over the canvas and swallows ordinary
clicks there, the same reason the react button needs `gestures(True)`
elsewhere in this harness. Every other control here (the tool buttons,
Undo, the overflow menu) is clicked by label as usual.

The pasted image is placed through the same DOM `paste` event a real Ctrl+V
produces (e2e_js.paste_image), not through the API: the bug this scenario
exists to catch - an image visible only to whoever pasted it, and only until
they reloaded - was a client-side hydration gap, and calling the API
directly would prove nothing about whether a *receiving* client fetches and
decodes the bytes back.

**What is deliberately not forced here: the in-flight stroke preview.**
Watching somebody draw (canvas_stroke_preview_relay.dart) rides its own
ephemeral WebSocket frames, painted through `RemoteDraftPainter`, a second
`CustomPainter` with nothing in the accessibility tree at all - not even an
object count, since a draft is never a committed object. Proving a frame
reached `b` mid-gesture would need a pixel comparison (this harness is
label-driven, not pixel-driven, by design) or sniffing `b`'s WebSocket
traffic over CDP, which no scenario here does and which would only prove a
frame arrived, not that it painted anything. A test that times a draft and
asserts nothing observable would pass whether or not the feature works,
which is worse than not writing it; the commit op a draft eventually
produces is what draw_stroke_and_see_it_live already checks on both
clients.
"""
import json
import threading
import time

import e2e_labels as L
from e2e_api import wait_until

# Offsets from the canvas's own top-left; the midpoint is the eraser's target.
STROKE_START = (60, 280)
STROKE_MID = (130, 280)
STROKE_END = (200, 280)
_ONE_STROKE = "1 stroke"


def origin(client):
    rect = client.canvas_rect()
    return rect["x"], rect["y"]


def at(point, offset):
    return point[0] + offset[0], point[1] + offset[1]


def at_frac(rect, fx, fy):
    """A point [fx, fy] of the way across the surface's own live size,
    rather than a fixed pixel offset - see this module's own doc for why a
    note or a shape needs this and a pen stroke does not.
    """
    return rect["x"] + rect["width"] * fx, rect["y"] + rect["height"] * fy


def wait_for_summary(client, needle, timeout=30):
    client.wait_for(needle, timeout=timeout)


def open_activity_log(client):
    client.click(L.MORE_CANVAS_ACTIONS)
    client.click(L.SHOW_ACTIVITY_LOG)


def close_activity_log(client):
    client.click(L.MORE_CANVAS_ACTIONS)
    client.click(L.HIDE_ACTIVITY_LOG)


def wait_for_kind_count(api, channel_id, kind, expected, timeout=15):
    """Polls the server, not the screen: the object count on screen drops
    the instant a removal is drawn locally, well before the async submit
    that pushes an undo entry has actually landed - clicking Undo in that
    gap does nothing, since the button is still disabled. Waiting for the
    server's own row to change is what proves the round trip finished.
    """
    deadline = time.time() + timeout
    while time.time() < deadline:
        count = sum(1 for o in api.canvas_objects(channel_id) if o["kind"] == kind)
        if count == expected:
            return
        time.sleep(0.5)
    raise AssertionError(f"server never settled to {expected} {kind}(s)")


def object_of_kind(api, channel_id, kind):
    return next(o for o in api.canvas_objects(channel_id) if o["kind"] == kind)


def _fetched_url_containing(client, server, needle):
    raw = client.ev(
        "JSON.stringify(performance.getEntriesByType('resource')"
        ".map(function(e){return e.name;}))")
    return any(needle in url for url in json.loads(raw or "[]")
               if server in url)


def open_on_both(a, b, channel):
    """Both clients into the same channel's canvas, empty.

    A voice channel, because the canvas only belongs to one now (owner
    decision, 2026-08-13): the header offers `Open canvas` there and nowhere
    else. Clicking a voice channel joins its call directly, so the wait is on
    being in the call rather than on a composer a voice channel does not have.
    """
    for c in (a, b):
        c.click(channel)
        c.wait_for(L.IN_CALL)
        c.click(L.OPEN_CANVAS)
        c.wait_for("no objects")
    print("  both clients opened the canvas and see it empty")


def draw_stroke_and_see_it_live(a, b):
    """`a` draws a short pen stroke; `b`, already watching, sees it arrive."""
    org = origin(a)
    a.gestures(True)
    a.drag([at(org, STROKE_START), at(org, STROKE_MID),
            at(org, STROKE_END)])
    a.gestures(False)
    wait_for_summary(a, _ONE_STROKE)
    wait_for_summary(b, _ONE_STROKE)
    print("  a's stroke arrived on b's screen live")


def paste_image_and_hydrate(a, b, server, admin_api, channel_id, image_path):
    """`a` pastes a real image; `b` renders it, bytes fetched and all.

    Placing the object is only half the claim in CLAUDE.md's own account of
    the hydration bug: the object row can exist while a receiving client
    still shows nothing but a box, because nothing ever asked the server for
    the pixels. Checking `b`'s own `performance` resource log for a request
    naming this exact attachment id is what tells those two apart.
    """
    a.paste_clipboard_image(image_path)
    wait_for_summary(a, "1 image")
    wait_for_summary(b, "1 image")
    print("  the pasted image arrived on b's screen live")

    attachment_id = object_of_kind(admin_api, channel_id, "image")["props"]["attachment"]

    deadline = time.time() + 20
    while time.time() < deadline:
        if _fetched_url_containing(b, server, attachment_id):
            print(f"  b's own browser fetched the attachment bytes "
                  f"({attachment_id}) rather than showing an empty box")
            return
        time.sleep(1)
    raise AssertionError(
        "b's browser never fetched the pasted image's bytes - "
        "it would have rendered as a placeholder, not a picture")


def move_and_resize_converges(a, b, admin_api, channel_id):
    """Drags the pasted image, then its handle, checked on the server and
    on the one client that never touched it.

    The select tool only ever picks up an image (`hitTestImageAt`), never a
    stroke - canvas_hit_test.dart's own doc says why - so this always moves
    the picture just pasted, not the ink drawn earlier. Runs while the
    canvas holds only the stroke and the image, before either note or shape
    scenario adds anything else, so the dynamic corner math below cannot
    land on an object it was not aimed at.
    """
    ox, oy = origin(a)
    image_id = object_of_kind(admin_api, channel_id, "image")["id"]
    before = admin_api.canvas_object(channel_id, image_id)

    a.click(L.PAN_TOOL)
    center = a.find("Canvas,")
    cx, cy = center["x"], center["y"]  # the paste centred the image here
    a.gestures(True)
    a.drag([(cx, cy), (cx + 90, cy + 60), (cx + 150, cy + 100)])
    a.gestures(False)
    time.sleep(2)

    moved = admin_api.canvas_object(channel_id, image_id)
    assert abs(moved["x"] - (before["x"] + 150)) < 8, \
        f"x did not track the drag: {moved['x']} vs {before['x'] + 150}"
    assert abs(moved["y"] - (before["y"] + 100)) < 8, \
        f"y did not track the drag: {moved['y']} vs {before['y'] + 100}"
    assert moved["w"] == before["w"] and moved["h"] == before["h"], \
        "a plain move changed the object's size too"
    print(f"  moved the image to ({moved['x']:.0f}, {moved['y']:.0f})")

    corner = (ox + moved["x"] + moved["w"], oy + moved["y"] + moved["h"])
    a.gestures(True)
    a.drag([corner, (corner[0] + 25, corner[1] + 20),
            (corner[0] + 50, corner[1] + 40)])
    a.gestures(False)
    time.sleep(2)

    resized = admin_api.canvas_object(channel_id, image_id)
    assert resized["w"] > moved["w"] and resized["h"] > moved["h"], \
        f"the resize handle did not grow the box: {resized['w']}x{resized['h']}"
    print(f"  resized it to {resized['w']:.0f}x{resized['h']:.0f}")

    open_activity_log(b)
    b.wait_for("was moved", timeout=20)
    b.shot("canvas-move-in-activity-log")
    close_activity_log(b)
    print("  b's activity log recorded the move and the resize live, "
          "not only the server's own row")


def erase_undo_clear_and_restore(a, b, admin_api, channel_id):
    """Erases the stroke, undoes it, clears the whole canvas, undoes that.

    By this point the canvas holds four kinds - stroke, image, note, shape
    (see e2e_canvas_shapes.py) - and every step here is read off the
    surface's own object-count label on *both* clients, since erase, undo,
    clear and restore all change that count and none of them need the
    activity panel to be seen. Clear and its undo are deliberately exercised
    against all four kinds at once, not just the original two: a clear that
    forgot to sweep a note or a shape would still pass a stroke-and-image-only
    version of this test.
    """
    a.click(L.ERASER_TOOL)
    a.gestures(True)
    a.drag([at(origin(a), STROKE_MID)])
    a.gestures(False)
    for c in (a, b):
        wait_for_summary(c, "0 strokes")
    print("  erasing the stroke dropped the count on both clients")
    wait_for_kind_count(admin_api, channel_id, "stroke", 0)

    a.click(L.UNDO)
    for c in (a, b):
        wait_for_summary(c, _ONE_STROKE)
    print("  undo restored it on both clients")

    a.click(L.MORE_CANVAS_ACTIONS)
    a.click(L.CLEAR_CANVAS)
    a.click(L.CLEAR_CANVAS, settle=3)  # the confirm dialog's own button
    for c in (a, b):
        wait_for_summary(c, "no objects")
    print("  clearing wiped all four kinds on both clients")
    wait_until(lambda: admin_api.canvas_objects(channel_id), lambda objects: not objects,
               "the server still holds canvas objects after the clear")

    a.click(L.UNDO)
    for c in (a, b):
        wait_for_summary(c, "1 stroke, 1 image")
    print("  undo restored the clear on both clients too")

    assert len(admin_api.canvas_objects(channel_id)) == 4, \
        "the server does not hold all four objects after the restore"


def reload_persists(client, channel, admin_api, channel_id):
    """A fresh reload, not a reopen: drops every in-memory cache and the
    local drift database's cursor alike, so a right answer here can only
    come from a real cold fetch of the server's own rows.
    """
    server_count = len(admin_api.canvas_objects(channel_id))
    origin_url = client.ev("location.origin")
    client.go_away()
    client.come_back(f"{origin_url}/#/channels")
    client.click(channel)
    # In call, not a composer: clicking a voice channel joins it directly.
    client.wait_for(L.IN_CALL)
    client.click(L.OPEN_CANVAS)
    client.wait_for("1 stroke, 1 image", timeout=30)
    client.wait_for(f"{server_count} objects", timeout=10)
    client.shot("canvas-after-reload")
    print(f"  after a full reload, {client.name} still sees all "
          f"{server_count} objects the server does")


def close_on_both(a, b):
    """Both canvases closed, and both clients out of the call they joined.

    Leaving is part of closing here, not tidiness. Opening a canvas now means
    joining a voice call (the canvas belongs to one, owner decision
    2026-08-13), and every voice scenario after this one starts by joining -
    so a client still in the call from these scenarios makes the next one's
    own join a no-op it then waits forever on. While these scenarios ran in a
    text channel there was no call to leave and nothing to hand back.
    """
    for c in (a, b):
        c.click(L.CLOSE_CANVAS)
        # A voice channel has no composer to come back to, only the call.
        c.wait_for(L.IN_CALL)
    for c in (a, b):
        c.click(L.LEAVE_CALL, settle=6)


def concurrent_edits_converge(a, b, admin_api, channel_id):
    """Both clients drag the same object at once, and everything settles.

    Every canvas scenario before this one is sequential: one client acts, the
    other watches it arrive. That proves the sync path carries a change, and
    says nothing about what happens when two changes race - which is the case
    a shared canvas exists to handle and the one where convergence bugs live.

    Genuinely simultaneous, on two threads, rather than one drag quickly
    followed by another: interleaving them by hand would let the first finish
    its round trip before the second starts, which is the sequential case
    again wearing a different hat.

    What is asserted is convergence, deliberately not a winner. Last write
    wins is a perfectly good answer here; a *blend* of the two drags is not,
    and neither is a value still moving after everyone stopped.

    Runs last among the canvas scenarios and reads the stroke count from the
    server rather than assuming it, so nothing downstream inherits whatever
    this leaves behind - the first draft hard-coded "2 strokes" and would have
    broken the moment an earlier scenario drew one more.

    Every tool it needs is selected explicitly. Two drafts failed on the tool
    left over from the step before: the drags found empty canvas with the pen
    still active, and then the closing stroke moved something with the select
    tool still active. A drag here means nothing without the tool it runs in.
    """
    image_id = object_of_kind(admin_api, channel_id, "image")["id"]
    before = admin_api.canvas_object(channel_id, image_id)
    strokes_before = sum(
        1 for o in admin_api.canvas_objects(channel_id) if o["kind"] == "stroke")

    # An object's position is in canvas coordinates; a drag is in screen ones.
    for c in (a, b):
        c.click(L.PAN_TOOL)
    org_a, org_b = origin(a), origin(b)
    centre_a = (org_a[0] + before["x"] + before["w"] / 2,
                org_a[1] + before["y"] + before["h"] / 2)
    centre_b = (org_b[0] + before["x"] + before["w"] / 2,
                org_b[1] + before["y"] + before["h"] / 2)

    def drag(client, centre, dx, dy):
        cx, cy = centre
        client.gestures(True)
        client.drag([(cx, cy), (cx + dx / 2, cy + dy / 2), (cx + dx, cy + dy)])
        client.gestures(False)

    threads = [
        threading.Thread(target=drag, args=(a, centre_a, 120, 0)),
        threading.Thread(target=drag, args=(b, centre_b, 0, 120)),
    ]
    for t in threads:
        t.start()
    for t in threads:
        t.join()
    time.sleep(3)

    settled = admin_api.canvas_object(channel_id, image_id)
    time.sleep(1.5)
    again = admin_api.canvas_object(channel_id, image_id)
    assert (settled["x"], settled["y"]) == (again["x"], again["y"]), \
        f"still moving after both drags stopped: {settled} then {again}"

    moved_x = abs(settled["x"] - (before["x"] + 120)) < 20
    moved_y = abs(settled["y"] - (before["y"] + 120)) < 20
    assert moved_x or moved_y, (
        "the object landed on neither drag's result, which is a blend of the "
        f"two rather than one of them winning: {before} -> {settled}")
    print(f"  both dragged at once; settled at "
          f"({settled['x']:.0f}, {settled['y']:.0f}) and stayed there")

    # A wedged sync loop looks identical to a healthy one until something moves.
    a.click(L.PEN_TOOL)
    a.gestures(True)
    a.drag([at(org_a, STROKE_START), at(org_a, STROKE_MID),
            at(org_a, STROKE_END)])
    a.gestures(False)
    want = strokes_before + 1
    wait_for_summary(b, f"{want} stroke" + ("" if want == 1 else "s"), timeout=45)
    print("  and the canvas is still live: a new stroke still reaches b")
