# SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
"""Where the shared board sits on a client's page.

A canvas opens on the 1920x1080 shared area at the zoom that fits it, inside a
board twice that size (docs/decisions/0073-shared-canvas-board.md). Most canvas
scenarios think in world pixels at zoom 1, so [fit_to_board_zoom_one] sizes
the window until the surface is exactly the shared area's width, and
[board_frame] says where the shared area starts on the page.

The shared area has no visible edge, so the dock's share of the surface is read
from the letterbox under the board in a window tall enough to be set by the
board's height, and the area is centred above it.
"""
import json
import time

import e2e_labels as L
import e2e_png

SHARED_W = 1920
SHARED_H = 1080
_TALL = 1500
_FULL_BOARD_WINDOW_H = 2700
_dock_insets = {}
_WIDE_START = 2600


def _metrics(client, width, height):
    client.send("Emulation.setDeviceMetricsOverride", {
        "width": int(width), "height": int(height),
        "deviceScaleFactor": 1, "mobile": False})
    time.sleep(1.0)


def fit_to_board_zoom_one(client):
    """Sizes the window so the surface is the board's width and taller.

    The docked member list goes first (the header's members button closes it), and the surface would widen under a window sized
    with it open.
    """
    if client.find(L.MEMBER_PANE_HEADER):
        client.click(L.MEMBER_LIST)
    _metrics(client, _WIDE_START, _TALL)
    rect = client.canvas_rect()
    _metrics(client, _WIDE_START - (rect["width"] - SHARED_W), _TALL)
    rect = client.canvas_rect()
    assert abs(rect["width"] - SHARED_W) < 1 and rect["height"] >= SHARED_H, \
        f"{client.name}: surface is {rect['width']}x{rect['height']}, not the shared area"
    _dock_insets.pop(client.name, None)


def set_window(client, width, height):
    _metrics(client, width, height)
    _dock_insets.pop(client.name, None)


def clear_window(client):
    client.send("Emulation.clearDeviceMetricsOverride")
    time.sleep(0.8)


_EDGE_DELTA = 3


def _letterbox_at_foot(client, rect):
    """How many pixels below the board's foot are letterbox, read up a strip clear of the dock.

    The board is centred on the view above the dock and the view never leaves
    the board, so in a window tall enough that the board's height sets the
    zoom, the board ends exactly where the dock's share begins; the strip
    below that edge is the flat letterbox colour.
    """
    strip = {"x": rect["x"] + rect["width"] * 0.05, "y": rect["y"],
             "width": 1, "height": rect["height"]}
    _, height, rows, _ = e2e_png.decode(client.region_png(strip))
    pixels = [tuple(rows[y][:3]) for y in range(height)][::-1]
    for offset, pixel in enumerate(pixels):
        if max(abs(a - b) for a, b in zip(pixel, pixels[0])) > _EDGE_DELTA:
            return offset
    return 0


def _window_size(client):
    width, height = json.loads(client.ev("JSON.stringify([innerWidth, innerHeight])"))
    return width, height


def _dock_inset(client):
    """What the dock takes from the surface's foot, read once per window size.

    A window tall enough that the board's height sets the zoom leaves the
    dock's share of the surface below the board, as letterbox.
    """
    if client.name not in _dock_insets:
        width, height = _window_size(client)
        _metrics(client, width, _FULL_BOARD_WINDOW_H)
        rect = client.canvas_rect()
        inset = _letterbox_at_foot(client, rect)
        assert inset > 1, f"{client.name}: no letterbox under the board in a {width}x{_FULL_BOARD_WINDOW_H} window"
        _metrics(client, width, height)
        _dock_insets[client.name] = float(inset)
    return _dock_insets[client.name]


def board_frame(client):
    """The shared area on the page: (left, top, zoom).

    The area is fitted by its width, so it starts at the surface's left, and it
    sits centred in the surface above the dock.
    """
    inset = _dock_inset(client)
    rect = client.canvas_rect()
    zoom = rect["width"] / SHARED_W
    top = (rect["height"] - inset - SHARED_H * zoom) / 2
    return rect["x"], rect["y"] + top, zoom


def board_point(client, world):
    """Where a shared-area point is on [client]'s page."""
    left, top, zoom = board_frame(client)
    return left + world[0] * zoom, top + world[1] * zoom
