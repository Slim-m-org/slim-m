# SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
"""The shared board: the same content at the same relative place on two
windows of different size, and follow and "bring everyone to me".

Decision 0073. `a` keeps the window sized to the board (zoom 1) and `b` gets
a smaller, differently shaped one, so a stroke has to land in the same place
of the board on both without either client doing any translating of its own.
"""
import re
import time

import e2e_labels as L
import e2e_png
from e2e_input import _modifier_key
from e2e_api import wait_until
from e2e_board_frame import (BOARD_H, BOARD_W, board_frame, board_point,
                             fit_to_board_zoom_one, set_window)
from e2e_canvas import wait_for_summary

SMALL_WINDOW = (1100, 900)
ZIGZAG = [(300, 500), (800, 500), (300, 560), (800, 560), (300, 620),
          (800, 620)]
PIXEL_DELTA = 24
MIN_PIXELS = 25
POSITION_TOLERANCE = 0.02
_ZOOM = re.compile(r"zoom (\d+) percent")


def _region_around(client, points, pad=30):
    pages = [board_point(client, p) for p in points]
    xs = [p[0] for p in pages]
    ys = [p[1] for p in pages]
    return {"x": min(xs) - pad, "y": min(ys) - pad,
            "width": max(xs) - min(xs) + 2 * pad,
            "height": max(ys) - min(ys) + 2 * pad}


def _relative_centre(client, rect, pixels):
    """Where the changed pixels' centre sits on the board, as 0..1 fractions."""
    left, top, zoom = board_frame(client)
    cx = rect["x"] + sum(p[0] for p in pixels) / len(pixels)
    cy = rect["y"] + sum(p[1] for p in pixels) / len(pixels)
    return (cx - left) / (BOARD_W * zoom), (cy - top) / (BOARD_H * zoom)


def same_relative_position_on_different_windows(a, b, admin_api, channel_id):
    set_window(b, *SMALL_WINDOW)
    _, _, zoom_a = board_frame(a)
    _, _, zoom_b = board_frame(b)
    assert zoom_b < zoom_a * 0.9, f"b's window should be smaller: {zoom_b} vs {zoom_a}"

    rects = {c.name: _region_around(c, ZIGZAG) for c in (a, b)}
    before = {c.name: c.region_png(rects[c.name]) for c in (a, b)}
    base = len(admin_api.canvas_objects(channel_id))

    a.gestures(True)
    page = [board_point(a, p) for p in ZIGZAG]
    a.drag(page)
    a.gestures(False)
    a.hover(5, 5, settle=1.5)
    wait_until(lambda: len(admin_api.canvas_objects(channel_id)),
               lambda n: n > base, "the zigzag never reached the server")
    for c in (a, b):
        wait_for_summary(c, f"{base + 1} object", timeout=30)
    time.sleep(1.0)

    stroke = [o for o in admin_api.canvas_objects(channel_id)
              if o["kind"] == "stroke"][-1]
    want = ((stroke["x"] + stroke["w"] / 2) / BOARD_W,
            (stroke["y"] + stroke["h"] / 2) / BOARD_H)
    for c in (a, b):
        after = c.region_png(rects[c.name])
        pixels = e2e_png.changed_pixels(before[c.name], after, PIXEL_DELTA)
        assert len(pixels) >= MIN_PIXELS, \
            f"{c.name}: only {len(pixels)} pixels changed where the stroke belongs"
        got = _relative_centre(c, rects[c.name], pixels)
        assert abs(got[0] - want[0]) < POSITION_TOLERANCE and \
            abs(got[1] - want[1]) < POSITION_TOLERANCE, \
            f"{c.name}: stroke centre at {got}, the board says {want}"
    print(f"  the stroke sits at {want[0]:.3f}, {want[1]:.3f} of the board on "
          f"both a (zoom {zoom_a:.2f}) and b (zoom {zoom_b:.2f})")


def zoom_percent(client):
    node = client.wait_for(L.FIT_VIEW + ", zoom")
    return int(_ZOOM.search(node["t"]).group(1))


def _near(zoom, other, tolerance=0.06):
    """Two viewports fit the same content a few percent apart, so a follow lands near, not on."""
    return abs(zoom - other) <= other * tolerance


def _settled_zoom(client, hold=0.6, timeout=10):
    """The zoom once it has stopped moving; a fit animates, so the first read is mid-flight."""
    deadline = time.time() + timeout
    last, since = None, time.time()
    while time.time() < deadline:
        now = zoom_percent(client)
        if now != last:
            last, since = now, time.time()
        elif time.time() - since >= hold:
            return now
        time.sleep(0.1)
    return last


def _ctrl_wheel(client, delta, notches=5):
    """Ctrl plus wheel over the surface, the way a mouse zooms it.

    Flutter reads Control from the key events, not from the wheel event's own
    modifiers, so the key is pressed around the notches.
    """
    rect = client.canvas_rect()
    client.gestures(True)
    client.send("Input.dispatchKeyEvent",
                _modifier_key("Control", "ControlLeft", 17, "keyDown", 2))
    for _ in range(notches):
        client.send("Input.dispatchMouseEvent", {
            "type": "mouseWheel", "x": rect["x"] + rect["width"] / 2,
            "y": rect["y"] + rect["height"] / 2, "deltaX": 0, "deltaY": delta,
            "modifiers": 2})
        time.sleep(0.1)
    client.send("Input.dispatchKeyEvent",
                _modifier_key("Control", "ControlLeft", 17, "keyUp", 0))
    client.gestures(False)
    time.sleep(1.0)


def _follow_label(client):
    node = client.find(L.FOLLOW_PREFIX)
    return node["t"] if node else None


def _wait_zoom(client, ok, what, timeout=15):
    seen = []

    def read():
        seen.append(zoom_percent(client))
        return seen[-1]

    try:
        wait_until(read, ok, "", timeout)
    except AssertionError:
        raise AssertionError(f"{client.name}: {what} (zoom read {seen[-1]}%)")


def follow_and_bring_everyone(a, b):
    fit_to_board_zoom_one(b)
    assert zoom_percent(a) == 100 and zoom_percent(b) == 100

    label = _follow_label(b)
    assert label, "b has no one to follow while a is in the canvas and the call"
    b.click(label)
    _ctrl_wheel(a, -100, notches=2)
    assert zoom_percent(a) > 100
    _wait_zoom(b, lambda z: z > 100, "never followed a's zoom")
    print("  b follows a: a zoomed in, so b did")

    # Fit view fits what is drawn, so on a board with content it is not 100.
    a.click(L.FIT_VIEW)
    fit = _settled_zoom(a)
    _wait_zoom(b, lambda z: _near(z, fit), "did not follow a back to the fit")

    _ctrl_wheel(a, -100, notches=2)
    _wait_zoom(b, lambda z: not _near(z, fit), "stopped following early")
    _ctrl_wheel(b, -100, notches=1)
    assert not b.find("Following"), "b still follows after its own zoom"
    assert _follow_label(b), "b's follow control did not come back"
    own = zoom_percent(b)
    a.click(L.FIT_VIEW)
    time.sleep(1.5)
    assert _near(zoom_percent(b), own), "b followed a after it stopped following"
    print("  b's own zoom ended the follow, and a's next move left b alone")

    b.click(L.FIT_VIEW)
    _wait_zoom(b, lambda z: _near(z, fit), "b could not fit")
    _ctrl_wheel(a, -100, notches=2)
    a.click(L.BRING_EVERYONE)
    a.click(L.BRING_EVERYONE_CONFIRM, settle=2)  # the confirm dialog's own button
    _wait_zoom(b, lambda z: not _near(z, fit), "was not brought to a")
    print("  bring everyone to me jumped b to a's view")

    a.click(L.FIT_VIEW)
    b.click(L.FIT_VIEW)
    _wait_zoom(b, lambda z: _near(z, fit), "b could not fit afterwards")
