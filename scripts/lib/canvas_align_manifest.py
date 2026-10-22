# SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
"""The reference scene of the canvas alignment test and its manifest.

Every object sits at a board coordinate chosen here, so a client's screenshot
can be compared with where each marker should be. The board is the fixed
1920x1080 frame of decision 0073, top-left at the world origin.
"""
import struct
import zlib

BOARD_W = 1920
BOARD_H = 1080

# Pure, saturated colours that no theme token uses, so a marker is findable on any background.
IMAGE_BG = (250, 244, 214)
_GRID = (222, 214, 184)
_TICK = 100
_TICK_THICKNESS = 2
_CORNER_SIZE = 80
_CORNER_INSET = 40
_CORNER_COLOURS = {
    "image-tl": (230, 0, 0),
    "image-tr": (0, 190, 0),
    "image-bl": (0, 0, 230),
    "image-br": (200, 0, 200),
}
# What the client paints a shape and a pen colour key as (AppCanvasColors).
SHAPE_COLOUR = (0x5B, 0x8F, 0xD6)
STROKE_COLOUR = (0x6F, 0xBF, 0x73)
STROKE_COLOUR_KEY = "green"
STROKE_WIDTH = 10

SQUARE = (1300, 200, 300, 300)
DOT = (955, 535, 10, 10)
_STROKE_INSET = 60


def _corner_centres():
    near = _CORNER_INSET + _CORNER_SIZE / 2
    return {
        "image-tl": (near, near),
        "image-tr": (BOARD_W - near, near),
        "image-bl": (near, BOARD_H - near),
        "image-br": (BOARD_W - near, BOARD_H - near),
    }


def _marker(name, colour, cx, cy, extent_w, extent_h, style="solid"):
    """[style] says how to read a centre: 'solid' and 'line' by centroid, 'outline' by its two sides."""
    return {"name": name, "colour": list(colour), "cx": cx, "cy": cy,
            "w": extent_w, "h": extent_h, "style": style}


def markers():
    """What the measure step looks for: a colour, a board centre and the extent to search."""
    found = [_marker(name, _CORNER_COLOURS[name], cx, cy, _CORNER_SIZE, _CORNER_SIZE)
             for name, (cx, cy) in _corner_centres().items()]
    x, y, w, h = SQUARE
    found.append(_marker("square", SHAPE_COLOUR, x + w / 2, y + h / 2, w, h, "outline"))
    stroke_span = w - 2 * _STROKE_INSET
    found.append(_marker("drawing", STROKE_COLOUR, x + w / 2, y + h / 2,
                         stroke_span + STROKE_WIDTH, stroke_span + STROKE_WIDTH, "line"))
    x, y, w, h = DOT
    found.append(_marker("dot-10x10", SHAPE_COLOUR, x + w / 2, y + h / 2, w, h, "outline"))
    return found


def reference_png():
    """The 1920x1080 reference image, one pixel per board unit, as PNG bytes."""
    rows = bytearray()
    for y in range(BOARD_H):
        rows += b"\x00" + bytes(_row(y))
    return _encode_png(BOARD_W, BOARD_H, bytes(rows))


def _on_grid_line(value):
    return value % _TICK < _TICK_THICKNESS


def _row(y):
    row = bytearray()
    row_is_line = _on_grid_line(y)
    for x in range(BOARD_W):
        row += bytes(_GRID if row_is_line or _on_grid_line(x) else IMAGE_BG)
    for name, (cx, cy) in _corner_centres().items():
        half = _CORNER_SIZE / 2
        if cy - half <= y < cy + half:
            start, stop = int(cx - half), int(cx + half)
            row[start * 3:stop * 3] = bytes(_CORNER_COLOURS[name]) * (stop - start)
    return row


def _chunk(kind, payload):
    body = kind + payload
    return struct.pack(">I", len(payload)) + body + struct.pack(">I", zlib.crc32(body))


def _encode_png(width, height, raw):
    header = struct.pack(">IIBBBBB", width, height, 8, 2, 0, 0, 0)
    return (b"\x89PNG\r\n\x1a\n" + _chunk(b"IHDR", header)
            + _chunk(b"IDAT", zlib.compress(raw, 9)) + _chunk(b"IEND", b""))


def placements(attachment, new_id):
    """The four objects to place, in z order: image, square, drawing, 10x10 dot.

    [attachment] is the upload's answer for [reference_png]; [new_id] makes a UUIDv7.
    """
    sx, sy, sw, sh = SQUARE
    dx, dy, dw, dh = DOT
    span = sw - 2 * _STROKE_INSET
    drawing_box = span + STROKE_WIDTH
    return [
        {"id": new_id(), "kind": "image", "x": 0, "y": 0, "w": BOARD_W, "h": BOARD_H,
         "props": {"attachment": attachment["id"],
                   "content_type": attachment["content_type"],
                   "width": BOARD_W, "height": BOARD_H}},
        {"id": new_id(), "kind": "shape", "x": sx, "y": sy, "w": sw, "h": sh,
         "props": {"shape": "rectangle"}},
        {"id": new_id(), "kind": "stroke",
         "x": sx + sw / 2 - drawing_box / 2, "y": sy + sh / 2 - drawing_box / 2,
         "w": drawing_box, "h": drawing_box,
         "props": {"points": [STROKE_WIDTH / 2, STROKE_WIDTH / 2,
                              STROKE_WIDTH / 2 + span, STROKE_WIDTH / 2 + span],
                   "width": STROKE_WIDTH, "color": STROKE_COLOUR_KEY}},
        {"id": new_id(), "kind": "shape", "x": dx, "y": dy, "w": dw, "h": dh,
         "props": {"shape": "rectangle"}},
    ]


def build_manifest(base_url, channel, placed):
    """The JSON the later steps read: where the board is and what sits on it."""
    return {
        "version": 1,
        "board": {"w": BOARD_W, "h": BOARD_H},
        "base_url": base_url,
        "channel_id": channel["id"],
        "channel_name": channel["name"],
        "image_bg": list(IMAGE_BG),
        "objects": [{"id": o["id"], "kind": o["kind"], "x": o["x"], "y": o["y"],
                     "w": o["w"], "h": o["h"]} for o in placed],
        "markers": markers(),
    }
