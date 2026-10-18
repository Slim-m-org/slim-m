# SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
"""What a second browser sees of the first one's pointer and in-flight work.

Pixel comparisons of the watcher's canvas region, because a remote cursor and
an unfinished stroke are painted by custom painters with nothing in the
accessibility tree. The stroke check compares the watcher after a held drag
with the watcher after a plain hover along the same path: both end with the
cursor at the same point, so any difference is the stroke itself.
"""
import time

from e2e_canvas import at, origin

PATH = [(60, 200), (100, 230), (140, 200), (180, 230), (220, 200)]
SETTLE = 0.8


def changed(before, after):
    return before != after


def poll_region(client, rect, differs_from, timeout=6.0):
    """The watcher's region once it differs from [differs_from], else the last."""
    deadline = time.time() + timeout
    shot = client.region_png(rect)
    while not changed(differs_from, shot) and time.time() < deadline:
        time.sleep(0.25)
        shot = client.region_png(rect)
    return shot


def around(org, points, pad=24):
    """A page rect around [points] given as offsets from [org]: small enough
    to leave the speaking rings and the dock, which animate, out of it."""
    xs = [p[0] for p in points]
    ys = [p[1] for p in points]
    return {"x": org[0] + min(xs) - pad, "y": org[1] + min(ys) - pad,
            "width": max(xs) - min(xs) + 2 * pad,
            "height": max(ys) - min(ys) + 2 * pad}


def remote_cursor_shows(a, b):
    """`a` hovers over the canvas; `b` paints something where it was empty."""
    rect = around(origin(b), PATH)
    org = origin(a)
    a.gestures(True)
    a.hover(*at(org, (20, 20)), settle=0.2)
    time.sleep(SETTLE)
    empty = b.region_png(rect)
    a.hover(*at(org, PATH[0]), settle=0.2)
    shot = poll_region(b, rect, empty)
    a.gestures(False)
    if not changed(empty, shot):
        raise AssertionError("b never painted a's cursor")
    print("  a's cursor appeared on b's canvas")


def stroke_shows_before_release(a, b):
    """`b` sees the stroke while `a` still holds the pointer down."""
    org = origin(b)
    rect = around(org, PATH)
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
    held = poll_region(b, rect, hovered)
    a.release(*at(org, PATH[-1]))
    a.gestures(False)
    if not changed(hovered, held):
        b.shot("no-live-stroke")
        raise AssertionError("b saw nothing of a's stroke before release")
    print("  b saw a's stroke while a still held the pointer")


def move_shows_before_release(a, b, admin_api, channel_id):
    """`b` sees the image displaced while `a` still holds it mid-drag.

    The drag returns to its start before release, so nothing is committed and
    the later scenarios find the image where they expect it.
    """
    from e2e_canvas import object_of_kind

    org = origin(a)
    image = object_of_kind(admin_api, channel_id, "image")
    centre = (org[0] + image["x"] + image["w"] / 2,
              org[1] + image["y"] + image["h"] / 2)
    away = [(centre[0] + dx, centre[1] + dy)
            for dx, dy in ((20, 14), (40, 28), (60, 42))]
    b_org = origin(b)
    rect = around(b_org, [(image["x"], image["y"]),
                          (image["x"] + image["w"], image["y"] + image["h"])])
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
    held = poll_region(b, rect, hovered)
    a.move_held([centre])
    a.release(*centre)
    a.gestures(False)
    if not changed(hovered, held):
        b.shot("no-live-move")
        raise AssertionError("b saw nothing of a's drag before release")
    print("  b saw the image move while a still held it")
