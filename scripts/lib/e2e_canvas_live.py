# SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
"""What a second browser sees of the first one's pointer and in-flight work.

Pixel comparisons of the watcher's canvas region, because a remote cursor and
an unfinished stroke are painted by custom painters with nothing in the
accessibility tree. The stroke check compares the watcher after a held drag
with the watcher after a plain hover along the same path: both end with the
cursor at the same point, so any difference is the stroke itself.

Each check counts changed pixels (a channel moving by more than PIXEL_DELTA)
and requires them where the thing should be, not merely anywhere in the
region. Measured on the e2e stack (headless Chrome, scale 1):

- a's cursor with its name label: 569 changed pixels, about half within 28px
  of the pointer and the rest in the label beside it, so the radius is 64px
  and the floor 300;
- the same cursor after a's pointer leaves the canvas: 0 changed pixels
  against the empty canvas, so at most 20 may remain (antialiasing);
- a's in-flight stroke: 658 changed pixels, all within 12px of the path,
  floor 350;
- the image displaced by (60, 42) mid-drag: 721 changed pixels inside its
  new box and outside its old one, floor 350.

Each floor is roughly half the measurement, far above the few pixels a stray
repaint (a speaking ring, a blinking caret) touches.
"""
import time

import e2e_labels as L
import e2e_png
from e2e_canvas import at, origin, wait_for_kind_count

PATH = [(60, 200), (100, 230), (140, 200), (180, 230), (220, 200)]
SETTLE = 0.8
PIXEL_DELTA = 24
CURSOR_RADIUS = 64
STROKE_DISTANCE = 12
MIN_CURSOR_PIXELS = 300
MIN_STROKE_PIXELS = 350
MIN_MOVE_PIXELS = 350
CURSOR_RESIDUE_PIXELS = 20


def changed_pixels(before, after):
    return e2e_png.changed_pixels(before, after, PIXEL_DELTA)


def poll_region(client, rect, baseline, enough, timeout=6.0):
    """The watcher's region and its changed pixels once [enough] accepts them.

    [enough] takes the pixel list; on timeout the last shot is returned, for
    the caller's own assertion to fail on.
    """
    deadline = time.time() + timeout
    while True:
        shot = client.region_png(rect)
        pixels = changed_pixels(baseline, shot)
        if enough(pixels) or time.time() >= deadline:
            return shot, pixels
        time.sleep(0.25)


def near_point(pixels, point, radius):
    return [p for p in pixels
            if (p[0] - point[0]) ** 2 + (p[1] - point[1]) ** 2 <= radius ** 2]


def _distance_to_segment(p, a, b):
    ax, ay = a
    dx, dy = b[0] - ax, b[1] - ay
    length = dx * dx + dy * dy
    t = 0 if length == 0 else max(
        0, min(1, ((p[0] - ax) * dx + (p[1] - ay) * dy) / length))
    return ((p[0] - ax - t * dx) ** 2 + (p[1] - ay - t * dy) ** 2) ** 0.5


def near_path(pixels, path, distance):
    return [p for p in pixels
            if any(_distance_to_segment(p, a, b) <= distance
                   for a, b in zip(path, path[1:]))]


def around(org, points, pad=24):
    """A page rect around [points] given as offsets from [org]: small enough
    to leave the speaking rings and the dock, which animate, out of it."""
    xs = [p[0] for p in points]
    ys = [p[1] for p in points]
    return {"x": org[0] + min(xs) - pad, "y": org[1] + min(ys) - pad,
            "width": max(xs) - min(xs) + 2 * pad,
            "height": max(ys) - min(ys) + 2 * pad}


def _to_region(points, pad=24):
    """Maps an offset from the canvas origin to a pixel of `around(points)`."""
    left = min(p[0] for p in points) - pad
    top = min(p[1] for p in points) - pad
    return lambda point: (point[0] - left, point[1] - top)


def _require(pixels, minimum, what):
    if len(pixels) < minimum:
        raise AssertionError(
            f"{what}: {len(pixels)} changed pixels, expected at least {minimum}")


def remote_cursor_shows(a, b):
    """`a` hovers over the canvas; `b` paints a cursor where it was empty."""
    rect = around(origin(b), PATH)
    org = origin(a)
    a.gestures(True)
    a.hover(*at(org, (20, 20)), settle=0.2)
    time.sleep(SETTLE)
    empty = b.region_png(rect)
    a.hover(*at(org, PATH[0]), settle=0.2)
    _, pixels = poll_region(
        b, rect, empty,
        lambda px: len(near_point(px, _to_region(PATH)(PATH[0]),
                                  CURSOR_RADIUS)) >= MIN_CURSOR_PIXELS)
    a.gestures(False)
    at_cursor = near_point(pixels, _to_region(PATH)(PATH[0]), CURSOR_RADIUS)
    print(f"  cursor: {len(at_cursor)} of {len(pixels)} changed pixels "
          f"within {CURSOR_RADIUS}px of a's pointer")
    _require(at_cursor, MIN_CURSOR_PIXELS, "b's view of a's cursor")
    if len(at_cursor) * 2 < len(pixels):
        raise AssertionError("b repainted mostly away from a's cursor")


def cursor_hides_when_pointer_leaves(a, b):
    """The `left` frame: `b` drops a's cursor once a's pointer leaves the canvas."""
    rect = around(origin(b), PATH)
    org = origin(a)
    a.gestures(True)
    a.hover(*at(org, (20, 20)), settle=0.2)
    time.sleep(SETTLE)
    empty = b.region_png(rect)
    a.hover(*at(org, PATH[0]), settle=0.2)
    shown, pixels = poll_region(
        b, rect, empty, lambda px: len(px) >= MIN_CURSOR_PIXELS)
    _require(pixels, MIN_CURSOR_PIXELS, "b's view of a's cursor before leaving")
    canvas = a.canvas_rect()
    a.hover(canvas["x"] - 12, canvas["y"] + canvas["height"] / 2, settle=0.2)
    _, residue = poll_region(
        b, rect, empty, lambda px: len(px) <= CURSOR_RESIDUE_PIXELS)
    a.gestures(False)
    print(f"  cursor: {len(pixels)} px shown, {len(residue)} px left "
          "after a's pointer left the canvas")
    if len(residue) > CURSOR_RESIDUE_PIXELS:
        b.shot("cursor-stuck-after-leave")
        raise AssertionError("b still shows a's cursor after the pointer left")


def strokes_on_server(admin_api, channel_id):
    return sum(1 for o in admin_api.canvas_objects(channel_id)
               if o["kind"] == "stroke")


def stroke_shows_before_release(a, b, admin_api, channel_id):
    """`b` sees the stroke along the path while `a` still holds the pointer down.

    The stroke is committed on release, so it is undone afterwards: the
    scenarios after this one count the canvas's strokes.
    """
    already = strokes_on_server(admin_api, channel_id)
    rect = around(origin(b), PATH)
    org = origin(a)
    a.gestures(True)
    for point in PATH:
        a.hover(*at(org, point), settle=0.05)
    time.sleep(0.15)
    a.hover(*at(org, PATH[-1]), settle=0.05)
    time.sleep(SETTLE)
    hovered = b.region_png(rect)
    a.hover(*at(org, PATH[0]), settle=0.2)
    a.press(*at(org, PATH[0]))
    a.move_held([at(org, p) for p in PATH[1:]])
    time.sleep(0.15)
    a.move_held([at(org, PATH[-1])])
    time.sleep(SETTLE)
    local = _to_region(PATH)
    local_path = [local(p) for p in PATH]
    _, pixels = poll_region(
        b, rect, hovered,
        lambda px: len(near_path(px, local_path, STROKE_DISTANCE))
        >= MIN_STROKE_PIXELS)
    a.release(*at(org, PATH[-1]))
    a.gestures(False)
    on_path = near_path(pixels, local_path, STROKE_DISTANCE)
    print(f"  stroke: {len(on_path)} of {len(pixels)} changed pixels "
          f"within {STROKE_DISTANCE}px of the path")
    if len(on_path) < MIN_STROKE_PIXELS:
        b.shot("no-live-stroke")
        raise AssertionError(
            f"b saw {len(on_path)} stroke pixels before release, "
            f"expected at least {MIN_STROKE_PIXELS}")
    print("  b saw a's stroke while a still held the pointer")
    wait_for_kind_count(admin_api, channel_id, "stroke", already + 1)
    a.click(L.UNDO)
    wait_for_kind_count(admin_api, channel_id, "stroke", already)


def move_shows_before_release(a, b, admin_api, channel_id):
    """`b` sees the image displaced into its new box while `a` holds it mid-drag.

    The drag returns to its start before release, so nothing is committed and
    the later scenarios find the image where they expect it.
    """
    from e2e_canvas import object_of_kind

    org = origin(a)
    image = object_of_kind(admin_api, channel_id, "image")
    centre = (org[0] + image["x"] + image["w"] / 2,
              org[1] + image["y"] + image["h"] / 2)
    shift = (60, 42)
    away = [(centre[0] + dx, centre[1] + dy)
            for dx, dy in ((20, 14), (40, 28), shift)]
    old = [(image["x"], image["y"]),
           (image["x"] + image["w"], image["y"] + image["h"])]
    new = [(x + shift[0], y + shift[1]) for x, y in old]
    rect = around(origin(b), old + new, pad=8)
    local = _to_region(old + new, pad=8)
    (nx0, ny0), (nx1, ny1) = (local(p) for p in new)
    (ox0, oy0), (ox1, oy1) = (local(p) for p in old)

    def newly_covered(pixels):
        """Inside the new box and outside the old one: only a displaced image paints here."""
        return [p for p in pixels
                if nx0 <= p[0] <= nx1 and ny0 <= p[1] <= ny1
                and not (ox0 <= p[0] <= ox1 and oy0 <= p[1] <= oy1)]

    a.gestures(True)
    for point in away:
        a.hover(*point, settle=0.05)
    time.sleep(0.15)
    a.hover(*away[-1], settle=0.05)
    time.sleep(SETTLE)
    hovered = b.region_png(rect)
    a.hover(*centre, settle=0.2)
    a.press(*centre)
    a.move_held(away)
    time.sleep(0.15)
    a.move_held([away[-1]])
    time.sleep(SETTLE)
    _, pixels = poll_region(
        b, rect, hovered, lambda px: len(newly_covered(px)) >= MIN_MOVE_PIXELS)
    a.move_held([centre])
    a.release(*centre)
    a.gestures(False)
    moved = newly_covered(pixels)
    print(f"  move: {len(moved)} of {len(pixels)} changed pixels in the "
          "image's new box")
    if len(moved) < MIN_MOVE_PIXELS:
        b.shot("no-live-move")
        raise AssertionError(
            f"b saw {len(moved)} pixels of the image at its new position "
            f"before release, expected at least {MIN_MOVE_PIXELS}")
    print("  b saw the image move while a still held it")
