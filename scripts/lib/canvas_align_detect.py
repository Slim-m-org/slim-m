# SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
"""Finds the board and the reference markers in a screenshot (numpy arrays).

The board edge comes from the reference image itself: its flat background is
a colour no theme uses, and the client clips the image to the board.
"""
import numpy as np

from canvas_align_geometry import VISIBLE_SHARE, Frame, offset
from canvas_align_manifest import BOARD_H, BOARD_W

_EDGE_DISTANCE = 24
_EDGE_SHARE = 0.5
_ALPHA_FLOOR = 0.15
_MIX_RESIDUAL = 14
_MIN_COVERAGE_PX = 0.4
_SEARCH_MARGIN_PX = 8
_GAP_PX = 8
_SIDE_SHARE = 0.25
_EDGE_TRUST_PX = 0.75
_ASPECT_TRUST = 0.01


def _spans(mask):
    """The longest stretch of columns that are mostly the image field, grid-line gaps bridged."""
    counts = mask.sum(axis=0)
    wanted = np.flatnonzero(counts >= _EDGE_SHARE * counts.max())
    runs, first, last = [], int(wanted[0]), int(wanted[0])
    for index in wanted[1:]:
        if index - last > _GAP_PX:
            runs.append((first, last + 1))
            first = int(index)
        last = int(index)
    runs.append((first, last + 1))
    return max(runs, key=lambda run: run[1] - run[0])


def find_frame(rgb, image_bg):
    """The fitted board's rectangle, or None when the reference image is not on screen."""
    distance = np.abs(rgb.astype(float) - np.array(image_bg, float)).max(axis=2)
    mask = distance < _EDGE_DISTANCE
    if mask.sum() < 100:
        return None
    left, right = _spans(mask)
    top, bottom = _spans(mask.T)
    return Frame(float(left), float(top), float(right - left), float(bottom - top))


def _coverage(window, background, colour):
    """Per pixel, how much of it is [colour] over [background], 0 where it is neither."""
    background = np.array(background, float)
    axis = np.array(colour, float) - background
    delta = window.astype(float) - background
    alpha = np.clip((delta @ axis) / float(axis @ axis), 0.0, 1.0)
    residual = np.linalg.norm(delta - alpha[..., None] * axis, axis=2)
    alpha[(alpha < _ALPHA_FLOOR) | (residual > _MIX_RESIDUAL)] = 0.0
    return alpha


def find_marker(rgb, frame, marker, image_bg):
    """Where a marker is on screen: {x, y, visible} in pixels, or None when absent.

    [visible] is the share of a solid marker's area that is showing, 1.0 for
    shapes whose area is not known; UI drawn over a marker lowers it.
    """
    cx, cy = frame.to_px(marker["cx"], marker["cy"])
    half_w = marker["w"] / 2 * frame.scale_x + _SEARCH_MARGIN_PX
    half_h = marker["h"] / 2 * frame.scale_y + _SEARCH_MARGIN_PX
    x0, x1 = max(0, int(cx - half_w)), min(rgb.shape[1], int(cx + half_w) + 1)
    y0, y1 = max(0, int(cy - half_h)), min(rgb.shape[0], int(cy + half_h) + 1)
    if x1 <= x0 or y1 <= y0:
        return None
    alpha = _coverage(rgb[y0:y1, x0:x1], image_bg, marker["colour"])
    total = alpha.sum()
    if total < _MIN_COVERAGE_PX:
        return None
    if marker.get("style") == "outline":
        x, y = _outline_centre(alpha, x0, y0)
    else:
        ys, xs = np.mgrid[y0:y1, x0:x1]
        x = float((alpha * (xs + 0.5)).sum() / total)
        y = float((alpha * (ys + 0.5)).sum() / total)
    area = marker["w"] * marker["h"] * frame.scale_x * frame.scale_y
    visible = min(1.0, float(total) / area) if marker.get("style") == "solid" else 1.0
    return {"x": x, "y": y, "visible": visible}


def _side_centroids(profile):
    """The weighted positions of the first and last strong stretch of a coverage profile."""
    strong = np.flatnonzero(profile >= _SIDE_SHARE * profile.max())
    stretches = np.split(strong, np.flatnonzero(np.diff(strong) > 1) + 1)
    ends = [stretches[0], stretches[-1]]
    return [float((profile[s] * (s + 0.5)).sum() / profile[s].sum()) for s in ends]


def _outline_centre(alpha, x0, y0):
    """The middle of an outline from its sides, since a side's weight varies with where it lands."""
    left, right = _side_centroids(alpha.sum(axis=0))
    top, bottom = _side_centroids(alpha.sum(axis=1))
    return x0 + (left + right) / 2, y0 + (top + bottom) / 2


def _corner_frame(rgb, edge_frame, manifest):
    """The frame the fully visible image corner markers imply, or None with fewer than three."""
    corners, found = [], []
    for marker in manifest["markers"]:
        seen = find_marker(rgb, edge_frame, marker, manifest["image_bg"])
        if marker["name"].startswith("image-") and seen and seen["visible"] >= VISIBLE_SHARE:
            corners.append(marker)
            found.append(seen)
    if len(corners) < 3:
        return None
    left, scale_x = np.polyfit([m["cx"] for m in corners], [f["x"] for f in found], 1)[::-1]
    top, scale_y = np.polyfit([m["cy"] for m in corners], [f["y"] for f in found], 1)[::-1]
    return Frame(float(left), float(top), float(scale_x * BOARD_W), float(scale_y * BOARD_H))


def edge_gap(a, b):
    return max(abs(a.left - b.left), abs(a.top - b.top),
               abs(a.left + a.width - b.left - b.width),
               abs(a.top + a.height - b.top - b.height))


def _uniform(frame):
    """The board is fitted at one zoom, so both axes must agree to within rounding."""
    return abs(frame.scale_x - frame.scale_y) <= _ASPECT_TRUST * frame.scale_x


def board_frame(rgb, manifest):
    """The board's frame, where it came from and the edge-versus-corners gap in px (or None).

    The source is 'edge', 'corners' when UI hides the edge (a focus ring, a border), or
    'cut' when the edge is no use and fewer than three corners show, which means the
    board is partly under the header or the dock and no position can be trusted.
    """
    edge = find_frame(rgb, manifest["image_bg"])
    if edge is None:
        return None, None, None
    corners = _corner_frame(rgb, edge, manifest)
    if corners is not None and _uniform(corners):
        gap = edge_gap(edge, corners)
        return (corners, "corners", gap) if gap > _EDGE_TRUST_PX else (edge, "edge", gap)
    return (edge, "edge", None) if _uniform(edge) else (edge, "cut", None)


def measure(rgb, manifest):
    """Per marker offsets for one screenshot: (frame, source, gap, [{name, result, visible}])."""
    image_bg = manifest["image_bg"]
    frame, source, gap = board_frame(rgb, manifest)
    if frame is None:
        return None, None, None, []
    if source == "cut":
        return frame, source, gap, []
    rows = []
    for marker in manifest["markers"]:
        found = find_marker(rgb, frame, marker, image_bg)
        row = {"name": marker["name"], "result": None, "visible": 0.0}
        if found is not None:
            row["visible"] = found["visible"]
            row["result"] = offset(frame, (marker["cx"], marker["cy"]), (found["x"], found["y"]))
        rows.append(row)
    return frame, source, gap, rows
