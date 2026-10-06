# SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
"""Generates hand-drawn-looking stroke geometry for canvas seeding.

Two straight-line endpoints read as machine-made the instant a real person
looks at the canvas, so every generator here is a noisy path: a random walk
with momentum for freehand doodles, a jittered ellipse, a wavy line, a
zigzag, and a bounded scribble. `split_stroke` mirrors the client's own
`splitStroke` (client/packages/voice_canvas/lib/src/stroke_splitter.dart): a stroke is split by its
*encoded byte size* against `MAX_PROPS_BYTES`, never by a point count, and a
split repeats the previous segment's last point so no seam shows.
"""
import json
import math

# Mirrors crates/slimm-server/src/http/canvas_write.rs's MAX_PROPS_BYTES.
MAX_PROPS_BYTES = 4 * 1024
# A cushion under the real ceiling for float-encoding differences.
SPLIT_BUDGET = MAX_PROPS_BYTES - 64


def freehand_stroke(rng, start, steps=40, step_length=(6, 14), turn_std=0.35,
                     jitter=1.0):
    """A random walk with momentum: a heading that drifts by small turns
    rather than resetting every step, plus a little per-point tremor."""
    x, y = start
    heading = rng.uniform(0, 2 * math.pi)
    points = [(x, y)]
    for _ in range(steps):
        heading += rng.gauss(0, turn_std)
        length = rng.uniform(*step_length)
        x += math.cos(heading) * length + rng.gauss(0, jitter)
        y += math.sin(heading) * length + rng.gauss(0, jitter)
        points.append((x, y))
    return points


def rough_ellipse(rng, center, rx, ry, points=48, wobble=0.06):
    """A closed loop around `center`, radius and angular step both jittered
    so it reads as a hand-drawn circle or oval rather than a geometric one."""
    cx, cy = center
    out = []
    angle = 0.0
    step = (2 * math.pi) / points
    for _ in range(points):
        angle += step * rng.uniform(0.7, 1.3)
        radius_noise = 1 + rng.gauss(0, wobble)
        out.append((cx + math.cos(angle) * rx * radius_noise,
                     cy + math.sin(angle) * ry * radius_noise))
    out.append(out[0])
    return out


def wavy_line(rng, start, end, amplitude=10, waves=3, points=40):
    """A sine wave from `start` to `end`, with a little noise on top of the
    clean sinusoid so it does not look plotted."""
    sx, sy = start
    ex, ey = end
    dx, dy = ex - sx, ey - sy
    length = math.hypot(dx, dy) or 1.0
    nx, ny = -dy / length, dx / length
    out = []
    for i in range(points + 1):
        t = i / points
        offset = (math.sin(t * waves * 2 * math.pi) * amplitude
                  + rng.gauss(0, amplitude * 0.15))
        out.append((sx + dx * t + nx * offset, sy + dy * t + ny * offset))
    return out


def zigzag(rng, start, end, segments=6, spread=14):
    """A jagged path alternating sides of the direct line, for a quick
    scratch-mark or arrow-like doodle."""
    sx, sy = start
    ex, ey = end
    dx, dy = ex - sx, ey - sy
    length = math.hypot(dx, dy) or 1.0
    nx, ny = -dy / length, dx / length
    out = [start]
    for i in range(1, segments):
        t = i / segments
        side = spread if i % 2 else -spread
        offset = side + rng.gauss(0, spread * 0.2)
        out.append((sx + dx * t + nx * offset, sy + dy * t + ny * offset))
    out.append(end)
    return out


def scribble_ball(rng, center, radius, steps=140, step_length=(4, 9),
                   turn_std=0.5):
    """A tangled freehand scribble kept roughly inside `radius` of `center`
    by steering back inward once a step would leave it, the way a person
    scribbling out a small area keeps circling back on themselves."""
    cx, cy = center
    x, y = cx, cy
    heading = rng.uniform(0, 2 * math.pi)
    points = [(x, y)]
    for _ in range(steps):
        heading += rng.gauss(0, turn_std)
        length = rng.uniform(*step_length)
        next_x = x + math.cos(heading) * length
        next_y = y + math.sin(heading) * length
        distance = math.hypot(next_x - cx, next_y - cy)
        if distance > radius:
            pull = min((distance - radius) / radius, 1.0)
            heading += math.atan2(cy - next_y, cx - next_x) * pull
            next_x = x + math.cos(heading) * length
            next_y = y + math.sin(heading) * length
        x, y = next_x, next_y
        points.append((x, y))
    return points


def quantize(points, ndigits=2):
    """Rounds every coordinate the way Dart's shortest-round-trip doubles
    and the client's own two-decimal quantization both narrow a stroke to
    before measuring its encoded size."""
    return [(round(x, ndigits), round(y, ndigits)) for x, y in points]


def _flatten(points):
    flat = []
    for x, y in points:
        flat.append(x)
        flat.append(y)
    return flat


def props_size(points, width, color):
    """The exact byte count the server measures: `serde_json`'s compact
    encoding of the whole `props` object, not just the point list."""
    payload = {"points": _flatten(points), "width": width, "color": color}
    return len(json.dumps(payload, separators=(",", ":")).encode("utf-8"))


def _relative_props_size(points, width, color):
    """The byte size a segment will actually encode at once it is offset to
    its own bounding box - what `stroke_placements` sends, not the size of
    the still-absolute coordinates this runs on during the split scan."""
    min_x, min_y, _, _ = bounding_box(points)
    relative = [(round(x - min_x, 2), round(y - min_y, 2)) for x, y in points]
    return props_size(relative, width, color)


def split_stroke(points, width, color, budget=SPLIT_BUDGET):
    """Splits `points` into segments whose *relative-encoded* props (see
    `_relative_props_size`) stay at or under `budget` bytes, repeating the
    previous segment's last point as the next segment's first so the split
    leaves no visible seam.

    The check measures the relative encoding rather than the still-absolute
    input, because offsetting each segment to its own top-left corner can
    grow or shrink its byte size versus the shared absolute coordinates -
    measuring the wrong one let a segment come back over `MAX_PROPS_BYTES`
    after `stroke_placements` re-encoded it relative to its own box.
    """
    if len(points) < 2:
        return [points]
    segments = []
    current = [points[0]]
    for point in points[1:]:
        candidate = current + [point]
        if (_relative_props_size(candidate, width, color) > budget
                and len(current) >= 2):
            segments.append(current)
            current = [current[-1], point]
        else:
            current = candidate
    segments.append(current)
    return segments


def bounding_box(points):
    xs = [p[0] for p in points]
    ys = [p[1] for p in points]
    return min(xs), min(ys), max(xs), max(ys)


def stroke_placements(points, width, color, next_id, budget=SPLIT_BUDGET):
    """Turns absolute-world `points` into one or more ready-to-send canvas
    object placements: split by encoded byte budget first (see
    `split_stroke`), then each segment's own bounding box becomes its
    `x`/`y`/`w`/`h`, with `props.points` made relative to that box's
    top-left corner - the shape `CanvasObjectPlacement` requires."""
    quantized = quantize(points)
    placements = []
    for segment in split_stroke(quantized, width, color, budget=budget):
        min_x, min_y, max_x, max_y = bounding_box(segment)
        relative = _flatten(
            [(round(x - min_x, 2), round(y - min_y, 2)) for x, y in segment])
        placements.append({
            "id": next_id(),
            "kind": "stroke",
            "x": min_x, "y": min_y,
            "w": round(max_x - min_x, 2), "h": round(max_y - min_y, 2),
            "props": {"points": relative, "width": width, "color": color},
        })
    return placements
