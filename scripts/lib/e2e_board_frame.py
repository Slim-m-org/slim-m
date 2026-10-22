# SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
"""Where the shared board sits on a client's page.

The canvas is one fixed 1920x1080 world frame fitted to the surface and
letterboxed (docs/decisions/0073-shared-canvas-board.md). Most canvas
scenarios think in world pixels at zoom 1, so [fit_to_board_zoom_one] sizes
the window until the surface is exactly the board's width, and [board_frame]
says where the board starts on the page whatever the zoom is.
"""
import time

import e2e_labels as L
import e2e_png

BOARD_W = 1920
BOARD_H = 1080
_TALL = 1500
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
    _metrics(client, _WIDE_START - (rect["width"] - BOARD_W), _TALL)
    rect = client.canvas_rect()
    assert abs(rect["width"] - BOARD_W) < 1 and rect["height"] >= BOARD_H, \
        f"{client.name}: surface is {rect['width']}x{rect['height']}, not the board"


def set_window(client, width, height):
    _metrics(client, width, height)


def clear_window(client):
    client.send("Emulation.clearDeviceMetricsOverride")
    time.sleep(0.8)


_EDGE_DELTA = 3


def _first_change(client, rect, vertical):
    """Offset of the first pixel along a one-pixel strip that differs from the strip's first.

    The letterbox is a flat colour and the board edge is the first thing that
    is not, so this finds where the board starts without knowing the dock's
    height or where the zoom pill sits, both of which have moved before.
    """
    if vertical:
        strip = {"x": rect["x"] + rect["width"] * 0.6, "y": rect["y"],
                 "width": 1, "height": rect["height"]}
    else:
        strip = {"x": rect["x"], "y": rect["y"] + rect["height"] * 0.6,
                 "width": rect["width"], "height": 1}
    width, height, rows, channels = e2e_png.decode(client.region_png(strip))
    if vertical:
        pixels = [tuple(rows[y][:3]) for y in range(height)]
    else:
        pixels = [tuple(rows[0][x * channels:x * channels + 3])
                  for x in range(width)]
    for offset, pixel in enumerate(pixels):
        if max(abs(a - b) for a, b in zip(pixel, pixels[0])) > _EDGE_DELTA:
            return offset
    return 0


def board_frame(client):
    """The fitted board on the page: (left, top, zoom), read off the pixels."""
    rect = client.canvas_rect()
    # An edge hairline reads a pixel in; a board that fills the width starts at the surface.
    left = _first_change(client, rect, vertical=False)
    left = 0 if left <= 1 else left
    top = _first_change(client, rect, vertical=True)
    zoom = (rect["width"] - 2 * left) / BOARD_W
    return rect["x"] + left, rect["y"] + top, zoom


def board_point(client, world):
    """Where a board point is on [client]'s page."""
    left, top, zoom = board_frame(client)
    return left + world[0] * zoom, top + world[1] * zoom
