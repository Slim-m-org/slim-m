# SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
"""Tests for seed_canvas_diagram.py; no network.

`run()` itself calls the API through `seed_canvas_ops.place_object`, so it
is exercised with a fake api object rather than skipped - the geometry is
the point of this module, and a fake that just echoes the placement back
is enough to prove it without a server.
"""
import unittest

import seed_canvas_diagram as diagram


class FakeApi:
    """Echoes a placement straight back with a made-up seq, the shape a
    real POST /canvas/objects response carries."""

    def __init__(self):
        self.next_seq = 1
        self.placed = []

    def call(self, method, path, body=None, raw=None, content_type=None):
        del method, path, raw, content_type
        body = dict(body)
        body["seq"] = self.next_seq
        body["z_index"] = self.next_seq
        self.next_seq += 1
        self.placed.append(body)
        return body


class ClusterBoundsTest(unittest.TestCase):
    def test_bounds_the_objects_actually_near_the_center(self):
        placed = [
            {"x": -100, "y": -50, "w": 40, "h": 20},
            {"x": 60, "y": 30, "w": 20, "h": 20},
            {"x": 5000, "y": 5000, "w": 10, "h": 10},  # far away, excluded
        ]
        bounds = diagram._cluster_bounds(placed, (0, 0))
        self.assertEqual(bounds, (-100, -50, 80, 50))

    def test_falls_back_to_a_placeholder_box_when_nothing_is_near(self):
        bounds = diagram._cluster_bounds([], (1000, -500))
        min_x, min_y, max_x, max_y = bounds
        self.assertLess(min_x, 1000)
        self.assertGreater(max_x, 1000)
        self.assertLess(min_y, -500)
        self.assertGreater(max_y, -500)


class DiagramRunTest(unittest.TestCase):
    def test_places_three_notes_and_three_shapes(self):
        apis = [FakeApi(), FakeApi(), FakeApi(), FakeApi(), FakeApi()]
        centers = [(0, 0), (3000, -2000), (-3000, 1800)]
        weights = [1.0, 0.4, 0.1]
        placed = [
            {"id": "seed-a", "x": -200, "y": -150, "w": 60, "h": 60},
            {"id": "seed-b", "x": 150, "y": 100, "w": 30, "h": 30},
        ]
        result = diagram.run(apis, "chan", centers, weights, placed)
        kinds = [row["kind"] for row in result]
        self.assertEqual(kinds.count("note"), 3)
        self.assertEqual(kinds.count("shape"), 3)
        shape_kinds = {row["props"]["shape"] for row in result
                       if row["kind"] == "shape"}
        self.assertEqual(shape_kinds, {"rectangle", "arrow", "line"})

    def test_spreads_authorship_across_accounts(self):
        apis = [FakeApi(), FakeApi(), FakeApi(), FakeApi(), FakeApi()]
        centers = [(0, 0), (2000, 2000)]
        weights = [1.0, 0.2]
        result = diagram.run(apis, "chan", centers, weights, [])
        self.assertEqual({row["author_index"] for row in result},
                          {0, 1, 2, 3, 4})

    def test_arrow_points_down_and_right_toward_its_target(self):
        """The shape kind's own line/arrow primitive always draws its
        box's top-left-to-bottom-right diagonal, so the arrow this module
        places from the cluster's rectangle to its callout note only
        renders pointing at the note if the note is down and to the right
        of the rectangle - see the module's own doc comment."""
        apis = [FakeApi() for _ in range(5)]
        centers = [(0, 0)]
        weights = [1.0]
        result = diagram.run(apis, "chan", centers, weights, [])
        arrow = next(row for row in result
                     if row["kind"] == "shape"
                     and row["props"]["shape"] == "arrow")
        rectangle = next(row for row in result
                          if row["kind"] == "shape"
                          and row["props"]["shape"] == "rectangle")
        self.assertGreaterEqual(arrow["x"], rectangle["x"] + rectangle["w"])
        self.assertGreaterEqual(arrow["y"], rectangle["y"] + rectangle["h"])

    def test_every_placed_box_has_nonnegative_extent(self):
        apis = [FakeApi() for _ in range(5)]
        centers = [(0, 0), (3500, -2200), (-3200, 2100), (1500, 3000)]
        weights = [1.0, 0.6, 0.3, 0.1]
        result = diagram.run(apis, "chan", centers, weights, [])
        for row in result:
            self.assertGreaterEqual(row["w"], 0)
            self.assertGreaterEqual(row["h"], 0)


if __name__ == "__main__":
    unittest.main()
