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

    The docked member list goes first: Escape closes it (the scenarios press
    Escape to dismiss menus), and the surface would widen under a window sized
    with it open.
    """
    if client.find(L.CLOSE_MEMBER_LIST):
        client.click(L.CLOSE_MEMBER_LIST)
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


def board_frame(client):
    """The fitted board on the page: (left, top, zoom)."""
    rect = client.canvas_rect()
    zoom = min(rect["width"] / BOARD_W, rect["height"] / BOARD_H)
    left = rect["x"] + (rect["width"] - BOARD_W * zoom) / 2
    top = rect["y"] + (rect["height"] - BOARD_H * zoom) / 2
    return left, top, zoom


def board_point(client, world):
    """Where a board point is on [client]'s page."""
    left, top, zoom = board_frame(client)
    return left + world[0] * zoom, top + world[1] * zoom
