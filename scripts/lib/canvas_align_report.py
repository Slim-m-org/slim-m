# SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
"""Runs the measurement over screenshots and prints the offset table."""
import json
import os

import safe_paths
from canvas_align_geometry import TOLERANCE_PX, VISIBLE_SHARE, distance_px, within_tolerance

_SOURCE_NOTE = {"edge": "the board edge",
                "corners": "the image corners, the edge is covered by UI"}


def _gap_note(gap):
    return "" if gap is None else f"; edge and corners differ by {gap:.2f}px"


def load_manifest(path):
    with open(safe_paths.home_or_cwd(path), encoding="utf-8") as handle:
        return json.load(handle)


def _imaging():
    try:
        import numpy
        from PIL import Image
    except ImportError as exc:
        raise SystemExit(f"measure needs Pillow and numpy ({exc}); "
                         "pip install pillow numpy, or use scripts/lib/.venv") from exc
    return numpy, Image


def measure_file(path, manifest):
    """Offsets for one screenshot: (frame or None, source, edge gap, rows, rgb array)."""
    import canvas_align_detect as detect
    numpy, image_module = _imaging()
    with image_module.open(path) as shot:
        rgb = numpy.asarray(shot.convert("RGB"))
    frame, source, gap, rows = detect.measure(rgb, manifest)
    return frame, source, gap, rows, rgb


def format_rows(label, frame, source, gap, rows, tolerance):
    """One table line per marker; returns (lines, ok)."""
    if frame is None:
        return [f"{label:<14} board not found in the screenshot"], False
    if source == "cut":
        return [f"{label:<14} board cut by the UI: edges give {frame.width:.0f}x{frame.height:.0f}px "
                f"and fewer than three corner markers show, so no position can be trusted"], False
    lines, ok = [], True
    head = (f"{label:<14} board {frame.width:.0f}x{frame.height:.0f}px "
            f"at ({frame.left:.1f},{frame.top:.1f}) scale {frame.scale_x:.4f}/{frame.scale_y:.4f}"
            f" (frame from {_SOURCE_NOTE[source]}{_gap_note(gap)})")
    lines.append(head)
    for row in rows:
        result = row["result"]
        if result is None:
            ok = False
            lines.append(f"  {row['name']:<11} not found  FAIL")
            continue
        if row["visible"] < VISIBLE_SHARE:
            lines.append(f"  {row['name']:<11} {row['visible']:.0%} showing, covered by UI  skipped")
            continue
        good = within_tolerance(result, tolerance)
        ok = ok and good
        lines.append(
            f"  {row['name']:<11} dx {result['dx_px']:+6.2f}px dy {result['dy_px']:+6.2f}px"
            f"   dx {result['dx_board']:+6.2f}u dy {result['dy_board']:+6.2f}u"
            f"   |d| {distance_px(result):5.2f}px  {'ok' if good else 'FAIL'}")
    return lines, ok


def annotate(rgb, frame, rows, manifest, path):
    """Saves the screenshot with the board outline and expected (white) versus found (red) marks."""
    _, image_module = _imaging()
    from PIL import ImageDraw
    canvas = image_module.fromarray(rgb)
    draw = ImageDraw.Draw(canvas)
    draw.rectangle([frame.left, frame.top, frame.left + frame.width, frame.top + frame.height],
                   outline=(255, 255, 255))
    for marker, row in zip(manifest["markers"], rows):
        ex, ey = frame.to_px(marker["cx"], marker["cy"])
        draw.line([ex - 6, ey, ex + 6, ey], fill=(255, 255, 255))
        draw.line([ex, ey - 6, ex, ey + 6], fill=(255, 255, 255))
        if row["result"]:
            fx, fy = ex + row["result"]["dx_px"], ey + row["result"]["dy_px"]
            draw.ellipse([fx - 3, fy - 3, fx + 3, fy + 3], outline=(255, 0, 0))
    canvas.save(path)


def run(paths, manifest_path, tolerance=TOLERANCE_PX, annotate_dir=None):
    """Prints the table for every screenshot; the exit code is 1 on any miss or drift."""
    manifest = load_manifest(manifest_path)
    all_ok = True
    for path in paths:
        label = os.path.splitext(os.path.basename(path))[0]
        frame, source, gap, rows, rgb = measure_file(path, manifest)
        lines, ok = format_rows(label, frame, source, gap, rows, tolerance)
        print("\n".join(lines))
        all_ok = all_ok and ok
        if annotate_dir and frame is not None:
            annotate_dir = safe_paths.home_or_cwd(annotate_dir)
            os.makedirs(annotate_dir, exist_ok=True)
            annotate(rgb, frame, rows, manifest, os.path.join(annotate_dir, f"{label}-diff.png"))
    print(f"tolerance {tolerance:g}px: {'PASS' if all_ok else 'FAIL'}")
    return 0 if all_ok else 1
