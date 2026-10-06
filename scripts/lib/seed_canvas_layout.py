# SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
"""Where seeded canvas objects land: clustered, not scattered uniformly.

A real board has busy regions and empty space, not an even grid - and
docs/research/canvas-spike-client.md records that clustering is the case
that matters for the client's spatial index (an 8.5x regression when
objects crowd one grid cell), so a uniform scatter would be the easy case
rather than the honest one.
"""
import math

# The three canvas ink tokens AppCanvasColors defines; only one paints today.
COLOR_KEYS = ("annotation", "note", "shape")

# Mirrors canvas_quick_placement.dart's own note/shape defaults, so a seeded object matches one placed by hand.
DEFAULT_NOTE_WIDTH = 220
DEFAULT_NOTE_HEIGHT = 140
DEFAULT_SHAPE_WIDTH = 180
DEFAULT_SHAPE_HEIGHT = 120

SHAPE_KINDS = ("rectangle", "ellipse", "line", "arrow")


def cluster_centers(rng, count, x_range=(-4000, 4000), y_range=(-2500, 2500),
                     min_gap=900):
    """`count` cluster centers, spaced at least `min_gap` apart where the
    range allows it; falls back to an unspaced pick rather than looping
    forever if packing that many centers that far apart is not possible."""
    centers = []
    attempts = 0
    while len(centers) < count and attempts < count * 50:
        attempts += 1
        candidate = (rng.uniform(*x_range), rng.uniform(*y_range))
        if all(math.hypot(candidate[0] - cx, candidate[1] - cy) >= min_gap
               for cx, cy in centers):
            centers.append(candidate)
    while len(centers) < count:
        centers.append((rng.uniform(*x_range), rng.uniform(*y_range)))
    return centers


def cluster_weights(rng, count):
    """A few dense hubs and a couple sparse ones, squared so the spread
    between busiest and quietest cluster is wider than a flat random draw."""
    return [rng.uniform(0.35, 1.0) ** 2 for _ in range(count)]


def sample_position(rng, centers, weights, sigma_range=(120, 420),
                     stray_chance=0.08,
                     stray_range=((-6000, 6000), (-4000, 4000))):
    """A world position: usually a gaussian scatter around one weighted
    cluster center, occasionally (`stray_chance`) a lone object dropped
    somewhere in the open, for contrast against the busy regions."""
    if not centers or rng.random() < stray_chance:
        return (rng.uniform(*stray_range[0]), rng.uniform(*stray_range[1]))
    index = rng.choices(range(len(centers)), weights=weights, k=1)[0]
    cx, cy = centers[index]
    sigma = rng.uniform(*sigma_range)
    return (rng.gauss(cx, sigma), rng.gauss(cy, sigma * 0.7))


def pick_color_key(rng):
    return rng.choice(COLOR_KEYS)


def pick_shape_kind(rng):
    return rng.choice(SHAPE_KINDS)


def pick_stroke_width(rng):
    return round(rng.uniform(2.0, 6.0), 1)


def pick_image_scale(rng):
    """A placed image's on-canvas size relative to its real pixel
    dimensions, so images read as resized rather than always at their
    native decoded size."""
    return round(rng.uniform(0.6, 1.4), 2)
